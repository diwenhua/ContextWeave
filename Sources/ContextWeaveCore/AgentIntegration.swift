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
        "[mcp_servers.contextweave]\ncommand = \(quoted(executable))\nargs = []\nenv = { CONTEXTWEAVE_MANAGED = \"1\" }\nstartup_timeout_sec = 60\ntool_timeout_sec = 120\n"
    }
    public static func dshSnippet(executable: String) -> String {
        "- insert:\n    - id: contextweave\n      name: '@deepseek-ai/dsh-mcp-client'\n      config:\n        serverName: contextweave\n        transport: stdio\n        command: \(quoted(executable))\n        args: []\n        toolCallTimeoutMs: 120000\n"
    }
}

extension AgentIntegration {
    /// Cursor and Antigravity use JSON rather than the marked TOML/YAML blocks used by Codex and DSH.
    /// The environment marker identifies only registrations created by ContextWeave.
    public static func claudeStatus(home: URL) -> AgentConnectionStatus {
        jsonStatus(agent: "claude", label: "Claude Code", url: home.appendingPathComponent(".claude.json"))
    }

    public static func claudeSnippet(executable: String) -> String {
        (try? jsonConfiguration("", executable: executable, label: "Claude Code")) ?? ""
    }

    public static func configureClaude(executable: String?, home: URL) throws -> [String] {
        try configureJSON(agent: "claude", label: "Claude Code", url: home.appendingPathComponent(".claude.json"), executable: executable)
    }

    public static func cursorConfiguration(_ current: String, executable: String?) throws -> String {
        try jsonConfiguration(current, executable: executable, label: "Cursor")
    }

    /// JSON shown in the manual setup section for Cursor.
    public static func cursorSnippet(executable: String) -> String {
        (try? cursorConfiguration("", executable: executable)) ?? ""
    }

    public static func cursorStatus(home: URL) -> AgentConnectionStatus {
        jsonStatus(agent: "cursor", label: "Cursor", url: home.appendingPathComponent("mcp.json"))
    }

    public static func configureCursor(executable: String?, home: URL) throws -> [String] {
        try configureJSON(agent: "cursor", label: "Cursor", url: home.appendingPathComponent("mcp.json"), executable: executable)
    }

    public static func antigravityConfiguration(_ current: String, executable: String?) throws -> String {
        try jsonConfiguration(current, executable: executable, label: "Antigravity")
    }

    /// JSON shown in the manual setup section for Antigravity.
    public static func antigravitySnippet(executable: String) -> String {
        (try? antigravityConfiguration("", executable: executable)) ?? ""
    }

    public static func antigravityStatus(home: URL) -> AgentConnectionStatus {
        jsonStatus(agent: "antigravity", label: "Antigravity", url: home.appendingPathComponent("mcp_config.json"))
    }

    public static func configureAntigravity(executable: String?, home: URL) throws -> [String] {
        try configureJSON(agent: "antigravity", label: "Antigravity", url: home.appendingPathComponent("mcp_config.json"), executable: executable)
    }

