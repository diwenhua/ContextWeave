import XCTest
@testable import ContextWeaveCore

final class MemoryProcessingTests: XCTestCase {
    func testQueuedWorkSurvivesReopenAndDoesNotRepeat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("data.sqlite")
        let id = try SessionID(agent: "codex", externalID: "memory-job")
        let path = root.appendingPathComponent("log.jsonl").path
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.appendingPathComponent("project").path, messages: [SessionMessage(id: "1", role: .user, content: "以后都用简体中文回复。", timestampMilliseconds: 10)])
        let cursor = FileCursor(inode: "1", parserVersion: "v1", observedSize: 10, observedMtimeMS: 1, offset: 10, pending: "", lineIndex: 1, externalID: id.externalID, project: session.projectID, ordinals: false, rejected: false)
        do {
            let store = try SessionStore(url: url)
            try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: false, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
            XCTAssertTrue(try store.memories(agent: id.agent, externalID: id.externalID).isEmpty)
        }
        let reopened = try SessionStore(url: url)
        XCTAssertTrue(try reopened.memories(agent: id.agent, externalID: id.externalID).isEmpty)
        let result = try JSONDecoder().decode(SemanticMemoryExtraction.self, from: Data(#"{"checkpoint":"目标：实现功能","candidates":[{"kind":"preference","content":"使用中文","sourceMessageID":"1"}]}"#.utf8))
        try reopened.saveSemanticMemory(result, session: id, expected: session.messages)
        try reopened.saveSemanticMemory(result, session: id, expected: session.messages)
        let saved = try reopened.memories(agent: id.agent, externalID: id.externalID)
        XCTAssertEqual(saved.filter { $0.content == "使用中文" }.count, 1)
        XCTAssertEqual(saved.first { $0.content == "使用中文" }?.status, "candidate")
        let changed = [SessionMessage(id: "1", role: .user, content: "修改后的内容", timestampMilliseconds: nil)]
        XCTAssertThrowsError(try reopened.saveSemanticMemory(result, session: id, expected: changed))
    }

    func testTaskRankingFindsChineseAndEnglishTerms() {
        func memory(_ text: String) -> ProjectMemory {
            ProjectMemory(kind: "decision", agent: "codex", externalID: "one", stableProjectID: "project", content: text, updatedAt: 1)
        }
        let input = [memory("采用 SwiftUI 构建界面"), memory("选择 SQLite 数据库存储")]
        XCTAssertEqual(HandoffService.rankMemories(input, task: "如何选择数据库？").first?.content, input[1].content)
        XCTAssertEqual(HandoffService.rankMemories(input, task: "SQLite").first?.content, input[1].content)
        XCTAssertEqual(HandoffService.rankMemories(input, task: nil), input)
    }
}
