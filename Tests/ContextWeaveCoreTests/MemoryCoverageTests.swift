import XCTest
import CSQLite
@testable import ContextWeaveCore

final class MemoryCoverageTests: XCTestCase {
    private func fixture() throws -> (URL, SessionStore, SessionID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try SessionStore(url: root.appendingPathComponent("db.sqlite")), try SessionID(agent: "codex", externalID: "selected"))
    }
    private func message(_ n: Int, _ content: String? = nil, role: SessionMessage.Role = .user) -> SessionMessage {
        SessionMessage(id: String(n), role: role, content: content ?? "Message \(n)", timestampMilliseconds: Int64(n))
    }
    private func append(_ messages: [SessionMessage], store: SessionStore, id: SessionID, root: URL) throws {
        let path = root.appendingPathComponent(id.externalID).path
        let previous = try store.cursors(path: path)[path]
        let cursor = FileCursor(inode: "1", parserVersion: "test", observedSize: (previous?.observedSize ?? 0) + 1, observedMtimeMS: 1, offset: 0, pending: "", lineIndex: 0, externalID: id.externalID, project: root.path, ordinals: true, rejected: false)
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path, messages: messages)
        try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: false, previousAgent: id.agent, previousExternalID: id.externalID, expectedCursor: previous)
    }
    private func service(_ root: URL) throws -> HandoffService {
        try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("absent-codex"), dshRoot: root.appendingPathComponent("absent-dsh"), databaseURL: root.appendingPathComponent("db.sqlite")))
    }
    private func sql(_ root: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("db.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testCoverageAppendMutationAndAutoUpdateStates() throws {
        let (root, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try append([message(1), message(2, role: .tool), message(3, role: .assistant)], store: store, id: id, root: root)
        XCTAssertEqual(try store.memoryCoverage(id).status, "missing")
        let expected = try store.semanticPage(id, offset: 0, limit: 40)
        try store.saveSemanticMemory(.init(checkpoint: "A summary", candidates: []), session: id, expected: expected)
        let current = try store.memoryCoverage(id)
        XCTAssertEqual(current.status, "current"); XCTAssertEqual(current.coveredMessages, 3)
        XCTAssertEqual(current.coveredDialogueMessages, 2); XCTAssertEqual(current.lastCoveredMessageID, "3")
        XCTAssertEqual(current.autoUpdate, "off")
        try append([message(4)], store: store, id: id, root: root)
        let stale = try store.memoryCoverage(id)
        XCTAssertEqual(stale.status, "stale"); XCTAssertEqual(stale.uncoveredMessages, 1)
        let model = MemoryModelConfiguration(endpoint: "http://127.0.0.1", model: "mock")
        try store.watch(id, model: model)
        XCTAssertEqual(try store.memoryCoverage(id).autoUpdate, "accumulating")
        XCTAssertEqual(try store.memoryCoverage(id, model: .init(endpoint: model.endpoint, model: "different")).autoUpdate, "model_changed")
        let revision = try XCTUnwrap(store.watched(model, due: true).first?.1)
        try store.finishWatch(id, revision: revision, success: false)
        XCTAssertEqual(try store.memoryCoverage(id).autoUpdate, "retrying")
        try append([message(1, "Changed old source")], store: store, id: id, root: root)
        let invalid = try store.memoryCoverage(id)
        XCTAssertEqual(invalid.status, "unknown"); XCTAssertEqual(invalid.reason, "covered_source_changed")
        XCTAssertEqual(invalid.coveredMessages, 0)
    }

    func testExtractionRejectsChangesToEarlierCoveredPrefix() throws {
        let (root, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try append((1...41).map { message($0) }, store: store, id: id, root: root)
        let batch = try store.semanticPage(id, offset: 40, limit: 40)
        let snapshot = try store.memorySourceSnapshot(id, through: "41")
        try append([message(1, "Changed while model was running")], store: store, id: id, root: root)
        XCTAssertThrowsError(try store.saveSemanticMemory(.init(checkpoint: "incorrect", candidates: []), session: id, expected: batch, offset: 40, sourceSnapshot: snapshot))
        XCTAssertEqual(try store.memoryCoverage(id).status, "missing")
    }

    func testLegacySummaryMigrationStaysUnknownAndCatchUpIsBounded() async throws {
        let (root, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try append((1...60).map { message($0, $0 == 1 ? String(repeating: "large tool output ", count: 2000) : "NEW_\($0)", role: $0 == 1 ? .tool : .user) }, store: store, id: id, root: root)
        let project = try XCTUnwrap(store.summary(id)?.stableProjectID)
        try sql(root, "INSERT INTO memories(id,stable_project_id,agent,external_id,kind,content,updated_at,status,scope) VALUES('legacy','\(project)','codex','selected','summary','OLD_SUMMARY',1,'checkpoint','session'); DROP TABLE semantic_coverage; PRAGMA user_version=13")
        let service = try service(root)
        let coverage = try await service.memoryCoverage(id)
        XCTAssertEqual(coverage.status, "unknown"); XCTAssertEqual(coverage.reason, "legacy_checkpoint_without_boundary")
        let delta = try await service.memoryCatchUp(id, coverage: coverage, limit: 5)
        XCTAssertEqual(delta.offset, 0); XCTAssertEqual(delta.nextOffset, 5)
        XCTAssertEqual(delta.messages.count, 5); XCTAssertEqual(delta.latestMessages.last?.id, "60")
        XCTAssertTrue(delta.truncatedMessageIDs.contains("1")); XCTAssertLessThan(delta.messages[0].content.count, 1400)
        let next = try await service.memoryCatchUp(id, coverage: coverage, limit: 5, from: 5)
        XCTAssertEqual(next.messages.first?.id, "6"); XCTAssertEqual(next.nextOffset, 10)
        let context = try await service.context(project: project, targetAgent: "claude", sessionID: id)
        XCTAssertTrue(context.contains("Status: unknown")); XCTAssertTrue(context.contains("NEW_60"))
        XCTAssertTrue(context.contains("offset=0"))
    }

    func testReadAgentReturnsDeltaWithProgressAndKeepsExactSession() async throws {
        let (root, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try append([message(1),message(2, role: .assistant)], store: store, id: id, root: root)
        try store.saveSemanticMemory(.init(checkpoint: "checkpoint", candidates: []), session: id, expected: store.semanticPage(id, offset: 0, limit: 40))
        try append((3...45).map { message($0) }, store: store, id: id, root: root)
        let other = try SessionID(agent: "codex", externalID: "other")
        try append([message(100, "WRONG_CONVERSATION")], store: store, id: other, root: root)
        let project = try XCTUnwrap(store.summary(id)?.stableProjectID)
        let handler = MCPHandler(service: try service(root))
        func read(_ offset: Int? = nil) async throws -> [String: Any] {
            var args: [String: Any] = ["project": project, "agent": "codex", "session_id": "selected"]
            if let offset { args["offset"] = offset }
            let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "memory_read_agent", "arguments": args]])
            let response = await handler.handle(request)
            let data = try XCTUnwrap(response)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let response = try await read()
        let selected = try XCTUnwrap(response["selected"] as? [String: Any])
        XCTAssertEqual(selected["sessionID"] as? String, "selected")
        XCTAssertEqual(selected["offset"] as? Int, 2)
        XCTAssertEqual((selected["coverage"] as? [String: Any])?["status"] as? String, "stale")
        let delta = try XCTUnwrap(selected["catchUp"] as? [String: Any])
        XCTAssertEqual(delta["nextOffset"] as? Int, 14)
        let again = try await read(14)
        let second = try XCTUnwrap(again["selected"] as? [String: Any])
        XCTAssertEqual((second["catchUp"] as? [String: Any])?["nextOffset"] as? Int, 34)
        let context = try await service(root).context(project: project, targetAgent: "claude", sessionID: id)
        XCTAssertFalse(context.contains("WRONG_CONVERSATION"))
    }
}
