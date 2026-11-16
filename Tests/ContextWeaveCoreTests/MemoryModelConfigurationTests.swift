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
