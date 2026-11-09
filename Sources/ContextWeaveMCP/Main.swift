import Foundation
import ContextWeaveCore

@main
struct ContextWeaveMCP {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--connect-cursor") {
                let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                for message in try AgentIntegration.configureCursor(executable: executable, home: home) { print(message) }
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
            let service = try HandoffService()
            if CommandLine.arguments.contains("--scan") {
                let report = await service.scan()
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                return
            }
            let handler = MCPHandler(service: service)
            while let line = readLine() {
                if let response = await handler.handle(Data(line.utf8)) {
                    FileHandle.standardOutput.write(response + Data([10]))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("ContextWeave: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
