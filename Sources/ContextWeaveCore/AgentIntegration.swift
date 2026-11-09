import Foundation

public struct AgentConnectionStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notConfigured
        case connected
        case unmanaged
        case unreadable
    }

    public let agent: String
    public let configPath: String
    public let state: State
    /// The executable recorded in the managed block, when it can be recognized.
    public let helperPath: String?
    public let detail: String?

    public init(agent: String, configPath: String, state: State, helperPath: String?, detail: String?) {
        self.agent = agent
        self.configPath = configPath
        self.state = state
        self.helperPath = helperPath
        self.detail = detail
    }
}

public enum AgentIntegration {
    private static let beginMarker = "# BEGIN ContextWeave managed MCP\n"
    private static let endMarker = "# END ContextWeave managed MCP"

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
    /// Both agents launch the same helper and share its SQLite database.
    public static func codexSnippet(executable: String) -> String {
        "[mcp_servers.contextweave]\ncommand = \(quoted(executable))\nargs = []\nstartup_timeout_sec = 60\ntool_timeout_sec = 120\n"
    }
    public static func dshSnippet(executable: String) -> String {
        "- insert:\n    - id: contextweave\n      name: '@deepseek-ai/dsh-mcp-client'\n      config:\n        serverName: contextweave\n        transport: stdio\n        command: \(quoted(executable))\n        args: []\n        toolCallTimeoutMs: 120000\n"
    }
}

extension AgentIntegration {
    /// Cursor uses JSON rather than the marked TOML/YAML blocks used by other agents.
    /// The environment marker identifies only registrations created by ContextWeave.
    public static func cursorConfiguration(_ current: String, executable: String?) throws -> String {
        let data = Data((current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : current).utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.invalid("Cursor MCP configuration must be a JSON object")
        }
        guard root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else {
            throw CaptureError.invalid("Cursor mcpServers must be a JSON object")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers["contextweave"] {
            guard let entry = existing as? [String: Any],
                  let env = entry["env"] as? [String: Any],
                  env["CONTEXTWEAVE_MANAGED"] as? String == "1" else {
                throw CaptureError.invalid("An existing Cursor contextweave registration needs manual review; configuration was not changed.")
            }
        }
        if let executable {
            servers["contextweave"] = ["command": executable, "args": [], "env": ["CONTEXTWEAVE_MANAGED": "1"]]
        } else { servers.removeValue(forKey: "contextweave") }
        root["mcpServers"] = servers
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    }

    /// JSON shown in the manual setup section.
    public static func cursorSnippet(executable: String) -> String {
        (try? cursorConfiguration("", executable: executable)) ?? ""
    }

    public static func cursorStatus(home: URL) -> AgentConnectionStatus {
        let url = home.appendingPathComponent("mcp.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentConnectionStatus(agent: "cursor", configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
        }
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any], root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else {
            return AgentConnectionStatus(agent: "cursor", configPath: url.path, state: .unreadable, helperPath: nil, detail: "Invalid Cursor MCP configuration.")
        }
        guard let entry = (root["mcpServers"] as? [String: Any])?["contextweave"] else {
            return AgentConnectionStatus(agent: "cursor", configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
        }
        guard let server = entry as? [String: Any], let env = server["env"] as? [String: Any], env["CONTEXTWEAVE_MANAGED"] as? String == "1" else {
            return AgentConnectionStatus(agent: "cursor", configPath: url.path, state: .unmanaged, helperPath: nil, detail: "Cursor registration is not managed by ContextWeave.")
        }
        return AgentConnectionStatus(agent: "cursor", configPath: url.path, state: .connected, helperPath: server["command"] as? String, detail: nil)
    }

    public static func configureCursor(executable: String?, home: URL) throws -> [String] {
        if let executable, (!executable.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: executable)) {
            throw CaptureError.invalid("MCP helper must be an existing absolute executable path")
        }
        let url = home.appendingPathComponent("mcp.json")
        let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        if executable == nil && cursorStatus(home: home).state == .notConfigured { return ["No managed Cursor registration"] }
        let new = try cursorConfiguration(old, executable: executable)
        if old == new { return ["Already connected: \(url.path)"] }
        var messages: [String] = []
        if let backup = try backup(url) { messages.append("Backup: \(backup)") }
        try write(new, to: url)
        messages.append("\(executable == nil ? "Removed" : "Connected"): \(url.path)")
        return messages
    }

