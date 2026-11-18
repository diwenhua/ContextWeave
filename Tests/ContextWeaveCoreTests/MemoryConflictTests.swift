import XCTest
@testable import ContextWeaveCore

private final class MemoryReviewProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        do {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let prompt = try XCTUnwrap(messages.first?["content"])
            let content: String
            if prompt.contains("RETRY_SCHEMA") && !prompt.contains("previous response failed schema validation") {
                content = #"{"checkpoint":42,"candidates":[]}"#
            } else if prompt.contains("Compare the candidate") {
                let line = try XCTUnwrap(prompt.split(separator: "\n").last)
                let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let candidate = try XCTUnwrap(input["candidate"] as? [String: String])
                let targets = try XCTUnwrap(input["confirmed"] as? [[String: String]])
                let conflicts = targets.filter { $0["content"] == "Use SQLite" }.map {
                    ["candidateID": candidate["id"]!, "confirmedID": $0["id"]!, "relation": "supersedes", "reason": "The new decision replaces SQLite with PostgreSQL."]
                }
                content = String(decoding: try JSONSerialization.data(withJSONObject: ["conflicts": conflicts]), as: UTF8.self)
            } else {
                let hasTail = prompt.contains("TAIL_DECISION")
                content = hasTail
                    ? #"{"checkpoint":"Tail covered","candidates":[{"kind":"decision","content":"Use PostgreSQL","sourceMessageID":"2"}]}"#
                    : #"{"checkpoint":"Processing long input","candidates":[]}"#
            }
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MemoryConflictTests: XCTestCase {
    func testLongUnicodeMessageRetainsTailAndBoundaries() async throws {
        let content = String(repeating: "背景👨‍👩‍👧‍👦", count: 8000) + "TAIL_DECISION: Use PostgreSQL"
        let message = SessionMessage(id: "2", role: .user, content: content, timestampMilliseconds: 2)
        let batches = SemanticMemoryClient.batches([message])
        XCTAssertGreaterThan(batches.count, 1)
        let fragments = batches.flatMap { $0 }
        XCTAssertTrue(fragments.allSatisfy { $0.id == "2" && $0.content.count <= 6000 })
        XCTAssertTrue(batches.allSatisfy { $0.reduce(0) { $0 + $1.content.count } <= 16000 })
        let reconstructed = fragments.enumerated().map { $0.offset == 0 ? $0.element.content : String($0.element.content.dropFirst(200)) }.joined()
        XCTAssertEqual(reconstructed, content)
        let transport = mockTransport()
        defer { transport.invalidateAndCancel() }
        let result = try await SemanticMemoryClient.extract(configuration: model, apiKey: nil, messages: [message], transport: transport)
        XCTAssertEqual(result.candidates.map(\.content), ["Use PostgreSQL"])
        XCTAssertEqual(result.checkpoint, "Tail covered")
    }

    func testConflictsPersistAndRequireReviewBeforeHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("memory.sqlite")
        let store = try SessionStore(url: database)
        let id = try SessionID(agent: "codex", externalID: "conflict-test")
        let messages = [SessionMessage(id: "1", role: .user, content: "Use SQLite", timestampMilliseconds: 1), SessionMessage(id: "2", role: .user, content: "TAIL_DECISION: Use PostgreSQL", timestampMilliseconds: 2)]
        let path = root.appendingPathComponent("source").path
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path, messages: messages)
        let cursor = FileCursor(inode: "1", parserVersion: "test", observedSize: 1, observedMtimeMS: 1, offset: 1, pending: "", lineIndex: 1, externalID: id.externalID, project: root.path, ordinals: false, rejected: false)
        try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: true, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
        try store.saveSemanticMemory(.init(checkpoint: "old", candidates: [.init(kind: "decision", content: "Use SQLite", sourceMessageID: "1")]), session: id, expected: messages)
        let old = try XCTUnwrap(store.memories(agent: id.agent, externalID: id.externalID).first { $0.kind == "decision" })
        try store.setMemoryStatus(id: old.id, status: "confirmed")
        try store.setMemoryScope(id: old.id, scope: "project")
        let configuration = CaptureConfiguration(codexRoot: root, dshRoot: root, databaseURL: database)
        let service = try HandoffService(configuration: configuration)
        let transport = mockTransport()
        defer { transport.invalidateAndCancel() }
        try await service.extractSemanticMemory(session: id, model: model, apiKey: nil, transport: transport)
        let conflicts = try await service.memoryConflicts()
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflict.confirmedID, old.id)
        // Reopen and rerun: persistent comparisons and conflicts remain idempotent.
        let reopened = try HandoffService(configuration: configuration)
        try await reopened.extractSemanticMemory(session: id, model: model, apiKey: nil, transport: transport)
        let afterRetry = try await reopened.memoryConflicts()
        XCTAssertEqual(afterRetry, conflicts)
        XCTAssertThrowsError(try store.setMemoryStatus(id: conflict.candidateID, status: "confirmed"))
        let candidate = try XCTUnwrap(store.memories(agent: id.agent, externalID: id.externalID).first { $0.id == conflict.candidateID })
        let foreign = ProjectMemory(kind: candidate.kind, agent: candidate.agent, externalID: "unrelated", stableProjectID: "another-project", content: candidate.content, updatedAt: 2, id: "foreign")
        XCTAssertTrue(try store.conflictTargets(foreign).isEmpty)
        let originalTargets = try store.conflictTargets(candidate)
        try store.setMemoryScope(id: old.id, scope: "session")
        XCTAssertThrowsError(try store.saveConflicts(conflicts, candidate: candidate, targets: originalTargets, digest: "stale"))
        XCTAssertFalse(try store.hasConflictCheck("stale"))
        try store.setMemoryScope(id: old.id, scope: "project")
        try store.dismissConflict(conflict)
        XCTAssertTrue(try store.memoryConflicts().isEmpty)
        try await reopened.replaceMemory(old.id, with: conflict.candidateID)
        let resolved = try await reopened.memoryConflicts()
        XCTAssertTrue(resolved.isEmpty)
        let entries = try store.memories(agent: id.agent, externalID: id.externalID)
        XCTAssertEqual(entries.first { $0.id == old.id }?.status, "superseded")
        XCTAssertEqual(entries.first { $0.id == conflict.candidateID }?.scope, "project")
        for agent in ["codex", "dsh", "cursor"] {
            let context = try await reopened.context(project: root.path, targetAgent: agent)
            let memorySection = context.components(separatedBy: "## Latest session")[0]
            XCTAssertTrue(memorySection.contains("Use PostgreSQL"))
            XCTAssertFalse(memorySection.contains("Use SQLite"))
        }
    }

    func testRetriesMalformedModelSchemaOnce() async throws {
        let transport = mockTransport()
        defer { transport.invalidateAndCancel() }
        let message = SessionMessage(id: "2", role: .user, content: "RETRY_SCHEMA TAIL_DECISION", timestampMilliseconds: 2)
        let result = try await SemanticMemoryClient.extract(configuration: model, apiKey: nil, messages: [message], transport: transport)
        XCTAssertEqual(result.candidates.first?.sourceMessageID, "2")
    }

    func testRejectsInventedConflictIDs() {
        let response = #"{"conflicts":[{"candidateID":"c","confirmedID":"other-project","relation":"supersedes","reason":"changed"}]}"#
        XCTAssertThrowsError(try MemoryConflictClient.parse(response, candidate: "c", targets: ["valid"]))
    }

    private var model: MemoryModelConfiguration { .init(endpoint: "http://127.0.0.1/test", model: "mock") }
    private func mockTransport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MemoryReviewProtocol.self]
        return URLSession(configuration: config)
    }
}
