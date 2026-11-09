import Foundation

public enum CaptureError: Error, LocalizedError {
    case invalid(String)
    case staleCursor
    public var errorDescription: String? {
        switch self {
        case let .invalid(text): return text
        case .staleCursor: return "The capture cursor changed in another process; retry the scan."
        }
    }
}

public enum ProjectIdentity {
    public static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw CaptureError.invalid("An absolute project path is required.") }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct CaptureState: Equatable {
    var externalID: String?
    var cwd: String?
    var lineIndex: Int
    var usesOrdinals: Bool
    var rejected: Bool
    var runState: SessionRunState?

    init(agent: String) {
        externalID = nil
        cwd = nil
        lineIndex = 0
        usesOrdinals = agent == "codex"
        rejected = false
        runState = nil
    }
}

struct ParsedChunk {
    var session: Session?
    var state: CaptureState
    var pending: String
    var newlines: Int
    var pendingBytes: Int
}

/// Parsers consume source events, not rendered chat text. IDs remain stable on append.
public enum SessionParser {
    static let version = "parser-4"

    public static func parse(_ text: String, agent: String, path: String) throws -> Session? {
        try consume(Data(text.utf8), agent: agent, path: path, state: CaptureState(agent: agent)).session
    }

    /// Parses complete lines in `data`. A trailing partial line stays pending and is not committed.
    static func consume(_ data: Data, agent: String, path: String, state: CaptureState) throws -> ParsedChunk {
        let split = try split(data)
        let parsed = try parseBody(split.body, agent: agent, path: path, state: state)
        return ParsedChunk(session: parsed.session, state: parsed.state, pending: split.pending, newlines: split.newlines, pendingBytes: split.pendingBytes)
    }

    static func consume(_ text: String, agent: String, path: String, state: CaptureState) throws -> ParsedChunk {
        let split = try split(Data(text.utf8))
        let parsed = try parseBody(split.body, agent: agent, path: path, state: state)
        return ParsedChunk(session: parsed.session, state: parsed.state, pending: split.pending, newlines: split.newlines, pendingBytes: split.pendingBytes)
    }

    private struct Split {
        var body: String
        var pending: String
        var newlines: Int
        var pendingBytes: Int
    }

    /// Commits through the last newline. A final valid JSON object is parsed now but left pending so a later append can extend it.
    private static func split(_ data: Data) throws -> Split {
        let newline = data.lastIndex(of: 0x0A)
        let prefix: Data
        let suffix: Data
        if let newline {
            let end = data.index(after: newline)
            prefix = Data(data[..<end])
            suffix = Data(data[end...])
        } else {
            prefix = Data()
            suffix = data
        }
        guard let prefixText = String(data: prefix, encoding: .utf8) else { throw CaptureError.invalid("Invalid UTF-8") }
        let newlines = prefix.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        if suffix.isEmpty { return Split(body: prefixText, pending: "", newlines: newlines, pendingBytes: 0) }
        guard let suffixText = String(data: suffix, encoding: .utf8) else {
            if prefix.isEmpty { throw CaptureError.invalid("Invalid UTF-8") }
            return Split(body: prefixText, pending: "", newlines: newlines, pendingBytes: suffix.count)
        }
        if jsonObject(suffixText) != nil {
            return Split(body: prefixText + suffixText, pending: suffixText, newlines: newlines, pendingBytes: suffix.count)
        }
        return Split(body: prefixText, pending: suffixText, newlines: newlines, pendingBytes: suffix.count)
    }