    /// Replaces only our marked block; refuses pre-existing unowned registrations.
    public static func merging(_ current: String, snippet: String) throws -> String {
        let normalized = current.replacingOccurrences(of: "\r\n", with: "\n")
        let block = beginMarker + snippet + endMarker
        if normalized.contains(beginMarker) || normalized.contains(endMarker) {
            guard normalized.components(separatedBy: beginMarker).count == 2,
                  normalized.components(separatedBy: endMarker).count == 2,
                  let start = normalized.range(of: beginMarker), let finish = normalized.range(of: endMarker), start.upperBound <= finish.lowerBound else { throw CaptureError.invalid("Ambiguous managed MCP block; configuration was not changed.") }
            var result = normalized
            result.replaceSubrange(start.lowerBound..<finish.upperBound, with: block)
            return current.contains("\r\n") ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
        }
        guard !normalized.contains("contextweave") else { throw CaptureError.invalid("An existing contextweave registration needs manual review; configuration was not changed.") }
        let result = normalized + (normalized.isEmpty ? "" : normalized.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
        return current.contains("\r\n") ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    /// Removes only our marked block. Unowned registrations are left untouched.
    public static func removing(_ current: String) throws -> String {
        let normalized = current.replacingOccurrences(of: "\r\n", with: "\n")
        let begins = normalized.components(separatedBy: beginMarker).count - 1
        let ends = normalized.components(separatedBy: endMarker).count - 1
        if begins == 1 && ends == 1 {
            guard let start = normalized.range(of: beginMarker),
                  let finish = normalized.range(of: endMarker),
                  start.upperBound <= finish.lowerBound else { throw CaptureError.invalid("Ambiguous managed MCP block; configuration was not changed.") }
            var result = normalized
            var removalEnd = finish.upperBound
            if removalEnd < result.endIndex, result[removalEnd] == "\n" {
                removalEnd = result.index(after: removalEnd)
            }
            result.removeSubrange(start.lowerBound..<removalEnd)
            if result.hasSuffix("\n\n") { result.removeLast() }
            return current.contains("\r\n") ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
        }
        if begins > 0 || ends > 0 {
            throw CaptureError.invalid("Ambiguous managed MCP block; configuration was not changed.")
        }
        guard !normalized.contains("contextweave") else { throw CaptureError.invalid("An existing contextweave registration needs manual review; configuration was not changed.") }
        return current
    }

    public static func status(codexHome: URL, dshHome: URL) -> [AgentConnectionStatus] {
        [
            connectionStatus(agent: "codex", url: codexHome.appendingPathComponent("config.toml")),
            connectionStatus(agent: "dsh", url: dshHome.appendingPathComponent("cordis.patch.yml"))
        ]
    }

    public static func connect(executable: String, codexHome: URL, dshHome: URL) throws -> [String] {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw CaptureError.invalid("MCP helper must be an existing absolute executable path") }
        let targets = [(codexHome.appendingPathComponent("config.toml"), codexSnippet(executable: executable)), (dshHome.appendingPathComponent("cordis.patch.yml"), dshSnippet(executable: executable))]
        // Preflight both files before making any change.
        let plans = try targets.map { url, snippet -> (URL, String, String) in
            let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            return (url, old, try merging(old, snippet: snippet))
        }
        var messages: [String] = []
        for (url, old, new) in plans {
            if old == new { messages.append("Already connected: \(url.path)"); continue }
            if let backup = try backup(url) { messages.append("Backup: \(backup)") }
            try write(new, to: url)
            messages.append("Connected: \(url.path)")
        }
        return messages
    }

    public static func remove(codexHome: URL, dshHome: URL) throws -> [String] {
        let targets = [codexHome.appendingPathComponent("config.toml"), dshHome.appendingPathComponent("cordis.patch.yml")]
        // Preflight both files before making any change.
        let plans = try targets.map { url -> (URL, String, String) in
            let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            return (url, old, try removing(old))
        }
        var messages: [String] = []
        for (url, old, new) in plans {
            if old == new { messages.append("No managed registration: \(url.path)"); continue }
            if let backup = try backup(url) { messages.append("Backup: \(backup)") }
            try write(new, to: url)
            messages.append("Removed: \(url.path)")
        }
        return messages
    }
}

extension AgentIntegration {
    private static func connectionStatus(agent: String, url: URL) -> AgentConnectionStatus {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentConnectionStatus(
                agent: agent,
                configPath: url.path,
                state: exists ? .unreadable : .notConfigured,
                helperPath: nil,
                detail: exists ? "The configuration file exists but could not be read." : nil
            )
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let block = managedBlock(in: normalized) {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .connected, helperPath: commandPath(in: block), detail: nil)
        }
        if normalized.contains("contextweave") {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .unmanaged, helperPath: nil, detail: "A contextweave entry exists without ContextWeave markers.")
        }
        return AgentConnectionStatus(agent: agent, configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
    }

    private static func managedBlock(in text: String) -> String? {
        guard text.components(separatedBy: beginMarker).count == 2,
              text.components(separatedBy: endMarker).count == 2,
              let start = text.range(of: beginMarker),
              let finish = text.range(of: endMarker),
              start.upperBound <= finish.lowerBound else { return nil }
        return String(text[start.upperBound..<finish.lowerBound])
    }

    private static func commandPath(in block: String) -> String? {
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { continue }
            let remainder = trimmed.dropFirst("command".count)
            guard let separator = remainder.first(where: { !$0.isWhitespace }), separator == "=" || separator == ":" else { continue }
            var value = remainder.drop(while: { $0 != separator }).dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"") else { continue }
            value.removeFirst()
            var path = ""
            var escaped = false
            for character in value {
                if escaped {
                    path.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                } else {
                    path.append(character)
                }
            }
            return path
        }
        return nil
    }

    private static func backup(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = url.path + ".bak-contextweave-" + UUID().uuidString
        try FileManager.default.copyItem(atPath: url.path, toPath: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
        return backup
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try String(contentsOf: url, encoding: .utf8) == contents else { throw CaptureError.invalid("Configuration readback failed: \(url.path)") }
    }
}
