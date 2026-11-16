import Foundation
import XCTest
@testable import ContextWeaveCore

private actor OpenFault {
    var calls = 0
    var failures: Int
    let service: HandoffService
    init(service: HandoffService, failures: Int) { self.service = service; self.failures = failures }
    func open() async throws -> HandoffService {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        if failures > 0 { failures -= 1; throw CaptureError.invalid("database is locked") }
        return service
    }
}

final class MCPResilienceTests: XCTestCase {
    func testTransientOpenFailureRetriesAndCoalescesConcurrentRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("db.sqlite")))
        let fault = OpenFault(service: service, failures: 1)
        let provider = MCPServiceProvider(open: { try await fault.open() })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await provider.get() } }
            try await group.waitForAll()
        }
        let calls = await fault.calls
        XCTAssertEqual(calls, 2)
    }

    func testHandshakeSurvivesUnavailableDatabaseAndRecoversOnNextRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let configuration = CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: blocked.appendingPathComponent("db.sqlite"))
        let handler = MCPHandler(configuration: configuration)
        func call(_ json: String) async throws -> [String: Any] {
            let response = await handler.handle(Data(json.utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
        }
        let initialize = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertNotNil(initialize["result"])
        let ping = try await call(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertNotNil(ping["result"])
        let request = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_list_projects","arguments":{}}}"#
        let failed = try await call(request)
        let result = try XCTUnwrap(failed["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertFalse(String(describing: result).contains(root.path))
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let recovered = try await call(request)
        XCTAssertNil((recovered["result"] as? [String: Any])?["isError"])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: initialize), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"listChanged\":true"), encoded)
    }

    func testExecutableReplacementIsDetectedAndAMissingFileWaits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("contextweave-mcp")
        try Data("one".utf8).write(to: file)
        let started = try XCTUnwrap(ExecutableStamp.capture(file.path))
        XCTAssertFalse(MCPReload.shouldReload(started: started, current: ExecutableStamp.capture(file.path)))
        try Data("two-bytes".utf8).write(to: file)
        let replaced = try XCTUnwrap(ExecutableStamp.capture(file.path))
        XCTAssertNotEqual(started, replaced)
        XCTAssertTrue(MCPReload.shouldReload(started: started, current: replaced))
        XCTAssertFalse(MCPReload.shouldReload(started: started, current: replaced, retryAfter: Date().addingTimeInterval(60)))
        XCTAssertFalse(MCPReload.shouldReload(started: started, current: nil))
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: MCPReload.toolsChangedNotification) as? [String: Any])
        XCTAssertEqual(note["method"] as? String, "notifications/tools/list_changed")
        XCTAssertNil(note["id"])
    }
}
