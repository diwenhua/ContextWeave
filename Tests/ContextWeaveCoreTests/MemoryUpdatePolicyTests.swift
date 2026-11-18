import XCTest
import CSQLite
@testable import ContextWeaveCore

final class MemoryUpdatePolicyTests: XCTestCase {
    private let model = MemoryModelConfiguration(endpoint: "http://127.0.0.1/mock", model: "test")

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func add(_ name: String, agent: String = "codex", store: SessionStore, root: URL) throws -> SessionID {
        let id = try SessionID(agent: agent, externalID: name)
        let path = root.appendingPathComponent(name).path
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path, messages: [SessionMessage(id: "1", role: .user, content: name, timestampMilliseconds: 1)])
        let cursor = FileCursor(inode: "1", parserVersion: "test", observedSize: 1, observedMtimeMS: 1, offset: 1, pending: "", lineIndex: 1, externalID: name, project: root.path, ordinals: false, rejected: false)
        try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: false, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
        return id
    }
    private func execute(_ sql: String, root: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("db.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testAgentDefaultAppliesToExistingAndNewSessionsButNotOtherAgents() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(url: root.appendingPathComponent("db.sqlite"))
        let first = try add("existing", store: store, root: root)
        _ = try add("another-agent", agent: "claude", store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: [], model: model)
        XCTAssertTrue(try store.watched(model, due: false).isEmpty)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(try store.watched(model, due: true).map(\.0), [first])
        let newer = try add("new", store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(Set(try store.watched(model, due: true).map(\.0)), [first, newer])
        XCTAssertTrue(try store.memoryUpdatePreferences().isEmpty)
    }

    func testSessionOptOutPersistsAndCanReturnToInheritance() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        let store = try SessionStore(url: url)
        let id = try add("excluded", store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        try store.setMemoryUpdatePreference(id, preference: .disabled)
        XCTAssertTrue(try store.watched(model, due: true).isEmpty)
        let reopened = try SessionStore(url: url)
        try reopened.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(try reopened.memoryUpdatePreferences()[id], .disabled)
        XCTAssertTrue(try reopened.watched(model, due: true).isEmpty)
        try reopened.synchronizeMemoryUpdates(agents: [], model: model)
        try reopened.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertTrue(try reopened.watched(model, due: true).isEmpty)
        try reopened.setMemoryUpdatePreference(id, preference: .inherit)
        try reopened.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(try reopened.watched(model, due: true).map(\.0), [id])
        XCTAssertNil(try reopened.memoryUpdatePreferences()[id])
        try reopened.synchronizeMemoryUpdates(agents: [], model: model)
        XCTAssertTrue(try reopened.watched(model, due: true).isEmpty)
    }

    func testCleanJobsAndBackoffSurviveReconciliationAndOldCompletionCannotAcknowledgeNewPolicy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(url: root.appendingPathComponent("db.sqlite"))
        let id = try add("job", store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        let original = try XCTUnwrap(store.watched(model, due: true).first?.1)
        try store.finishWatch(id, revision: original, success: false)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertTrue(try store.watched(model, due: true).isEmpty)
        XCTAssertEqual(try store.memoryCoverage(id).autoUpdate, "retrying")
        try store.synchronizeMemoryUpdates(agents: [], model: model)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        let current = try XCTUnwrap(store.watched(model, due: true).first?.1)
        XCTAssertNotEqual(current, original)
        try store.finishWatch(id, revision: original, success: true)
        XCTAssertEqual(try store.watched(model, due: true).first?.1, current)
        try store.finishWatch(id, revision: current, success: true)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertTrue(try store.watched(model, due: true).isEmpty)
        let changed = MemoryModelConfiguration(endpoint: model.endpoint, model: "new-model")
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: changed)
        XCTAssertEqual(try store.watched(changed, due: true).map(\.0), [id])
        XCTAssertTrue(try store.watched(model, due: false).isEmpty)
    }

    func testLegacySubscriptionsMigrateToExplicitOptInAndArchivedJobsAreExcluded() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        var id: SessionID!
        do {
            let store = try SessionStore(url: url)
            id = try add("legacy", store: store, root: root)
            try store.watch(id, model: model)
        }
        execute("DROP TABLE semantic_preferences; ALTER TABLE semantic_watch DROP COLUMN enabled; PRAGMA user_version=14", root: root)
        let upgraded = try SessionStore(url: url)
        XCTAssertEqual(try upgraded.memoryUpdatePreferences()[id], .enabled)
        try upgraded.synchronizeMemoryUpdates(agents: [], model: model)
        XCTAssertEqual(try upgraded.watched(model, due: true).map(\.0), [id])
        execute("UPDATE sessions SET archived_at=1", root: root)
        try upgraded.synchronizeMemoryUpdates(agents: [], model: model)
        XCTAssertTrue(try upgraded.watched(model, due: false).isEmpty)
        XCTAssertEqual(try upgraded.memoryUpdatePreferences()[id], .enabled)
    }

    private func append(_ messages: [SessionMessage], id: SessionID, store: SessionStore, root: URL) throws {
        let path = root.appendingPathComponent(id.externalID).path
        let previous = try store.cursors(path: path)[path]
        let cursor = FileCursor(inode: "1", parserVersion: "test", observedSize: (previous?.observedSize ?? 0) + 1, observedMtimeMS: 1, offset: 1, pending: "", lineIndex: 1, externalID: id.externalID, project: root.path, ordinals: false, rejected: false)
        try store.commitCapture(path: path, cursor: cursor, session: Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path, messages: messages), fullReplace: false, previousAgent: id.agent, previousExternalID: id.externalID, expectedCursor: previous)
    }

    private func dialogue(_ n: Int, role: SessionMessage.Role = .user) -> SessionMessage {
        SessionMessage(id: String(n), role: role, content: "message \(n)", timestampMilliseconds: Int64(n))
    }

    func testThresholdCountsOnlyNewDialogueAcrossRepeatedScansAndRestart() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(url: root.appendingPathComponent("db.sqlite"))
        let id = try add("threshold", store: store, root: root)
        try append((2...19).map { dialogue($0, role: $0.isMultiple(of: 2) ? .assistant : .user) }, id: id, store: store, root: root)
        try append((100...199).map { dialogue($0, role: .tool) }, id: id, store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(try store.pendingDialogueMessages(id), 19)
        XCTAssertTrue(try store.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
        XCTAssertEqual(try store.memoryCoverage(id).autoUpdate, "accumulating")
        try append([dialogue(19)], id: id, store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        XCTAssertEqual(try store.pendingDialogueMessages(id), 19, "Replays and tool logs must not increase the count")
        let reopened = try SessionStore(url: root.appendingPathComponent("db.sqlite"))
        XCTAssertTrue(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
        try append([dialogue(20)], id: id, store: reopened, root: root)
        XCTAssertEqual(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 20).map(\.0), [id])
        let expected = try reopened.semanticPage(id, offset: 0, limit: 40)
        try reopened.saveSemanticMemory(.init(checkpoint: "20 messages covered", candidates: []), session: id, expected: expected)
        XCTAssertEqual(try reopened.pendingDialogueMessages(id), 0)
        XCTAssertTrue(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
        try append((21...39).map { dialogue($0) }, id: id, store: reopened, root: root)
        XCTAssertTrue(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
        XCTAssertEqual(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 10).map(\.0), [id])
        XCTAssertTrue(try reopened.pendingMemoryExtractions(model, minimumNewMessages: 40).isEmpty)
        // Manual extraction is allowed below the automatic threshold and resets the count.
        try reopened.saveSemanticMemory(.init(checkpoint: "manual update", candidates: []), session: id, expected: reopened.semanticPage(id, offset: 0, limit: 40))
        XCTAssertEqual(try reopened.pendingDialogueMessages(id), 0)
    }

    func testPartialFailureRetriesAfterBackoffEvenBelowThreshold() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(url: root.appendingPathComponent("db.sqlite"))
        let id = try add("partial", store: store, root: root)
        try append((2...45).map { dialogue($0) }, id: id, store: store, root: root)
        try store.synchronizeMemoryUpdates(agents: ["codex"], model: model)
        let revision = try XCTUnwrap(store.pendingMemoryExtractions(model, minimumNewMessages: 20).first?.1)
        try store.saveSemanticMemory(.init(checkpoint: "first 40", candidates: []), session: id, expected: store.semanticPage(id, offset: 0, limit: 40))
        XCTAssertEqual(try store.pendingDialogueMessages(id), 5)
        try store.finishWatch(id, revision: revision, success: false)
        XCTAssertTrue(try store.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
        execute("UPDATE semantic_watch SET retry_at=0", root: root)
        XCTAssertEqual(try store.pendingMemoryExtractions(model, minimumNewMessages: 20).map(\.0), [id])
        try store.setMemoryUpdatePreference(id, preference: .disabled)
        XCTAssertTrue(try store.pendingMemoryExtractions(model, minimumNewMessages: 20).isEmpty)
    }

    func testThresholdSettingsArePersistedAndOldOrInvalidValuesUseDefault() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.memoryAutoUpdateMessageThreshold, 20)
        for value in [0, -1, 999] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"memoryAutoUpdateMessageThreshold\":\(value)}".utf8))
            XCTAssertEqual(settings.memoryAutoUpdateMessageThreshold, 20)
        }
        let settings = AppSettings(memoryAutoUpdateMessageThreshold: 40)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).memoryAutoUpdateMessageThreshold, 40)
    }

    func testAgentSettingsRoundTripAndMissingKeyDefaultsOff() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.memoryAutoUpdateAgents.isEmpty)
        let settings = AppSettings(memoryAutoUpdateAgents: ["codex", "claude"])
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).memoryAutoUpdateAgents, ["codex", "claude"])
        XCTAssertTrue(MemoryUpdatePreference.inherit.isEnabled(agentDefault: true))
        XCTAssertFalse(MemoryUpdatePreference.disabled.isEnabled(agentDefault: true))
        XCTAssertTrue(MemoryUpdatePreference.enabled.isEnabled(agentDefault: false))
    }
}