    private static func jsonConfiguration(_ current: String, executable: String?, label: String) throws -> String {
        let data = Data((current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : current).utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.invalid("\(label) MCP configuration must be a JSON object")
        }
        guard root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else {
            throw CaptureError.invalid("\(label) mcpServers must be a JSON object")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers["contextweave"] {
            guard let entry = existing as? [String: Any],
                  let env = entry["env"] as? [String: Any],
                  env["CONTEXTWEAVE_MANAGED"] as? String == "1" else {
                throw CaptureError.invalid("An existing \(label) contextweave registration needs manual review; configuration was not changed.")
            }
        }
        if let executable {
            servers["contextweave"] = ["type": "stdio", "command": executable, "args": [], "env": ["CONTEXTWEAVE_MANAGED": "1"]]
        } else { servers.removeValue(forKey: "contextweave") }
        root["mcpServers"] = servers
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    }

    private static func jsonStatus(agent: String, label: String, url: URL) -> AgentConnectionStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
        }
        guard let rawText = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .unreadable, helperPath: nil, detail: "Invalid \(label) MCP configuration.")
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let root = object as? [String: Any], root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .unreadable, helperPath: nil, detail: "Invalid \(label) MCP configuration.")
        }
        guard let entry = (root["mcpServers"] as? [String: Any])?["contextweave"] else {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .notConfigured, helperPath: nil, detail: nil)
        }
        guard let server = entry as? [String: Any], let env = server["env"] as? [String: Any], env["CONTEXTWEAVE_MANAGED"] as? String == "1" else {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .unmanaged, helperPath: nil, detail: "\(label) registration is not managed by ContextWeave.")
        }
        return AgentConnectionStatus(agent: agent, configPath: url.path, state: .connected, helperPath: server["command"] as? String, detail: nil)
    }

    private static func configureJSON(agent: String, label: String, url: URL, executable: String?) throws -> [String] {
        if let executable, (!executable.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: executable)) {
            throw CaptureError.invalid("MCP helper must be an existing absolute executable path")
        }
        let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        if executable == nil && jsonStatus(agent: agent, label: label, url: url).state == .notConfigured {
            return ["No managed \(label) registration"]
        }
        let new = try jsonConfiguration(old, executable: executable, label: label)
        if old == new { return ["Already connected: \(url.path)"] }
        var messages: [String] = []
        if let backup = try backup(url) { messages.append("Backup: \(backup)") }
        try write(new, to: url)
        messages.append("\(executable == nil ? "Removed" : "Connected"): \(url.path)")
        return messages
    }

    /// Codex may rewrite TOML and drop comments. Recover only our exact generated
    /// schema, with a durable env marker (or the legacy orphaned end marker).
    /// Unknown fields and ambiguous sections remain untouched for manual review.
    private static func recoveringCodexMarkers(_ current: String) -> String {
        let normalized = current.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains(beginMarker) else { return current }
        var lines = normalized.components(separatedBy: "\n")
        let header = "[mcp_servers.contextweave]"
        let headers = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == header }
        guard headers.count == 1, let start = headers.first else { return current }
        var end = start + 1
        while end < lines.count {
            let line = lines[end].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line != "[mcp_servers.contextweave.env]" { break }
            end += 1
        }
        var fields: [String: String] = [:]
        var inEnvironment = false
        var endMarkers = 0
        for raw in lines[(start + 1)..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == endMarker { endMarkers += 1; continue }
            if line == "[mcp_servers.contextweave.env]", !inEnvironment {
                inEnvironment = true
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { return current }
            let key = (inEnvironment ? "env." : "") + line[..<separator].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { return current }
            fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard let command = fields.removeValue(forKey: "command"),
              let path = try? JSONDecoder().decode(String.self, from: Data(command.utf8)),
              path.hasPrefix("/"),
              fields.removeValue(forKey: "args") == "[]",
              fields.removeValue(forKey: "startup_timeout_sec") == "60",
              fields.removeValue(forKey: "tool_timeout_sec") == "120" else { return current }
        let inlineEnv = fields.removeValue(forKey: "env")
        let nestedEnv = fields.removeValue(forKey: "env.CONTEXTWEAVE_MANAGED")
        let owned = (inlineEnv?.filter { !$0.isWhitespace } == "{CONTEXTWEAVE_MANAGED=\"1\"}" && nestedEnv == nil)
            || (nestedEnv == "\"1\"" && inlineEnv == nil)
        let legacy = inlineEnv == nil && nestedEnv == nil && endMarkers == 1
            && URL(fileURLWithPath: path).lastPathComponent == "contextweave-mcp"
        guard fields.isEmpty, (owned || legacy), endMarkers <= 1,
              normalized.components(separatedBy: endMarker).count - 1 == endMarkers else { return current }
        // Keep trailing blank lines and the following table outside the managed range.
        while end > start + 1 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let body = lines[start..<end].filter { $0.trimmingCharacters(in: .whitespaces) != endMarker }
        lines.replaceSubrange(start..<end, with: [String(beginMarker.dropLast())] + body + [endMarker])
        let repaired = lines.joined(separator: "\n")
        return current.contains("\r\n") ? repaired.replacingOccurrences(of: "\n", with: "\r\n") : repaired
    }

    // Codex records trusted project paths and plugin settings in the same file.
    // Only MCP tables (or inline/dotted MCP keys) can register this server.
    private static func hasCodexRegistration(_ text: String) -> Bool {
        var inServersTable = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let table = line.prefix { $0 != "]" }.dropFirst()
                    .replacingOccurrences(of: #"[\s"']"#, with: "", options: .regularExpression)
                inServersTable = table == "mcp_servers"
                if table == "mcp_servers.contextweave" || table.hasPrefix("mcp_servers.contextweave.") { return true }
            } else if !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].replacingOccurrences(of: #"[\s"']"#, with: "", options: .regularExpression)
                if key == "mcp_servers.contextweave" || key.hasPrefix("mcp_servers.contextweave.")
                    || (inServersTable && (key == "contextweave" || key.hasPrefix("contextweave."))) { return true }
                // An inline server map can span structured values. Avoid appending a duplicate table.
                if key == "mcp_servers" { return true }
            }
        }
        return false
    }

    /// Replaces only our marked block; refuses pre-existing unowned registrations.
    public static func merging(_ current: String, snippet: String) throws -> String {
        let normalized = recoveringCodexMarkers(current).replacingOccurrences(of: "\r\n", with: "\n")
        let block = beginMarker + snippet + endMarker
        if normalized.contains(beginMarker) || normalized.contains(endMarker) {
            guard normalized.components(separatedBy: beginMarker).count == 2,
                  normalized.components(separatedBy: endMarker).count == 2,
                  let start = normalized.range(of: beginMarker), let finish = normalized.range(of: endMarker), start.upperBound <= finish.lowerBound else { throw CaptureError.invalid("Ambiguous managed MCP block; configuration was not changed.") }
            var result = normalized
            result.replaceSubrange(start.lowerBound..<finish.upperBound, with: block)
            return current.contains("\r\n") ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
        }
        guard !(snippet.hasPrefix("[mcp_servers.") ? hasCodexRegistration(normalized) : normalized.contains("contextweave")) else { throw CaptureError.invalid("An existing contextweave registration needs manual review; configuration was not changed.") }
        let result = normalized + (normalized.isEmpty ? "" : normalized.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
        return current.contains("\r\n") ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    /// Removes only our marked block. Unowned registrations are left untouched.
    public static func removing(_ current: String, codex: Bool = false) throws -> String {
        let normalized = recoveringCodexMarkers(current).replacingOccurrences(of: "\r\n", with: "\n")
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
        guard !(codex ? hasCodexRegistration(normalized) : normalized.contains("contextweave")) else { throw CaptureError.invalid("An existing contextweave registration needs manual review; configuration was not changed.") }
        return current
    }

    public static func status(codexHome: URL, dshHome: URL) -> [AgentConnectionStatus] {
        [
            connectionStatus(agent: "codex", url: codexHome.appendingPathComponent("config.toml")),
            connectionStatus(agent: "dsh", url: dshHome.appendingPathComponent("cordis.patch.yml"))
        ]
    }

    /// Configures one agent without reading or modifying any other agent's files.
    public static func configure(agent: String, executable: String?, home: URL) throws -> [String] {
        switch agent {
        case "claude": return try configureClaude(executable: executable, home: home)
        case "cursor": return try configureCursor(executable: executable, home: home)
        case "antigravity": return try configureAntigravity(executable: executable, home: home)
        case "codex", "dsh": break
        default: throw CaptureError.invalid("Unsupported agent: \(agent)")
        }
        if let executable, (!executable.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: executable)) {
            throw CaptureError.invalid("MCP helper must be an existing absolute executable path")
        }
        let url = home.appendingPathComponent(agent == "codex" ? "config.toml" : "cordis.patch.yml")
        let old = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        let new: String
        if let executable {
            new = try merging(old, snippet: agent == "codex" ? codexSnippet(executable: executable) : dshSnippet(executable: executable))
        } else {
            new = try removing(old, codex: agent == "codex")
        }
        guard old != new else { return ["Unchanged: \(url.path)"] }
        var messages: [String] = []
        if let backup = try backup(url) { messages.append("Backup: \(backup)") }
        try write(new, to: url)
        messages.append("\(executable == nil ? "Removed" : "Configured"): \(url.path)")
        return messages
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
            return (url, old, try removing(old, codex: url.lastPathComponent == "config.toml"))
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
        let normalized = (agent == "codex" ? recoveringCodexMarkers(text) : text).replacingOccurrences(of: "\r\n", with: "\n")
        if let block = managedBlock(in: normalized) {
            return AgentConnectionStatus(agent: agent, configPath: url.path, state: .connected, helperPath: commandPath(in: block), detail: nil)
        }
        if (agent == "codex" ? hasCodexRegistration(normalized) : normalized.contains("contextweave")) || normalized.contains(beginMarker) || normalized.contains(endMarker) {
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
