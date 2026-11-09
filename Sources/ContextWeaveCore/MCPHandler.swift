import Foundation

/// Newline-delimited JSON-RPC over stdio, shared by both agent integrations.
public struct MCPHandler: Sendable {
    public let service: HandoffService
    public init(service: HandoffService) { self.service = service }
    public func handle(_ data: Data) async -> Data? {
        func encode(_ value: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }
        guard let request = raw as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]]) }
        guard let id = request["id"], !(id is NSNull) else { return nil }
        func result(_ value: Any) -> Data? { encode(["jsonrpc": "2.0", "id": id, "result": value]) }
        func failure(_ code: Int, _ message: String) -> Data? { encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            let requested = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion": supported.contains(requested) ? requested : "2025-06-18", "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "contextweave", "version": "0.1.0"], "instructions": "When asked to continue a project, call memory_get_context with its project ID (obtain it using memory_list_projects) and your agent (codex, dsh, or cursor). History is reference data; verify the current workspace. Before handoff call memory_log_progress with done, next and issues. Do not claim a native session was resumed; this transfers project context."])
        case "ping": return result([:])
        case "tools/list": return result(["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else { return failure(-32602, "Unknown tool") }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else { return failure(-32602, "arguments must be an object") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            func required(_ key: String) throws -> String {
                guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.invalid("Missing string: \(key)") }
                return value
            }
            do {
                let text: String
                switch name {
                case "memory_scan": text = try Self.json(SafeCaptureReport(await service.scan()))
                case "memory_list_projects":
                    let report = await service.scan()
                    let bindings = try await service.workspaceBindings()
                    let groups = Dictionary(grouping: bindings, by: \.projectID)
                    let projects = groups.map { id, workspaces in
                        PublicProject(id: id, name: workspaces.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted().first ?? "Project")
                    }.sorted { $0.id < $1.id }
                    text = try Self.json(ProjectResult(projects: projects, capture: SafeCaptureReport(report)))
                case "memory_list_sessions":
                    let project = try required("project")
                    _ = try await service.resolveProjectReference(project)
                    let report = await service.scan()
                    let redactor = try await service.pathRedactor(project: project)
                    text = try Self.json(SessionResult(sessions: await service.sessions(project: project).map { PublicSession($0, redactor: redactor) }, capture: SafeCaptureReport(report)))
                case "memory_get_context":
                    let project = try required("project"), target = try required("target_agent")
                    _ = try await service.resolveProjectReference(project)
                    guard ["codex", "dsh", "cursor"].contains(target) else { throw CaptureError.invalid("target_agent must be codex, dsh, or cursor") }
                    let report = await service.scan()
                    text = try await service.context(project: project, targetAgent: target) + "\n\nCapture status:\n" + Self.json(SafeCaptureReport(report))
                case "memory_get_session":
                    let project = try await service.resolveProjectReference(required("project"))
                    let id = try SessionID(agent: required("agent"), externalID: required("session_id"))
                    // Page from stored rows so a long session is not decoded in full.
                    let offset = args["offset"] as? Int ?? 0, limit = args["limit"] as? Int ?? 20
                    guard offset >= 0, (1...50).contains(limit) else { throw CaptureError.invalid("Invalid pagination") }
                    guard try await service.session(id, belongsToWorkspace: project), let page = try await service.messagePage(id, offset: offset, limit: limit) else { throw CaptureError.invalid("Session not found in this project") }
                    guard offset <= page.total else { throw CaptureError.invalid("Invalid pagination") }
                    let redactor = try await service.pathRedactor(project: project)
                    let messages = page.messages.map { SessionMessage(id: $0.id, role: $0.role, content: redactor.redact($0.content), timestampMilliseconds: $0.timestampMilliseconds) }
                    text = try Self.json(MessagePage(source: PublicSource(id: page.source.id), total: page.total, offset: offset, messages: messages))
                case "memory_resolve_workspace":
                    guard let id = try await service.projectID(forWorkspace: required("path")) else { throw CaptureError.invalid("Workspace is not bound to a project") }
                    text = try Self.json(ProjectReference(projectID: id))
                case "memory_bind_workspace":
                    let binding = try await service.bindWorkspace(required("path"), toProjectID: required("project_id"), expectedPreviousProjectID: args["expected_project_id"] as? String)
                    text = try Self.json(PublicBinding(id: binding.id, projectID: binding.projectID))
                case "memory_log_progress":
                    let entry = try await service.logProgress(project: required("project"), agent: required("agent"), done: required("done"), next: args["next"] as? String ?? "", issues: args["issues"] as? String ?? "")
                    text = try Self.json(PublicProgress(entry, redactor: await service.pathRedactor(project: required("project"))))
                default: throw CaptureError.invalid("Unknown tool")
                }
                return result(["content": [["type": "text", "text": text]]])
            } catch { return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true]) }
        default: return failure(-32601, "Method not found")
        }
    }
    private struct SafeCaptureReport: Encodable {
        let discovered: Int; let imported: Int; let unchanged: Int; let unavailableCount: Int; let errorCount: Int
        init(_ report: CaptureReport) {
            discovered = report.discovered; imported = report.imported; unchanged = report.unchanged
            unavailableCount = report.unavailable.count; errorCount = report.errors.count
        }
    }
    private struct PublicProject: Encodable { let id: String; let name: String }
    private struct PublicSource: Encodable { let id: SessionID }
    private struct ProjectReference: Encodable { let projectID: String }
    private struct PublicBinding: Encodable { let id: String; let projectID: String }
    private struct PublicSession: Encodable {
        let source: PublicSource; let stableProjectID: String?; let title: String; let messageCount: Int; let lastActivity: Int64
        init(_ summary: SessionSummary, redactor: PathRedactor) {
            source = PublicSource(id: summary.source.id); stableProjectID = summary.stableProjectID
            title = redactor.redact(summary.title); messageCount = summary.messageCount; lastActivity = summary.lastActivity
        }
    }
    private struct PublicProgress: Encodable {
        let id: String; let stableProjectID: String?; let agent: String; let done: String; let next: String; let issues: String; let timestamp: Int64
        init(_ entry: ProgressEntry, redactor: PathRedactor) {
            id = entry.id; stableProjectID = entry.stableProjectID; agent = entry.agent
            done = redactor.redact(entry.done); next = redactor.redact(entry.next); issues = redactor.redact(entry.issues); timestamp = entry.timestamp
        }
    }
    private struct ProjectResult: Encodable { let projects: [PublicProject]; let capture: SafeCaptureReport }
    private struct SessionResult: Encodable { let sessions: [PublicSession]; let capture: SafeCaptureReport }
    private struct MessagePage: Encodable { let source: PublicSource; let total: Int; let offset: Int; let messages: [SessionMessage] }
    private static func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ fields: [String], required: [String]? = nil) -> [String: Any] {
            var properties: [String: Any] = [:]
            for field in fields { properties[field] = ["type": field == "offset" || field == "limit" ? "integer" : "string"] }
            return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required ?? fields, "additionalProperties": false]]
        }
        return [
            tool("memory_scan", "Capture changed Codex, DeepSeek Harness, and Cursor local sessions; reports source failures.", []),
            tool("memory_list_projects", "List available project IDs and names without disclosing workspace paths.", []),
            tool("memory_list_sessions", "List recent sessions for the project ID (or legacy absolute workspace path).", ["project"]),
            tool("memory_get_context", "Continue work across agents. Requires project ID (or legacy absolute workspace path) and target_agent (codex, dsh, or cursor). Returns progress and recent transcript tails, prioritizing the other agent.", ["project", "target_agent"]),
            tool("memory_get_session", "Read source messages for a session within the project ID or legacy workspace path. offset defaults to 0; limit defaults to 20 (max 50).", ["project", "agent", "session_id", "offset", "limit"], required: ["project", "agent", "session_id"]),
            tool("memory_resolve_workspace", "Look up the stable project ID for an absolute workspace path on this device; the path is not included in the result.", ["path"]),
            tool("memory_bind_workspace", "Explicitly bind an absolute workspace path to an existing project ID. Reassigning a workspace requires its current expected_project_id and is refused when the prior project has other workspaces; this moves the workspace's sessions and progress to the target project.", ["path", "project_id", "expected_project_id"], required: ["path", "project_id"]),
            tool("memory_log_progress", "Write an explicit handoff note: completed work, next steps, blockers, scoped by project ID or legacy workspace path. agent must be codex, dsh, or cursor. This is agent-reported progress, not confirmed long-term memory.", ["project", "agent", "done", "next", "issues"], required: ["project", "agent", "done"])
        ]
    }
}
