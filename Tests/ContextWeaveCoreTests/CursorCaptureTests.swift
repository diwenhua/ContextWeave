import Foundation
import XCTest
import CSQLite
@testable import ContextWeaveCore

final class CursorCaptureTests: XCTestCase {
    func testCaptureCursorHistoryUpdateAndProjectHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("Cursor/User")
        let global = user.appendingPathComponent("globalStorage")
        let workspace = user.appendingPathComponent("workspaceStorage/workspace-hash")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let workspaceJSON = try JSONSerialization.data(withJSONObject: ["folder": project.absoluteString])
        try workspaceJSON.write(to: workspace.appendingPathComponent("workspace.json"))
        let database = global.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { XCTAssertEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK) }
        sql("CREATE TABLE composerHeaders(composerId TEXT, workspaceId TEXT, value TEXT, isSubagent INTEGER)")
        sql("CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value BLOB)")
        func put(_ key: String, _ object: Any) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            sql("INSERT OR REPLACE INTO cursorDiskKV VALUES('\(key)', '\(text)')")
        }
        sql("INSERT INTO composerHeaders VALUES('session-a','workspace-hash','{}',0)")
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])
        try put("bubbleId:session-a:b1", ["type": 1, "text": "Work on \(project.path)/Sources/A.swift"])
        try put("bubbleId:session-a:b2", ["type": 2, "text": "Implemented it", "toolFormerData": ["name": "read_file", "result": ["path": project.path + "/Sources/A.swift", "content": "done"]]])
        let config = CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite"), cursorUserRoot: user)
        let service = try HandoffService(configuration: config)
        let first = await service.scan()
        XCTAssertEqual(first.imported, 1); XCTAssertTrue(first.errors.isEmpty)
        let id = try SessionID(agent: "cursor", externalID: "session-a")
        let loaded = try await service.session(id)
        XCTAssertEqual(loaded?.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertNil(loaded?.runState)
        let projectID = try XCTUnwrap(loaded?.stableProjectID)
        let forCodex = try await service.context(project: projectID, targetAgent: "codex")
        XCTAssertTrue(forCodex.contains("Implemented it")); XCTAssertTrue(forCodex.contains("[PROJECT]/Sources/A.swift"))
        XCTAssertFalse(forCodex.contains(project.path))
        let unchanged = await service.scan(); XCTAssertEqual(unchanged.unchanged, 1)
        try put("bubbleId:session-a:b2", ["type": 2, "text": "Updated answer", "toolFormerData": ["name": "read_file", "result": "done"]])
        let updated = await service.scan(); XCTAssertEqual(updated.imported, 1)
        let after = try await service.session(id); XCTAssertEqual(after?.messages[1].content, "Updated answer")
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "status": "generating", "generatingBubbleIds": ["b2"], "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])
        let running = await service.scan(); XCTAssertEqual(running.imported, 1)
        let runningSession = try await service.session(id); XCTAssertEqual(runningSession?.runState, .running)
        try put("bubbleId:session-a:b2", ["type": 2, "text": "Updated answer", "toolFormerData": ["name": "read_file", "status": "needs_user_approval", "result": "done"]])
        let waiting = await service.scan(); XCTAssertEqual(waiting.imported, 1)
        let waitingSession = try await service.session(id); XCTAssertEqual(waitingSession?.runState, .awaitingApproval)
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "status": "completed", "generatingBubbleIds": [], "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])
        let finished = await service.scan(); XCTAssertEqual(finished.imported, 1)
        let finishedSession = try await service.session(id); XCTAssertEqual(finishedSession?.runState, .finished)
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "status": "aborted", "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])
        let stopped = await service.scan(); XCTAssertEqual(stopped.imported, 1)
        let stoppedSession = try await service.session(id); XCTAssertEqual(stoppedSession?.runState, .aborted)
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        try put("bubbleId:session-a:b2", ["type": 2, "text": "Updated answer", "toolFormerData": ["name": "read_file", "result": "done"]])
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "status": "aborted", "unfinishedRunAt": nowMS - 300_000, "conversationCheckpointLastUpdatedAt": nowMS - 10_000, "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])
        let resumed = await service.scan(); XCTAssertEqual(resumed.imported, 1)
        let resumedSession = try await service.session(id); XCTAssertEqual(resumedSession?.runState, .running)
        try put("composerData:session-a", ["composerId": "session-a", "createdAt": 1234, "fullConversationHeadersOnly": [], "headerLog": ["chunkCount": 2, "count": 2]])
        try put("composerConvHeaders:session-a:000000", [["bubbleId": "b1", "type": 1]])
        try put("composerConvHeaders:session-a:000001", [["bubbleId": "b2", "type": 2]])
        let chunked = await service.scan(); XCTAssertEqual(chunked.imported, 1); XCTAssertTrue(chunked.errors.isEmpty)
        let chunkedSession = try await service.session(id); XCTAssertEqual(chunkedSession?.messages.map(\.role), [.user, .assistant, .tool])
        let namedHeader = try JSONSerialization.data(withJSONObject: ["name": "对话甲"])
        sql("UPDATE composerHeaders SET value='\(String(decoding: namedHeader, as: UTF8.self).replacingOccurrences(of: "'", with: "''"))' WHERE composerId='session-a'")
        let named = await service.scan(); XCTAssertEqual(named.imported, 1)
        let namedSummary = try await service.summary(id); XCTAssertEqual(namedSummary?.title, "对话甲")
        let renamedHeader = try JSONSerialization.data(withJSONObject: ["name": "对话乙"])
        sql("UPDATE composerHeaders SET value='\(String(decoding: renamedHeader, as: UTF8.self).replacingOccurrences(of: "'", with: "''"))' WHERE composerId='session-a'")
        let renamed = await service.scan(); XCTAssertEqual(renamed.imported, 1)
        let renamedSummary = try await service.summary(id)
        XCTAssertEqual(renamedSummary?.title, "对话乙")
        let projectBefore = try XCTUnwrap(namedSummary?.stableProjectID)
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        let relocatedJSON = try JSONSerialization.data(withJSONObject: ["folder": relocated.absoluteString])
        try relocatedJSON.write(to: workspace.appendingPathComponent("workspace.json"))
        try FileManager.default.removeItem(at: project)
        let followed = await service.scan(); XCTAssertEqual(followed.unchanged, 1); XCTAssertTrue(followed.errors.isEmpty, followed.errors.joined(separator: "\n"))
        let followedSummary = try await service.summary(id)
        let relocatedPath = try ProjectIdentity.canonicalPath(relocated.path)
        XCTAssertEqual(followedSummary?.stableProjectID, projectBefore)
        XCTAssertEqual(followedSummary?.projectID, relocatedPath)
        XCTAssertEqual(followedSummary?.title, "对话乙")
        sql("DELETE FROM cursorDiskKV WHERE key='composerConvHeaders:session-a:000001'")
        let incomplete = await service.scan(); XCTAssertFalse(incomplete.errors.isEmpty)
        let retained = try await service.session(id); XCTAssertEqual(retained?.messages.count, 3)
        _ = try await service.logProgress(project: projectID, agent: "dsh", done: "Harness completed tests")
        let forCursor = try await service.context(project: projectID, targetAgent: "cursor")
        XCTAssertTrue(forCursor.contains("Harness completed tests"))
    }

    func testAbortedStatusWithRecentCheckpointIsRunning() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)

        func composer(status: String, checkpoint: Int64?, unfinished: Int64?) -> [String: Any] {
            var value: [String: Any] = ["status": status, "generatingBubbleIds": [Any]()]
            if let checkpoint { value["conversationCheckpointLastUpdatedAt"] = NSNumber(value: checkpoint) }
            if let unfinished { value["unfinishedRunAt"] = NSNumber(value: unfinished) }
            return value
        }

        let active = composer(status: "aborted", checkpoint: nowMS - 15_000, unfinished: nowMS - 300_000)
        XCTAssertEqual(CursorCapture.runState(active, awaitingApproval: false, now: now), .running)

        let quiet = composer(status: "aborted", checkpoint: nowMS - 300_000, unfinished: nowMS - 600_000)
        XCTAssertEqual(CursorCapture.runState(quiet, awaitingApproval: false, now: now), .aborted)

        let waiting = composer(status: "aborted", checkpoint: nowMS - 15_000, unfinished: nowMS - 300_000)
        XCTAssertEqual(CursorCapture.runState(waiting, awaitingApproval: true, now: now), .awaitingApproval)

        let stoppedWithStaleApproval = composer(status: "aborted", checkpoint: nowMS - 300_000, unfinished: nowMS - 600_000)
        XCTAssertEqual(CursorCapture.runState(stoppedWithStaleApproval, awaitingApproval: true, now: now), .aborted)

        let finished = composer(status: "completed", checkpoint: nowMS - 15_000, unfinished: nowMS - 300_000)
        XCTAssertEqual(CursorCapture.runState(finished, awaitingApproval: false, now: now), .finished)

        let plainApproval = composer(status: "none", checkpoint: nil, unfinished: nil)
        XCTAssertEqual(CursorCapture.runState(plainApproval, awaitingApproval: true, now: now), .awaitingApproval)
    }
}
