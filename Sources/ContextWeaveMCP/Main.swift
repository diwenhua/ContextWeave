import Darwin
import Foundation
import ContextWeaveCore

private actor ResponseWriter {
    func write(_ response: Data) {
        FileHandle.standardOutput.write(response + Data([10]))
    }
}

/// Reserve capacity for health checks even when ordinary requests are saturated.
private actor RequestAdmission {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter(control: Bool) -> Bool {
        guard active < (control ? 10 : 8) else { return false }
        active += 1
        return true
    }
    func leave() {
        active -= 1
        if active == 0 {
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    func waitUntilIdle() async {
        if active == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func isIdle() -> Bool { active == 0 }
}

@main
struct ContextWeaveMCP {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--connect-claude") {
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.configureClaude(executable: executable, home: ClaudePaths().configuration.deletingLastPathComponent()) { print(message) }
                return
            }
            if CommandLine.arguments.contains("--connect-codex") {
                let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.configure(agent: "codex", executable: executable, home: home) { print(message) }
                return
            }
            if CommandLine.arguments.contains("--connect-cursor") {
                let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.configureCursor(executable: executable, home: home) { print(message) }
                return
            }
            if CommandLine.arguments.contains("--connect-antigravity") {
                let env = ProcessInfo.processInfo.environment
                let home = env["ANTIGRAVITY_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config")
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.configureAntigravity(executable: executable, home: home) { print(message) }
                return
            }
            if CommandLine.arguments.contains("--connect") {
                let env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser
                let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
                let dshHome = env["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.connect(executable: executable, codexHome: codexHome, dshHome: dshHome) { print(message) }
                return
            }
            if CommandLine.arguments.contains("--scan") {
                let service = try HandoffService()
                let report = await service.scan()
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                return
            }
            let handler = MCPHandler(configuration: .local)
            let output = ResponseWriter(), admission = RequestAdmission()
            MCPDiagnostics.event("process_started", category: "ok")
            if ProcessInfo.processInfo.environment[MCPReload.environmentKey] == "1" {
                unsetenv(MCPReload.environmentKey)
                await output.write(MCPReload.toolsChangedNotification)
            }
            let executable = Self.executablePath()
            let started = executable.flatMap(ExecutableStamp.capture)
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            if flags >= 0 { _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) }
            var pending = Data()
            var retryAfter: Date?
            while true {
                if pending.isEmpty, await admission.isIdle(), let executable, let started,
                   let observed = ExecutableStamp.capture(executable),
                   MCPReload.shouldReload(started: started, current: observed, retryAfter: retryAfter) {
                    try await Task.sleep(for: .milliseconds(200))
                    let settled = ExecutableStamp.capture(executable)
                    await admission.waitUntilIdle()
                    if pending.isEmpty, await admission.isIdle(), settled == observed {
                        if Self.reload(executable) { return }
                        MCPDiagnostics.event("reload_failed", category: "unavailable")
                        retryAfter = Date().addingTimeInterval(5)
                    }
                }
                var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
                // A partially received line still needs to wait for input; polling
                // with a zero timeout would spin a CPU core until its newline arrives.
                let status = poll(&fds, 1, 1000)
                if status < 0 { if errno == EINTR { continue }; break }
                if status == 0 { continue }
                let events = fds[0].revents
                if events & Int16(POLLERR | POLLNVAL) != 0 { break }
                if events & Int16(POLLIN | POLLHUP) != 0 {
                    guard let chunk = Self.readChunk() else { break }
                    pending.append(chunk)
                }
                while let newline = pending.firstRange(of: Data([0x0A])) {
                    var line = Data(pending[..<newline.lowerBound])
                    pending.removeSubrange(..<newline.upperBound)
                    if line.last == 0x0D { line.removeLast() }
                    await Self.accept(line, handler: handler, output: output, admission: admission)
                }
                if events & Int16(POLLHUP) != 0, pending.isEmpty { break }
            }
            await admission.waitUntilIdle()
            MCPDiagnostics.event("stdin_closed", category: "normal")
        } catch {
            FileHandle.standardError.write(Data("ContextWeave: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Unbuffered reads keep a later exec from discarding a line already held by libc.
    private static func readChunk() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN { return Data() }
            return nil
        }
    }

    private static func accept(_ line: Data, handler: MCPHandler, output: ResponseWriter, admission: RequestAdmission) async {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let method = request?["method"] as? String
        let control = method == "ping" || method == "initialize" || method == "tools/list"
        if await admission.enter(control: control) {
            Task.detached {
                if let response = await handler.handle(line) { await output.write(response) }
                await admission.leave()
            }
        } else {
            MCPDiagnostics.event("request_rejected", category: "overloaded")
            if let id = request?["id"], !(id is NSNull),
               let response = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Server busy; retry later"]]) {
                await output.write(response)
            }
        }
    }

    private static func executablePath() -> String? {
        var size = UInt32(1024)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Keeps the agent's pipes. Returns false when the new image could not be loaded.
    private static func reload(_ path: String) -> Bool {
        setenv(MCPReload.environmentKey, "1", 1)
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(path)]
        for argument in CommandLine.arguments.dropFirst() {
            arguments.append(strdup(argument))
        }
        arguments.append(nil)
        let _ = execv(path, arguments)
        unsetenv(MCPReload.environmentKey)
        return false
    }
}
