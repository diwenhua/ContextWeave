import XCTest
@testable import ContextWeaveCore

final class ProjectIdentityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func service(_ root: URL, device: String = "device-a") throws -> HandoffService {
        try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("c"), dshRoot: root.appendingPathComponent("d"), databaseURL: root.appendingPathComponent("db.sqlite"), deviceIdentityDirectory: root.appendingPathComponent(device)))
    }
    func testDeviceIdentityIsSharedAcrossDatabaseLocations() async throws {
        let root = try temporaryDirectory(), identity = root.appendingPathComponent("settings")
        let first = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("c"), dshRoot: root.appendingPathComponent("d"), databaseURL: root.appendingPathComponent("one/db.sqlite"), deviceIdentityDirectory: identity))
        let second = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("c"), dshRoot: root.appendingPathComponent("d"), databaseURL: root.appendingPathComponent("two/db.sqlite"), deviceIdentityDirectory: identity))
        let one = await first.localDeviceID(), two = await second.localDeviceID()
        XCTAssertEqual(one, two)
        XCTAssertNotNil(UUID(uuidString: one))
    }
    func testTitlePathMaskingLeavesURLsIntact() {
        let title = "Open /Users/alice/Projects/private and ~/work/demo; see https://github.com/example/repo"
        let output = MetadataPrivacy.redactPaths(title)
        XCTAssertFalse(output.contains("/Users/alice")); XCTAssertFalse(output.contains("~/work"))
        XCTAssertTrue(output.contains("https://github.com/example/repo"))
    }
    func testBindingsPersistGroupPathsAndIsolateSameNamedFolders() async throws {
        let root = try temporaryDirectory(), first = try service(root)
        let original = "/tmp/team-a/my-project", alias = "/tmp/team-b/renamed", other = "/tmp/team-c/my-project"
        _ = try await first.logProgress(project: original, agent: "codex", done: "original progress")
        _ = try await first.logProgress(project: other, agent: "dsh", done: "unrelated progress")
        let before = try await first.workspaceBindings()
        let canonicalOriginal = try ProjectIdentity.canonicalPath(original), canonicalOther = try ProjectIdentity.canonicalPath(other)
        let projectID = try XCTUnwrap(before.first { $0.path == canonicalOriginal }?.projectID)
        let otherID = try XCTUnwrap(before.first { $0.path == canonicalOther }?.projectID)
        XCTAssertNotEqual(projectID, otherID)
        let bound = try await first.bindWorkspace(alias, toProjectID: projectID)
        XCTAssertEqual(bound.projectID, projectID)
        let context = try await first.context(project: alias, targetAgent: "dsh")
        XCTAssertTrue(context.contains("original progress")); XCTAssertTrue(context.contains(projectID)); XCTAssertFalse(context.contains("unrelated progress"))
        let otherContext = try await first.context(project: other, targetAgent: "codex")
        XCTAssertTrue(otherContext.contains("unrelated progress")); XCTAssertFalse(otherContext.contains("original progress"))
        let sameBinding = try await first.bindWorkspace(alias, toProjectID: projectID)
        XCTAssertEqual(sameBinding.id, bound.id)
        do { _ = try await first.bindWorkspace(other, toProjectID: projectID); XCTFail("must refuse reassignment") } catch { XCTAssertTrue(error.localizedDescription.contains("already bound")) }
        let reopened = try self.service(root)
        let after = try await reopened.workspaceBindings()
        XCTAssertEqual(before.first { $0.path == canonicalOriginal }?.id, after.first { $0.path == canonicalOriginal }?.id)
        let device1 = await first.localDeviceID(), device2 = await reopened.localDeviceID()
        XCTAssertEqual(device1, device2)
        let restored = try await reopened.context(project: alias, targetAgent: "dsh")
        XCTAssertTrue(restored.contains("original progress"))
    }
    func testDeviceScopedBindingsRequireExplicitAssociation() async throws {
        let root = try temporaryDirectory(), a = try service(root, device: "a"), b = try service(root, device: "b")
        let path = "/tmp/same-name/project"
        _ = try await a.logProgress(project: path, agent: "codex", done: "device a record")
        let aBindings = try await a.workspaceBindings(), bBefore = try await b.workspaceBindings()
        let original = try XCTUnwrap(aBindings.first)
        XCTAssertTrue(bBefore.isEmpty)
        let bBeforeContext = try await b.context(project: path, targetAgent: "dsh")
        XCTAssertFalse(bBeforeContext.contains("device a record"))
        let bBinding = try await b.bindWorkspace(path, toProjectID: original.projectID)
        XCTAssertNotEqual(original.deviceID, bBinding.deviceID)
        XCTAssertNotEqual(original.id, bBinding.id)
        let bAfterContext = try await b.context(project: path, targetAgent: "dsh")
        XCTAssertTrue(bAfterContext.contains("device a record"))
        let bAgain = try service(root, device: "b")
        let bDeviceID = await b.localDeviceID(), reopenedID = await bAgain.localDeviceID()
        XCTAssertEqual(bDeviceID, reopenedID)
    }
    func testExplicitReassignmentMovesOnlySoleWorkspaceRecords() async throws {
        let root = try temporaryDirectory(), service = try service(root)
        let source = "/tmp/source-project", target = "/tmp/target-project"
        let sourceNote = try await service.logProgress(project: source, agent: "dsh", done: "source note")
        let targetNote = try await service.logProgress(project: target, agent: "codex", done: "target note")
        let old = try XCTUnwrap(sourceNote.stableProjectID), new = try XCTUnwrap(targetNote.stableProjectID)
        do { _ = try await service.bindWorkspace(source, toProjectID: new, expectedPreviousProjectID: UUID().uuidString); XCTFail("stale identity must fail") } catch {}
        let before = try await service.context(project: source, targetAgent: "codex")
        XCTAssertTrue(before.contains("source note")); XCTAssertFalse(before.contains("target note"))
        _ = try await service.bindWorkspace(source, toProjectID: new, expectedPreviousProjectID: old)
        let after = try await service.context(project: source, targetAgent: "codex")
        XCTAssertTrue(after.contains("source note")); XCTAssertTrue(after.contains("target note"))
        let targetAfter = try await service.context(project: target, targetAgent: "codex")
        XCTAssertTrue(targetAfter.contains("source note")); XCTAssertTrue(targetAfter.contains("target note"))
        let store = try SessionStore(url: root.appendingPathComponent("db.sqlite"), deviceID: await service.localDeviceID())
        let notes = try store.progress(project: ProjectIdentity.canonicalPath(source))
        XCTAssertEqual(notes.first { $0.done == "source note" }?.stableProjectID, new)
        // Distinct workspace aliases are not silently moved as a group.
        do { _ = try await service.bindWorkspace(source, toProjectID: old, expectedPreviousProjectID: new); XCTFail("multi-binding reassignment must fail") } catch {}
        let bindings = try await service.workspaceBindings()
        XCTAssertEqual(bindings.first { $0.path == (try? ProjectIdentity.canonicalPath(source)) }?.projectID, new)
    }
    func testLegacyV3MigrationPreservesMessagesProgressAndCursor() async throws {
        let root = try temporaryDirectory(), db = root.appendingPathComponent("db.sqlite"), path = "/tmp/legacy-project"
        let note = ProgressEntry(id: "old-progress", project: path, agent: "codex", done: "preserved progress", next: "", issues: "", timestamp: 123)
        let payload = String(decoding: try JSONEncoder().encode(note), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE sessions(agent TEXT NOT NULL, external_id TEXT NOT NULL, project TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL, activity INTEGER NOT NULL, source_path TEXT NOT NULL, ordinals INTEGER NOT NULL, PRIMARY KEY(agent, external_id));
        CREATE TABLE messages(agent TEXT NOT NULL, external_id TEXT NOT NULL, message_id TEXT NOT NULL, source_path TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, timestamp INTEGER, ordinal INTEGER NOT NULL, PRIMARY KEY(agent, external_id, message_id));
        CREATE TABLE capture_files(path TEXT PRIMARY KEY, inode TEXT NOT NULL, parser_version TEXT NOT NULL, observed_size INTEGER NOT NULL, observed_mtime_ms INTEGER NOT NULL, offset INTEGER NOT NULL, pending TEXT NOT NULL, line_index INTEGER NOT NULL, external_id TEXT, project TEXT, ordinals INTEGER NOT NULL, rejected INTEGER NOT NULL);
        CREATE TABLE progress(id TEXT PRIMARY KEY, project TEXT NOT NULL, payload TEXT NOT NULL, timestamp INTEGER NOT NULL);
        INSERT INTO sessions VALUES('codex','legacy','\(path)','old title',1,123,'/tmp/source.jsonl',0);
        INSERT INTO messages VALUES('codex','legacy','1','/tmp/source.jsonl','user','preserved message',123,1000);
        INSERT INTO progress VALUES('old-progress','\(path)','\(payload)',123);
        INSERT INTO capture_files VALUES('/tmp/source.jsonl','1:2','v1',500,123,480,'pending',4,'legacy','\(path)',0,0);
        PRAGMA user_version=3;
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); p.arguments = [db.path, sql]
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
        let service = try service(root)
        let sessions = try await service.sessions(project: path); XCTAssertEqual(sessions.count, 1)
        let projectID = try XCTUnwrap(sessions.first?.stableProjectID)
        let bindings = try await service.workspaceBindings(); XCTAssertEqual(bindings.count, 1); XCTAssertEqual(bindings.first?.projectID, projectID)
        let stored = try await service.session(SessionID(agent: "codex", externalID: "legacy"))
        XCTAssertEqual(stored?.messages.map(\.content), ["preserved message"])
        let context = try await service.context(project: path, targetAgent: "dsh")
        XCTAssertTrue(context.contains("preserved message")); XCTAssertTrue(context.contains("preserved progress"))
        let offset = try await service.capturedOffset("/tmp/source.jsonl"); XCTAssertEqual(offset, 480)
        let reopened = try self.service(root)
        let again = try await reopened.workspaceBindings(); XCTAssertEqual(again, bindings)
    }
    func testMigrationFailureRollsBackSchemaAndRecords() throws {
        let root = try temporaryDirectory(), db = root.appendingPathComponent("db.sqlite")
        let sql = """
        CREATE TABLE sessions(agent TEXT NOT NULL, external_id TEXT NOT NULL, project TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL, activity INTEGER NOT NULL, source_path TEXT NOT NULL, ordinals INTEGER NOT NULL, PRIMARY KEY(agent, external_id));
        CREATE TABLE messages(agent TEXT NOT NULL, external_id TEXT NOT NULL, message_id TEXT NOT NULL, source_path TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, timestamp INTEGER, ordinal INTEGER NOT NULL, PRIMARY KEY(agent, external_id, message_id));
        CREATE TABLE capture_files(path TEXT PRIMARY KEY, inode TEXT NOT NULL, parser_version TEXT NOT NULL, observed_size INTEGER NOT NULL, observed_mtime_ms INTEGER NOT NULL, offset INTEGER NOT NULL, pending TEXT NOT NULL, line_index INTEGER NOT NULL, external_id TEXT, project TEXT, ordinals INTEGER NOT NULL, rejected INTEGER NOT NULL);
        CREATE TABLE progress(id TEXT PRIMARY KEY, project TEXT NOT NULL, payload TEXT NOT NULL, timestamp INTEGER NOT NULL);
        INSERT INTO sessions VALUES('codex','bad','relative-path','preserve',0,0,'/tmp/source',0);
        PRAGMA user_version=3;
        """
        let setup = Process(); setup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); setup.arguments = [db.path, sql]
        try setup.run(); setup.waitUntilExit(); XCTAssertEqual(setup.terminationStatus, 0)
        XCTAssertThrowsError(try SessionStore(url: db))
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = [db.path, "SELECT project FROM sessions WHERE external_id='bad'; SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='projects'; PRAGMA user_version;"]
        let pipe = Pipe(); check.standardOutput = pipe
        try check.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); check.waitUntilExit()
        XCTAssertEqual(output, "relative-path\n0\n3\n")
    }
    func testOlderWriterCannotInsertPathOnlySession() async throws {
        let root = try temporaryDirectory(), service = try service(root)
        _ = try await service.logProgress(project: "/tmp/bound", agent: "codex", done: "exists")
        let sql = "INSERT INTO sessions(agent,external_id,project,title,message_count,activity,source_path,ordinals) VALUES('codex','old-writer','/private/tmp/bound','old',0,0,'/tmp/s',0);"
        let old = Process(); old.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        old.arguments = [root.appendingPathComponent("db.sqlite").path, sql]; old.standardError = FileHandle.nullDevice
        try old.run(); old.waitUntilExit(); XCTAssertNotEqual(old.terminationStatus, 0)
        let sessions = try await service.sessions(); XCTAssertTrue(sessions.isEmpty)
    }
    func testMCPProjectDiscoveryAndExplicitWorkspaceBinding() async throws {
        let root = try temporaryDirectory(), service = try service(root)
        let note = try await service.logProgress(project: "/tmp/project", agent: "codex", done: "ready")
        let id = try XCTUnwrap(note.stableProjectID), handler = MCPHandler(service: service)
        func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let response = await handler.handle(try JSONSerialization.data(withJSONObject: request))
            return try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
        }
        let list = try await call("memory_list_projects", [:])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
        XCTAssertTrue(text.contains(id)); XCTAssertFalse(text.contains("deviceID")); XCTAssertFalse(text.contains("workspaces"))
        let resolution = try await call("memory_resolve_workspace", ["path": "/tmp/project"])
        let resolutionText = String(decoding: try JSONSerialization.data(withJSONObject: resolution), as: UTF8.self)
        XCTAssertTrue(resolutionText.contains(id)); XCTAssertFalse(resolutionText.contains("/tmp/project"))
        let binding = try await call("memory_bind_workspace", ["path": "/tmp/project-alias", "project_id": id])
        XCTAssertNil((binding["result"] as? [String: Any])?["isError"])
        let context = try await service.context(project: "/tmp/project-alias", targetAgent: "dsh")
        XCTAssertTrue(context.contains("ready")); XCTAssertTrue(context.contains(id))
    }
    func testDefaultMCPMetadataOmitsPathsAndSupportsProjectIDs() async throws {
        let root = try temporaryDirectory(), logs = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let workspace = "/tmp/private-client/project"
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "private-s1", "cwd": workspace]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "a safe message"]]]]
        ]
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try lines.write(to: logs.appendingPathComponent("rollout-private.jsonl"), atomically: true, encoding: .utf8)
        let service = try service(root); _ = await service.scan()
        let bindings = try await service.workspaceBindings(); let id = try XCTUnwrap(bindings.first?.projectID)
        let handler = MCPHandler(service: service)
        func call(_ name: String, _ args: [String: Any]) async throws -> String {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
            let response = await handler.handle(try JSONSerialization.data(withJSONObject: request))
            let rpc = try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
            let result = try XCTUnwrap(rpc["result"] as? [String: Any]); XCTAssertNil(result["isError"])
            let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
            return try XCTUnwrap(blocks.first?["text"] as? String)
        }
        let requests: [(String, [String: Any])] = [
            ("memory_list_projects", [:]),
            ("memory_scan", [:]),
            ("memory_list_sessions", ["project": id]),
            ("memory_get_context", ["project": id, "target_agent": "dsh"]),
            ("memory_get_session", ["project": id, "agent": "codex", "session_id": "private-s1"]),
            ("memory_log_progress", ["project": id, "agent": "codex", "done": "finished"])
        ]
        for (name, args) in requests {
            let output = try await call(name, args)
            XCTAssertFalse(output.contains("private-client"), "\(name) leaked workspace path")
            XCTAssertFalse(output.contains(root.path), "\(name) leaked source or settings path")
            XCTAssertFalse(output.contains("sourcePath"), "\(name) leaked source metadata")
        }
        let context = try await call("memory_get_context", ["project": workspace, "target_agent": "dsh"])
        XCTAssertTrue(context.contains("finished")); XCTAssertFalse(context.contains("private-client"))
    }
    func testSameProjectSessionsCanBeAccessedThroughAliasViaMCP() async throws {
        let root = try temporaryDirectory(), logs = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "s1", "cwd": "/tmp/original"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "test handoff"]]]]
        ]
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try lines.write(to: logs.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let service = try service(root); let scan = await service.scan()
        XCTAssertTrue(scan.errors.isEmpty, scan.errors.joined(separator: "\n"))
        let records = try await service.workspaceBindings(); let original = try XCTUnwrap(records.first)
        _ = try await service.bindWorkspace("/tmp/alias", toProjectID: original.projectID)
        let sessions = try await service.sessions(project: "/tmp/alias")
        XCTAssertEqual(sessions.count, 1); XCTAssertEqual(sessions.first?.stableProjectID, original.projectID)
        let handler = MCPHandler(service: service)
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "memory_get_session", "arguments": ["project": "/tmp/alias", "agent": "codex", "session_id": "s1"]]]
        let response = await handler.handle(try JSONSerialization.data(withJSONObject: request))
        let result = try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
        let body = result["result"] as! [String: Any]
        XCTAssertNil(body["isError"])
        XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains("test handoff"))
        let forbidden: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "memory_get_session", "arguments": ["project": "/tmp/unknown", "agent": "codex", "session_id": "s1"]]]
        let deniedResponse = await handler.handle(try JSONSerialization.data(withJSONObject: forbidden))
        let denied = try JSONSerialization.jsonObject(with: XCTUnwrap(deniedResponse)) as! [String: Any]
        XCTAssertEqual((denied["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
}
