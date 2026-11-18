import XCTest
@testable import ContextWeaveCore

final class ClaudeCaptureTests: XCTestCase {
    private func jsonl(_ events: [[String: Any]]) throws -> String {
        try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    func testClaudeSharedPathsAndLegacySettings() throws {
        let home = URL(fileURLWithPath: "/tmp/cw-test-home")
        let paths = ClaudePaths(environment: [:], home: home)
        XCTAssertEqual(paths.configuration.path, home.appendingPathComponent(".claude.json").path)
        XCTAssertEqual(paths.projects.path, home.appendingPathComponent(".claude/projects").path)
        let custom = ClaudePaths(environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"], home: home)
        XCTAssertEqual(custom.configuration.path, "/tmp/custom-claude/.claude.json")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.claudeProjectsPath, "")
        XCTAssertEqual(old.captureConfiguration(environment: [:], home: home).claudeRoot, paths.projects)
        var settings = old
        settings.claudeProjectsPath = "/tmp/custom-projects"
        XCTAssertEqual(settings.captureConfiguration(environment: [:], home: home).claudeRoot?.path, "/tmp/custom-projects")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testClaudeConfigurationPreservesAccountProjectsAndOtherServers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude.json")
        let original = #"{"projects":{"/example":{"hasTrustDialogAccepted":true}},"mcpServers":{"other":{"command":"keep"}},"theme":"dark"}"#
        try original.write(to: file, atomically: true, encoding: .utf8)
        _ = try AgentIntegration.configure(agent: "claude", executable: "/usr/bin/true", home: root)
        XCTAssertEqual(AgentIntegration.claudeStatus(home: root).state, .connected)
        _ = try AgentIntegration.configure(agent: "claude", executable: "/usr/bin/true", home: root)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".bak-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), original)
        _ = try AgentIntegration.configure(agent: "claude", executable: nil, home: root)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
        XCTAssertEqual(restored, try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary)
        XCTAssertEqual(AgentIntegration.claudeStatus(home: root).state, .notConfigured)
        let unmanaged = #"{"mcpServers":{"contextweave":{"command":"custom"}}}"#
        try unmanaged.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentIntegration.configure(agent: "claude", executable: nil, home: root))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), unmanaged)
        try "broken JSON".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIntegration.claudeStatus(home: root).state, .unreadable)
        XCTAssertThrowsError(try AgentIntegration.configure(agent: "claude", executable: "/usr/bin/true", home: root))
    }

    func testCLIAndDesktopIncrementalCaptureOrderingToolsTitlesAndHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("claude/projects")
        let folder = projects.appendingPathComponent("encoded-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("workspace").path
        let ids = [UUID().uuidString, UUID().uuidString]
        func event(_ id: String, _ uuid: String, _ entrypoint: String, _ type: String, _ content: Any) -> [String: Any] {
            ["sessionId": id, "uuid": uuid, "cwd": workspace, "entrypoint": entrypoint,
             "timestamp": "2026-11-18T10:00:00.000Z", "type": type, "message": ["role": type, "content": content]]
        }
        let files = ids.map { folder.appendingPathComponent($0 + ".jsonl") }
        let first = event(ids[0], "zz-user", "cli", "user", "Inspect \(workspace)/Main.swift")
        let answer = event(ids[0], "aa-assistant", "cli", "assistant", [
            ["type": "text", "text": "Reviewing source"],
            ["type": "thinking", "thinking": "not captured"],
            ["type": "tool_use", "id": "call1", "name": "Read", "input": ["file_path": workspace + "/Main.swift"]]
        ] as [[String: Any]])
        try jsonl([first, answer]).write(to: files[0], atomically: true, encoding: .utf8)
        try jsonl([event(ids[1], "desktop-user", "claude-desktop", "user", "Desktop task")]).write(to: files[1], atomically: true, encoding: .utf8)
        let nested = folder.appendingPathComponent("\(ids[0])/subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try jsonl([first]).write(to: nested.appendingPathComponent(UUID().uuidString + ".jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("db.sqlite"), claudeRoot: projects))
        let report = await service.scan(only: ["claude"])
        XCTAssertTrue(report.errors.isEmpty, report.errors.joined(separator: "\n")); XCTAssertEqual(report.imported, 2)
        let id = try SessionID(agent: "claude", externalID: ids[0])
        let initial = try await service.session(id)
        XCTAssertEqual(initial?.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertFalse(initial?.messages.contains { $0.content.contains("not captured") } ?? true)
        XCTAssertEqual(initial?.messages.first?.id, "zz-user")
        let unchanged = await service.scan(only: ["claude"]); XCTAssertEqual(unchanged.unchanged, 2)
        let tail = try jsonl([
            answer, // Replayed message must update, not duplicate or reorder.
            event(ids[0], "tool-result", "cli", "user", [["type": "tool_result", "tool_use_id": "call1", "content": "File contents"]]),
            ["type": "custom-title", "sessionId": ids[0], "customTitle": "Renamed Claude task"]
        ])
        let handle = try FileHandle(forWritingTo: files[0]); try handle.seekToEnd(); try handle.write(contentsOf: Data(tail.utf8)); try handle.close()
        let appended = await service.scan(only: ["claude"]); XCTAssertTrue(appended.errors.isEmpty)
        let captured = try await service.session(id)
        XCTAssertEqual(captured?.messages.map(\.role), [.user, .assistant, .tool, .tool])
        let sessions = try await service.sessions(); XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.id == id }?.title, "Renamed Claude task")
        let project = try XCTUnwrap(sessions.first?.stableProjectID)
        let context = try await service.context(project: project, targetAgent: "codex")
        XCTAssertTrue(context.contains("File contents")); XCTAssertFalse(context.contains(workspace))
        _ = try await service.logProgress(project: project, agent: "codex", done: "CODEX_TO_CLAUDE_TEST", next: "Continue", issues: "")
        let returned = try await service.context(project: project, targetAgent: "claude")
        XCTAssertTrue(returned.contains("CODEX_TO_CLAUDE_TEST"))
        try FileManager.default.removeItem(at: files[0])
        let removed = await service.scan(only: ["claude"]); XCTAssertEqual(removed.archived, 1)
    }

    func testClaudePartialLineSidechainsAndMixedIDs() throws {
        let line = try jsonl([["type": "user", "sessionId": "main", "uuid": "u1", "cwd": "/tmp/project", "message": ["content": "Hello"]]])
        let bytes = Data(line.utf8)
        let first = try SessionParser.consume(Data(bytes.prefix(20)), agent: "claude", path: "/tmp/session.jsonl", state: CaptureState(agent: "claude"))
        XCTAssertNil(first.session); XCTAssertEqual(first.pendingBytes, 20)
        let complete = try SessionParser.consume(bytes, agent: "claude", path: "/tmp/session.jsonl", state: first.state)
        XCTAssertEqual(complete.session?.messages.count, 1)
        let sidechain = try jsonl([["type": "user", "sessionId": "side", "isSidechain": true, "message": ["content": "Ignore"]]])
        XCTAssertNil(try SessionParser.parse(sidechain, agent: "claude", path: "/tmp/side.jsonl"))
        let mixed = line + line.replacingOccurrences(of: "main", with: "different")
        XCTAssertThrowsError(try SessionParser.parse(mixed, agent: "claude", path: "/tmp/mixed.jsonl"))
    }
}
