import CryptoKit
import XCTest
@testable import ContextWeaveCore

final class MemoryModelConfigurationTests: XCTestCase {
    func testEndpointValidationRejectsInsecureRemoteAndEmbeddedCredentials() throws {
        XCTAssertNoThrow(try MemoryModelConfiguration(endpoint: "https://api.example.com/v1/chat/completions", model: "example").validatedEndpoint())
        XCTAssertNoThrow(try MemoryModelConfiguration(endpoint: "http://127.0.0.1:11434/v1/chat/completions", model: "example").validatedEndpoint())
        for address in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/a"] {
            XCTAssertThrowsError(try MemoryModelConfiguration(endpoint: address, model: "example").validatedEndpoint())
        }
    }

    func testSettingsRoundTripContainsNoAPIKey() throws {
        var settings = AppSettings()
        settings.memoryModel = MemoryModelConfiguration(endpoint: "https://api.example.com/chat/completions", model: "example")
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("apikey"))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).memoryModel, settings.memoryModel)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.memoryModel, MemoryModelConfiguration())
    }
}

extension MemoryModelConfigurationTests {
    func testSemanticResponseMustCiteIncludedMessage() throws {
        let valid = #"{"checkpoint":"工作进行中","candidates":[{"kind":"decision","content":"选择 SQLite","sourceMessageID":"42"}]}"#
        XCTAssertEqual(try SemanticMemoryParser.parse(valid, messageIDs: ["42"]).candidates.first?.content, "选择 SQLite")
        XCTAssertThrowsError(try SemanticMemoryParser.parse(valid, messageIDs: ["other"]))
        XCTAssertThrowsError(try SemanticMemoryParser.parse("not json", messageIDs: ["42"]))
    }
}

private final class ModelMockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"choices":[{"message":{"content":"{\"checkpoint\":\"继续开发\",\"candidates\":[{\"kind\":\"decision\",\"content\":\"使用 SQLite\",\"sourceMessageID\":\"42\"}]}"}}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension MemoryModelConfigurationTests {
    func testModelClientParsesMockResponse() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ModelMockProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let message = SessionMessage(id: "42", role: .user, content: "选择 SQLite", timestampMilliseconds: nil)
        let result = try await SemanticMemoryClient.extract(configuration: MemoryModelConfiguration(endpoint: "http://127.0.0.1/test", model: "mock"), apiKey: nil, messages: [message], transport: session)
        XCTAssertEqual(result.candidates.first?.sourceMessageID, "42")
        XCTAssertEqual(result.checkpoint, "继续开发")
    }
}

extension MemoryModelConfigurationTests {
    func testResumeFromSavedBatchAndReplaceConfirmedDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("fixture.sqlite")
        let store = try SessionStore(url: db)
        let id = try SessionID(agent: "codex", externalID: "resume")
        let path = root.appendingPathComponent("source").path
        let messages = (2...42).map { SessionMessage(id: String($0), role: .user, content: "fixture", timestampMilliseconds: Int64($0)) }
        let session = Session(source: SessionSource(id: id, sourcePath: path), projectID: root.path, messages: messages)
        let cursor = FileCursor(inode: "1", parserVersion: "test", observedSize: 1, observedMtimeMS: 1, offset: 1, pending: "", lineIndex: 1, externalID: id.externalID, project: root.path, ordinals: false, rejected: false)
        try store.commitCapture(path: path, cursor: cursor, session: session, fullReplace: true, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
        let model = MemoryModelConfiguration(endpoint: "http://127.0.0.1/test", model: "mock")
        let page = try store.semanticPage(id, offset: 0, limit: 40)
        XCTAssertEqual(page.count, 40)
        XCTAssertEqual(try store.semanticPage(id, offset: 40, limit: 40).map(\.id), ["42"])
        let fields = ["", model.endpoint, model.model] + page.flatMap { [$0.id, $0.role.rawValue, $0.content] }
        let digest = SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
        try store.saveSemanticMemory(.init(checkpoint: "first batch", candidates: [.init(kind: "decision", content: "previous storage choice", sourceMessageID: page[0].id)]), session: id, expected: page, digest: digest)
        try store.watch(id, model: model)
        let revision = try XCTUnwrap(store.watched(model, due: true).first?.1)
        try store.finishWatch(id, revision: revision, success: false)
        XCTAssertTrue(try store.watched(model, due: true).isEmpty)
        XCTAssertEqual(try store.watched(model, due: false).count, 1)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelMockProtocol.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root, dshRoot: root, databaseURL: db))
        // The mock always cites 42. Requesting the cached first batch would fail citation validation.
        try await service.extractSemanticMemory(session: id, model: model, apiKey: nil, transport: transport)
        let memories = try await service.sessionMemory(id)
        let old = try XCTUnwrap(memories.first { $0.content == "previous storage choice" })
        let new = try XCTUnwrap(memories.first { $0.sourceMessageID == "42" })
        try await service.setMemoryStatus(id: old.id, status: "confirmed")
        try await service.replaceMemory(old.id, with: new.id)
        let handoff = try await service.context(project: root.path, targetAgent: "dsh")
        XCTAssertTrue(handoff.contains(new.content))
        XCTAssertFalse(handoff.contains(old.content))
        let source = try await service.evidence(project: new.stableProjectID, id: id, message: "42")
        XCTAssertEqual(source.content, "fixture")
        do {
            _ = try await service.evidence(project: root.appendingPathComponent("another").path, id: id, message: "42")
            XCTFail("Returned evidence outside project")
        } catch CaptureError.invalid { }
    }
}
