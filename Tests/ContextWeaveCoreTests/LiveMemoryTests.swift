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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        for agent in ["dsh", "cursor"] {
            let handoff = try await service.context(project: root.path, targetAgent: agent)
            XCTAssertTrue(handoff.contains(decision.content))
        }
    }
}
