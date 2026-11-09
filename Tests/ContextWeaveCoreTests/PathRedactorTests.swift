import XCTest
@testable import ContextWeaveCore

final class PathRedactorTests: XCTestCase {
    func testWorkspaceAliasesAndOtherPathsKeepUsefulContext() {
        let redactor = PathRedactor(workspacePaths: ["/Users/alice/Project Alpha", "/tmp/other"])
        let input = #"Read "/Users/alice/Project Alpha/Sources/App.swift" and /tmp/other/Tests/A.swift; use /Users/bob/private/key.txt; https://example.com/api/v1 and /api/v1 stay; run /usr/bin/swift and /bin/zsh; Sources/Next.swift, project-id 123."#
        let output = redactor.redact(input)
        XCTAssertTrue(output.contains("[PROJECT]/Sources/App.swift"), output)
        XCTAssertTrue(output.contains("[PROJECT]/Tests/A.swift"), output)
        XCTAssertTrue(output.contains("[LOCAL_PATH]"), output)
        XCTAssertFalse(output.contains("/Users/alice")); XCTAssertFalse(output.contains("/Users/bob")); XCTAssertFalse(output.contains("/tmp/other"))
        XCTAssertTrue(output.contains("https://example.com/api/v1")); XCTAssertTrue(output.contains("/api/v1")); XCTAssertTrue(output.contains("Sources/Next.swift"))
        XCTAssertTrue(output.contains("project-id 123")); XCTAssertTrue(output.contains("/usr/bin/swift")); XCTAssertTrue(output.contains("/bin/zsh"))
        XCTAssertEqual(redactor.redact(output), output, "Redaction must be idempotent")
    }
    func testWorkspaceFileURLAndEncodedSpacesKeepProjectRelativePath() {
        let redactor = PathRedactor(workspacePaths: ["/Users/alice/Project Alpha"])
        let text = "open file:///Users/alice/Project%20Alpha/Sources/App.swift"
        let output = redactor.redact(text)
        XCTAssertEqual(output, "open [PROJECT]/Sources/App.swift")
    }
    func testEscapedAndWindowsPathsAndPrefixCollision() {
        let redactor = PathRedactor(workspacePaths: ["/Users/alice/work"])
        let input = #"/Users/alice/work/src/main.swift /Users/alice/work-other/secret.txt ~/private/secrets.txt C:\Users\alice\secret.txt file:///Users/alice/Documents/a.txt \/Users\/alice\/private\/data"#
        let output = redactor.redact(input)
        XCTAssertTrue(output.contains("[PROJECT]/src/main.swift"), output)
        XCTAssertFalse(output.contains("/Users/alice"), output)
        XCTAssertFalse(output.contains("work-other"), output)
        XCTAssertFalse(output.contains("C:\\Users"), output)
        XCTAssertFalse(output.contains(#"\/Users\/alice"#), output)
        XCTAssertFalse(output.contains("file:///"), output)
    }
    func testQuotedPathsWithSpacesAndUnicodeEscapedSlashes() {
        let redactor = PathRedactor(workspacePaths: ["/Users/alice/work"])
        let input = #"Open "/Users/bob/Private Documents/a file.txt" and "file:///Users/bob/My Documents/report.pdf". Path \u002FUsers\u002Falice\u002Fprivate, API "/api/v1"."#
        let result = redactor.redact(input)
        XCTAssertFalse(result.contains("/Users/bob"), result)
        XCTAssertFalse(result.contains("Private Documents"), result)
        XCTAssertFalse(result.contains("My Documents"), result)
        XCTAssertFalse(result.contains(#"\u002FUsers"#), result)
        XCTAssertTrue(result.contains("/api/v1"), result)
    }
    func testContextAndMCPReturnRedactedCopiesWithoutChangingStoredRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = "/Users/alice/private-project"
        let command = "Read /Users/alice/private-project/Sources/Foo.swift and /Users/alice/secrets.txt"
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "redact-1", "cwd": workspace]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": command]]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "call1", "output": "saved /Users/alice/private-project/Tests/Foo.swift"]]
        ]
        let text = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("codex/rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let report = await service.scan(); XCTAssertTrue(report.errors.isEmpty)
        let bindingList = try await service.workspaceBindings(); let binding = try XCTUnwrap(bindingList.first)
        let note = "Review /Users/alice/private-project/Sources/Foo.swift and /Users/alice/private.txt"
        let saved = try await service.logProgress(project: binding.projectID, agent: "codex", done: note, next: "edit /Users/alice/private-project/Tests/Foo.swift")
        XCTAssertEqual(saved.done, note)
        let context = try await service.context(project: binding.projectID, targetAgent: "dsh")
        XCTAssertFalse(context.contains("/Users/alice"), context)
        XCTAssertTrue(context.contains("[PROJECT]/Sources/Foo.swift"), context)
        XCTAssertTrue(context.contains("[PROJECT]/Tests/Foo.swift"), context)
        XCTAssertTrue(context.contains("[LOCAL_PATH]"), context)
        let id = try SessionID(agent: "codex", externalID: "redact-1")
        let stored = try await service.session(id)
        XCTAssertEqual(stored?.messages.first?.content, command)
        let displayed = try await service.displaySession(id)
        XCTAssertTrue(displayed?.messages.first?.content.contains("[PROJECT]/Sources/Foo.swift") == true)
        XCTAssertFalse(displayed?.messages.first?.content.contains("/Users/alice") ?? true)
        let titles = try await service.displaySessions()
        XCTAssertTrue(titles.first?.title.contains("[PROJECT]") == true)
        XCTAssertFalse(titles.first?.title.contains("/Users/alice") ?? true)
        let handler = MCPHandler(service: service)
        func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
            let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let response = await handler.handle(try JSONSerialization.data(withJSONObject: req))
            let rpc = try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
            let result = try XCTUnwrap(rpc["result"] as? [String: Any]); XCTAssertNil(result["isError"])
            return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        }
        let page = try await call("memory_get_session", ["project": binding.projectID, "agent": "codex", "session_id": "redact-1"])
        XCTAssertFalse(page.contains("/Users/alice")); XCTAssertTrue(page.contains("[PROJECT]"))
        let result = try await call("memory_log_progress", ["project": binding.projectID, "agent": "dsh", "done": note])
        XCTAssertFalse(result.contains("/Users/alice")); XCTAssertTrue(result.contains("[PROJECT]"))
        let afterward = try await service.context(project: binding.projectID, targetAgent: "codex")
        XCTAssertTrue(afterward.contains("[PROJECT]/Sources/Foo.swift"))
        let stillRaw = try await service.session(id)
        XCTAssertEqual(stillRaw?.messages.first?.content, command)
    }
}
