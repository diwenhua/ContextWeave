import XCTest
@testable import ContextWeaveCore

final class LiveMemoryTests: XCTestCase {
    func testSyntheticDeepSeekHandoff() async throws {
        guard ProcessInfo.processInfo.environment["CW_LIVE_MEMORY"] == "1" else {
            throw XCTSkip("Requires explicit live model invocation")
        }
        let model = SettingsFile.load().memoryModel
        let endpoint = try model.validatedEndpoint()
        guard endpoint.host == "api.deepseek.com", endpoint.scheme == "https" else {
            throw CaptureError.invalid("Live fixture expects configured DeepSeek endpoint")
        }
        let key = try XCTUnwrap(MemoryModelKeychain.load(endpoint: endpoint))
        let retained = ProcessInfo.processInfo.environment["CW_LIVE_FIXTURE"]
        let root = retained.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        let db = root.appendingPathComponent("fixture.sqlite")
        let id = try SessionID(agent: "codex", externalID: "fixture")
        let path = root.appendingPathComponent("fixture.jsonl").path
        let text = "For this fictional project we decided to store recipes in SQLite. Next implement recipe import."
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path,
                              messages: [SessionMessage(id: "1", role: .user, content: text, timestampMilliseconds: 1)])
        let cursor = FileCursor(inode: "1", parserVersion: "fixture", observedSize: 1, observedMtimeMS: 1, offset: 1, pending: "", lineIndex: 1, externalID: id.externalID, project: root.path, ordinals: false, rejected: false)
        let store = try SessionStore(url: db)
        try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: true, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root, dshRoot: root, databaseURL: db))
        try await service.extractSemanticMemory(session: id, model: model, apiKey: key)
        let memories = try await service.sessionMemory(id)
        let decision = try XCTUnwrap(memories.first { $0.status == "candidate" && $0.content.localizedCaseInsensitiveContains("SQLite") })
        XCTAssertEqual(decision.sourceMessageID, "1")
        try await service.setMemoryStatus(id: decision.id, status: "confirmed")
        try await service.setMemoryScope(id: decision.id, scope: "project")
        // Place the replacement decision beyond the previous 2,000-character cutoff.
        let longText = String(repeating: "This is background for the fictional recipe import acceptance test. ", count: 350)
            + "Final explicit decision: replace SQLite with PostgreSQL as the only recipe database. This supersedes our previous SQLite decision."
        let updated = Session(source: session.source, projectID: root.path, messages: session.messages + [SessionMessage(id: "2", role: .user, content: longText, timestampMilliseconds: 2)])
        var nextCursor = cursor
        nextCursor.observedSize = 2
        try store.commitCapture(path: path, cursor: nextCursor, session: updated, fullReplace: true, previousAgent: nil, previousExternalID: nil, expectedCursor: cursor)
        try await service.extractSemanticMemory(session: id, model: model, apiKey: key)
        let conflicts = try await service.memoryConflicts()
        let conflict = try XCTUnwrap(conflicts.first { $0.confirmedID == decision.id })
        let extracted = try store.memories(agent: id.agent, externalID: id.externalID)
        let replacement = try XCTUnwrap(extracted.first { $0.id == conflict.candidateID })
        XCTAssertTrue(replacement.content.localizedCaseInsensitiveContains("PostgreSQL"))
        XCTAssertEqual(replacement.sourceMessageID, "2")
        if retained != nil {
            // Retain unresolved review state for actual GUI acceptance.
            let reviewDB = root.appendingPathComponent("review.sqlite")
            let backup = Process()
            backup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            backup.arguments = [db.path, ".backup '" + reviewDB.path.replacingOccurrences(of: "'", with: "''") + "'"]
            try backup.run()
            backup.waitUntilExit()
            XCTAssertEqual(backup.terminationStatus, 0)
            let settings = AppSettings(codexSessionsPath: root.appendingPathComponent("missing-codex").path, dshSessionsPath: root.appendingPathComponent("missing-dsh").path, cursorUserPath: root.appendingPathComponent("missing-cursor").path, databasePath: reviewDB.path, watchAutomatically: false, memoryModel: model)
            try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        }
        try await service.replaceMemory(decision.id, with: replacement.id)
        for agent in ["dsh", "cursor"] {
            let handoff = try await service.context(project: root.path, targetAgent: agent)
            XCTAssertTrue(handoff.contains(replacement.content))
        }
    }
}