    private static func parseBody(_ body: String, agent: String, path: String, state: CaptureState) throws -> (session: Session?, state: CaptureState) {
        var externalID = state.externalID
        var cwd = state.cwd
        var usesOrdinals = state.usesOrdinals
        var messages: [SessionMessage] = []
        var state = state
        var pendingApprovals = state.runState == .awaitingApproval ? 1 : 0
        guard !state.rejected else { return (nil, state) }
        guard !body.isEmpty else { return (nil, state) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        let lines = body.components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let index = state.lineIndex + offset
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CaptureError.invalid("Malformed JSON at line \(index + 1) in \(path)")
            }
            if event["ordinal"] as? Int == nil { usesOrdinals = false }
            let eventID = event["ordinal"] as? Int ?? index
            let type = event["type"] as? String ?? ""
            let payload = event["payload"] as? [String: Any] ?? [:]
            let eventBody = event["data"] as? [String: Any] ?? [:]
            let timestamp: Int64?
            if agent == "codex" {
                if let value = event["timestamp"] as? String, type == "response_item" {
                    timestamp = (iso.date(from: value) ?? plainISO.date(from: value)).map { Int64($0.timeIntervalSince1970 * 1000) }
                } else { timestamp = nil }
            } else {
                timestamp = (event["time"] as? NSNumber)?.int64Value
            }
            func append(_ role: SessionMessage.Role, _ content: String, suffix: String = "") {
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                messages.append(SessionMessage(id: "\(eventID)\(suffix)", role: role, content: content, timestampMilliseconds: timestamp))
            }
            if agent == "codex" {
                if type == "event_msg" {
                    switch payload["type"] as? String {
                    case "task_started": state.runState = .running
                    case "task_complete": state.runState = .finished
                    case "turn_aborted": state.runState = .aborted
                    default: break
                    }
                }
                if type == "session_meta" {
                    externalID = payload["id"] as? String ?? payload["session_id"] as? String ?? externalID
                    if cwd == nil { cwd = payload["cwd"] as? String }
                    if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                        var rejected = state
                        rejected.rejected = true
                        rejected.externalID = externalID
                        rejected.usesOrdinals = usesOrdinals
                        return (nil, rejected)
                    }
                } else if type == "turn_context", cwd == nil { cwd = payload["cwd"] as? String }
                else if type == "response_item" {
                    switch payload["type"] as? String {
                    case "message":
                        if let raw = payload["role"] as? String, let role = SessionMessage.Role(rawValue: raw), role == .user || role == .assistant {
                            append(role, textOf(payload["content"]))
                        }
                    case "function_call", "custom_tool_call":
                        append(.tool, "Call \(payload["name"] as? String ?? "tool") [\(payload["call_id"] as? String ?? "")]:\n" + stringify(payload["arguments"] ?? payload["input"]))
                    case "function_call_output", "custom_tool_call_output":
                        append(.tool, "Result [\(payload["call_id"] as? String ?? "")]:\n" + stringify(payload["output"]))
                    default: break
                    }
                }
            } else if agent == "dsh" {
                if type == "session" {
                    externalID = event["id"] as? String ?? externalID
                    if cwd == nil { cwd = event["cwd"] as? String }
                    if event["origin"] as? String == "subagent" || (event["delegationDepth"] as? Int ?? 0) > 0 {
                        var rejected = state
                        rejected.rejected = true
                        rejected.externalID = externalID
                        rejected.usesOrdinals = false
                        return (nil, rejected)
                    }
                } else if type == "user/message" {
                    let source = eventBody["source"] as? [String: Any]
                    if source?["kind"] == nil || source?["kind"] as? String == "user" { append(.user, textOf(eventBody["content"])) }
                } else if type == "assistant/message", let message = eventBody["message"] as? [String: Any] {
                    if let blocks = message["content"] as? [[String: Any]] {
                        for (blockOffset, block) in blocks.enumerated() {
                            if block["type"] as? String == "text" { append(.assistant, block["text"] as? String ?? "", suffix: ":\(blockOffset)") }
                            if block["type"] as? String == "tool-call" { append(.tool, "Call \(block["name"] as? String ?? "tool"):\n" + stringify(block["arguments"]), suffix: ":\(blockOffset)") }
                        }
                    } else { append(.assistant, textOf(message["content"])) }
                } else if type == "tool/result" { append(.tool, "Result:\n" + stringify(eventBody)) }
                else if type == "turn/start" { state.runState = pendingApprovals > 0 ? .awaitingApproval : .running }
                else if type == "approval/asked" {
                    pendingApprovals += 1
                    state.runState = .awaitingApproval
                } else if type == "approval/decided" {
                    if pendingApprovals > 0 { pendingApprovals -= 1 }
                    if pendingApprovals == 0, state.runState == .awaitingApproval { state.runState = .running }
                } else if type == "turn/end" {
                    pendingApprovals = 0
                    let kind = (eventBody["reason"] as? [String: Any])?["kind"] as? String
                    state.runState = kind == "aborted" ? .aborted : .finished
                }
            } else { throw CaptureError.invalid("Unsupported agent: \(agent)") }
        }
        var updated = state
        updated.externalID = externalID
        updated.cwd = try cwd.map(ProjectIdentity.canonicalPath) ?? state.cwd
        updated.usesOrdinals = usesOrdinals
        guard let externalID, !messages.isEmpty else { return (nil, updated) }
        let session = Session(
            source: SessionSource(id: try SessionID(agent: agent, externalID: externalID), sourcePath: path),
            projectID: updated.cwd,
            messages: messages,
            messageIDsAreOrdinals: usesOrdinals,
            runState: updated.runState
        )
        return (session, updated)
    }

    private static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func textOf(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}
