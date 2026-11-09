import XCTest
@testable import ContextWeaveCore

private actor ScanProbe {
    private var first: CheckedContinuation<Void, Never>?
    private(set) var overlapped = false
    private(set) var visible = false
    func update(_ service: HandoffService) async {
        if let rows = try? await service.sessions(), !rows.isEmpty { visible = true }
        if let first { overlapped = true; self.first = nil; first.resume(); return }
        if !overlapped { await withCheckedContinuation { first = $0 } }
    }
    func release() { first?.resume(); first = nil }
}

final class HandoffTests: XCTestCase {
    func testSourcesScanConcurrentlyAndPublishCommittedSessions() async throws {
        let root = try directory(), cRoot = root.appendingPathComponent("codex"), dRoot = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: cRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dRoot, withIntermediateDirectories: true)
        try codex().write(to: cRoot.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        try dsh().write(to: dRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: cRoot, dshRoot: dRoot, databaseURL: root.appendingPathComponent("data.sqlite")))
        let probe = ScanProbe()
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); await probe.release() }
        let result = await service.scan { await probe.update(service) }
        timeout.cancel()
        let overlapped = await probe.overlapped, visible = await probe.visible
        XCTAssertTrue(overlapped); XCTAssertTrue(visible)
        XCTAssertEqual(result.imported, 2); XCTAssertTrue(result.errors.isEmpty)
    }

    func testDisplayPagesReturnOrderedRedactedHistory() async throws {
        let root = try directory(), logs = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var events: [[String: Any]] = [["type": "session_meta", "payload": ["id": "long", "cwd": "/tmp/project-a"]]]
        for index in 0..<75 {
            events.append(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "message \(index) /tmp/project-a/file.swift"]]]])
        }
        try jsonl(events).write(to: logs.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: logs, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        _ = await service.scan()
        let id = try SessionID(agent: "codex", externalID: "long")
        let lastPage = try await service.displaySessionPage(id)
        let last = try XCTUnwrap(lastPage)
        XCTAssertEqual(last.start, 45); XCTAssertEqual(last.total, 75); XCTAssertEqual(last.session.messages.count, 30)
        XCTAssertTrue(last.session.messages[0].content.contains("message 45")); XCTAssertTrue(last.session.messages[0].content.contains("[PROJECT]/file.swift"))
        let priorPage = try await service.displaySessionPage(id, before: last.start)
        let prior = try XCTUnwrap(priorPage)
        XCTAssertEqual(prior.start, 15); XCTAssertEqual(prior.session.messages.count, 30)
        XCTAssertTrue(prior.session.messages.last?.content.contains("message 44") == true)
        let firstPage = try await service.displaySessionPage(id, before: prior.start)
        let first = try XCTUnwrap(firstPage)
        XCTAssertEqual(first.start, 0); XCTAssertEqual(first.session.messages.count, 15)
    }
    func testRunStateFollowsTurnBoundaries() throws {
        let running = try SessionParser.parse(codex() + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n", agent: "codex", path: "/tmp/c.jsonl")
        XCTAssertEqual(running?.runState, .running)
        let finished = try SessionParser.parse(codex() + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n", agent: "codex", path: "/tmp/c.jsonl")
        XCTAssertEqual(finished?.runState, .finished)
        let stopped = try SessionParser.parse(dsh() + "{\"type\":\"turn/start\",\"data\":{\"turn\":1}}\n{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"aborted\"},\"turn\":1}}\n", agent: "dsh", path: "/tmp/d.jsonl")
        XCTAssertEqual(stopped?.runState, .aborted)
        let done = try SessionParser.parse(dsh() + "{\"type\":\"turn/start\",\"data\":{\"turn\":1}}\n{\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"completed\"},\"turn\":1}}\n", agent: "dsh", path: "/tmp/d.jsonl")
        XCTAssertEqual(done?.runState, .finished)
        let waiting = try SessionParser.parse(dsh() + "{\"type\":\"turn/start\",\"data\":{\"turn\":1}}\n{\"type\":\"approval/asked\",\"data\":{\"id\":\"a1\"}}\n", agent: "dsh", path: "/tmp/d.jsonl")
        XCTAssertEqual(waiting?.runState, .awaitingApproval)
        let approved = try SessionParser.parse(dsh() + "{\"type\":\"turn/start\",\"data\":{\"turn\":1}}\n{\"type\":\"approval/asked\",\"data\":{\"id\":\"a1\"}}\n{\"type\":\"approval/decided\",\"data\":{\"id\":\"a1\",\"outcome\":\"allow\"}}\n", agent: "dsh", path: "/tmp/d.jsonl")
        XCTAssertEqual(approved?.runState, .running)
    }
    func testCursorHandoffInBothDirections() async throws {
        let root = try directory()
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let workspace = root.appendingPathComponent("project").path
        _ = try await service.logProgress(project: workspace, agent: "codex", done: "Implemented Sources/Foo.swift", next: "Continue in Cursor")
        let cursor = try await service.context(project: workspace, targetAgent: "cursor")
        XCTAssertTrue(cursor.contains("Implemented Sources/Foo.swift"))
        _ = try await service.logProgress(project: workspace, agent: "cursor", done: "Cursor verified feature", next: "Return to Codex")
        let codex = try await service.context(project: workspace, targetAgent: "codex")
        let dsh = try await service.context(project: workspace, targetAgent: "dsh")
        XCTAssertTrue(codex.contains("Cursor verified feature"))
        XCTAssertTrue(dsh.contains("Cursor verified feature"))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func jsonl(_ events: [[String: Any]]) throws -> String {
        try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
    private func codex(_ prompt: String = "Implement feature A") throws -> String {
        try jsonl([
            ["type": "session_meta", "payload": ["id": "same-id", "cwd": "/tmp/project-a"]],
            ["type": "response_item", "timestamp": "2026-11-09T01:02:03.456Z", "payload": ["type": "message", "role": "user", "content": [["text": prompt]]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "call-1", "output": "build passed"]]
        ])
    }
    private func dsh() throws -> String {
        try jsonl([
            ["type": "session", "id": "same-id", "version": 4, "cwd": "/tmp/project-a", "createdAt": 1_700_000_000_000],
            ["type": "user/message", "seq": 1, "time": 1_700_000_000_001, "data": ["source": ["kind": "runtime-context"], "content": "DO NOT CAPTURE"]],
            ["type": "user/message", "seq": 2, "time": 1_700_000_000_002, "data": ["source": ["kind": "user"], "content": "Continue feature A"]],
            ["type": "assistant/message", "seq": 3, "time": 1_700_000_000_003, "data": ["message": ["role": "assistant", "content": [["type": "reasoning", "text": "PRIVATE REASONING"], ["type": "text", "text": "Feature complete"], ["type": "tool-call", "name": "build", "arguments": "{}"]]]]],
            ["type": "tool/result", "seq": 4, "time": 1_700_000_000_004, "data": ["output": "success"]]
        ])
    }
    func testParsersPreserveToolsMillisecondsAndExcludeInjectedContext() throws {
        let c = try XCTUnwrap(SessionParser.parse(codex(), agent: "codex", path: "/tmp/c.jsonl"))
        XCTAssertEqual(c.messages.count, 2)
        XCTAssertEqual(c.messages[0].timestampMilliseconds, 1_794_186_123_456)
        XCTAssertEqual(c.messages[1].role, .tool)
        let d = try XCTUnwrap(SessionParser.parse(dsh(), agent: "dsh", path: "/tmp/d.jsonl"))
        XCTAssertEqual(d.messages.count, 4)
        XCTAssertFalse(d.messages.contains { $0.content.contains("DO NOT CAPTURE") || $0.content.contains("PRIVATE REASONING") })
        XCTAssertEqual(d.messages.last?.timestampMilliseconds, 1_700_000_000_004)
        XCTAssertNotEqual(c.source.id, d.source.id)
    }
    func testPartialTailAcceptedButCorruptCompletedLineRejected() throws {
        XCTAssertEqual(try SessionParser.parse(codex() + "{\"type\":", agent: "codex", path: "/tmp/c").map { $0.messages.count }, 2)
        XCTAssertThrowsError(try SessionParser.parse(codex() + "bad-json\n", agent: "codex", path: "/tmp/c"))
    }
    func testLatestGenerationIsNumericAndCompressionWinsTie() {
        let paths = ["/a/session.v9.jsonl", "/a/session.v10.jsonl", "/a/session.v10.jsonl.zstd", "/b/session.jsonl", "/a/session.lock"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(HandoffService.latestGenerations(paths).map(\.path), ["/a/session.v10.jsonl.zstd", "/b/session.jsonl"])
    }
    func testConcatenatedZstdFramesAndEveryTruncatedTail() throws {
        // Valid single-segment raw frames, no compression library needed to test framing.
        func frame(_ text: String) -> Data {
            let payload = Data(text.utf8), header = (payload.count << 3) | 1
            return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(payload.count), UInt8(header & 255), UInt8((header >> 8) & 255), 0]) + payload
        }
        let first = frame("header\n"), second = frame("event\n")
        XCTAssertEqual(try ZstandardLog.completePrefix(first + second), first + second)
        for count in 1..<second.count { XCTAssertEqual(try ZstandardLog.completePrefix(first + second.prefix(count)), first) }
        XCTAssertThrowsError(try ZstandardLog.completePrefix(Data([1, 2, 3, 4, 5])))
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/zstd") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/zstd") {
            XCTAssertEqual(try ZstandardLog.decode(first + second), "header\nevent\n")
        }
    }
    func testBidirectionalHandoffPersistenceIsolationAndAppend() async throws {
        let root = try directory(), cRoot = root.appendingPathComponent("codex"), dRoot = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: cRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dRoot.appendingPathComponent("s1"), withIntermediateDirectories: true)
        let cFile = cRoot.appendingPathComponent("rollout-test.jsonl"), dFile = dRoot.appendingPathComponent("s1/session.v4.jsonl")
        try codex().write(to: cFile, atomically: true, encoding: .utf8)
        try dsh().write(to: dFile, atomically: true, encoding: .utf8)
        let config = CaptureConfiguration(codexRoot: cRoot, dshRoot: dRoot, databaseURL: root.appendingPathComponent("data.sqlite"))
        let service = try HandoffService(configuration: config)
        let first = await service.scan(); XCTAssertEqual(first.imported, 2); XCTAssertTrue(first.errors.isEmpty)
        let second = await service.scan(); XCTAssertEqual(second.unchanged, 2)
        _ = try await service.logProgress(project: "/tmp/project-a", agent: "codex", done: "API ready", next: "Harness adds tests")
        let forDsh = try await service.context(project: "/tmp/project-a", targetAgent: "dsh")
        XCTAssertTrue(forDsh.contains("API ready")); XCTAssertTrue(forDsh.contains("Implement feature A"))
        let forCodex = try await service.context(project: "/tmp/project-a", targetAgent: "codex")
        XCTAssertTrue(forCodex.contains("Feature complete"))
        let otherProject = try await service.context(project: "/tmp/project-b", targetAgent: "codex")
        XCTAssertFalse(otherProject.contains("API ready")); XCTAssertFalse(otherProject.contains("Feature complete"))
        let appended = try codex() + jsonl([["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["text": "New answer"]]]]])
        try appended.write(to: cFile, atomically: true, encoding: .utf8)
        let third = await service.scan(); XCTAssertEqual(third.imported, 1)
        let page = try await service.messagePage(SessionID(agent: "codex", externalID: "same-id"), offset: 2, limit: 1)
        XCTAssertEqual(page?.total, 3)
        XCTAssertEqual(page?.messages.map(\.content), ["New answer"])
        let reopened = try HandoffService(configuration: config)
        let rows = try await reopened.sessions(); XCTAssertEqual(rows.count, 2)
        let restored = try await reopened.context(project: "/tmp/project-a", targetAgent: "dsh")
        XCTAssertTrue(restored.contains("New answer")); XCTAssertTrue(restored.contains("API ready"))
        try codex().write(to: cFile, atomically: true, encoding: .utf8)
        let shrink = await service.scan(); XCTAssertEqual(shrink.errors.count, 1)
        let preserved = try await service.context(project: "/tmp/project-a", targetAgent: "dsh")
        XCTAssertTrue(preserved.contains("New answer"))
    }
    func testCodexHistoryShardsMergeByOrdinalRegardlessOfScanOrder() async throws {
        let root = try directory(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        func shard(_ ordinal: Int, _ content: String) throws -> String {
            try jsonl([
                ["type": "session_meta", "ordinal": ordinal, "payload": ["id": "shared", "cwd": "/tmp/sharded"]],
                ["type": "response_item", "ordinal": ordinal + 1, "payload": ["type": "message", "role": "assistant", "content": [["text": content]]]]
            ])
        }
        try shard(100, "Latest shard").write(to: logs.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        try shard(0, "Earlier shard").write(to: logs.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: logs, dshRoot: root.appendingPathComponent("missing"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let report = await service.scan(); XCTAssertTrue(report.errors.isEmpty)
        let session = try await service.session(SessionID(agent: "codex", externalID: "shared"))
        XCTAssertEqual(session?.messages.map(\.content), ["Earlier shard", "Latest shard"])
        try shard(0, "Earlier shard").appending(" ").write(to: logs.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)
        let repeated = await service.scan(); XCTAssertTrue(repeated.errors.isEmpty)
        let preserved = try await service.session(SessionID(agent: "codex", externalID: "shared"))
        XCTAssertEqual(preserved?.messages.count, 2)
    }
    func testAppendReadsOnlyTheNewTail() async throws {
        let root = try directory(), logs = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout-live.jsonl")
        try codex().write(to: file, atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: logs, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let first = await service.scan()
        XCTAssertEqual(first.imported, 1)
        let path = file.resolvingSymlinksInPath().path
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        let offset = try await service.capturedOffset(path)
        XCTAssertEqual(offset, size)
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("x".utf8))
        let extra = try jsonl([["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["text": "Tail only"]]]]])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()
        let second = await service.scan()
        XCTAssertTrue(second.errors.isEmpty, second.errors.joined(separator: "\n"))
        let session = try await service.session(SessionID(agent: "codex", externalID: "same-id"))
        XCTAssertEqual(session?.messages.map(\.content).filter { $0 == "Implement feature A" || $0 == "Tail only" }, ["Implement feature A", "Tail only"])
        let grown = try await service.capturedOffset(path)
        XCTAssertGreaterThan(grown ?? 0, offset ?? 0)
        let third = await service.scan()
        XCTAssertEqual(third.unchanged, 1)
    }
    func testIncompleteLineIsKeptUntilItCloses() async throws {
        let root = try directory(), logs = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout-partial.jsonl")
        let partial = try codex() + #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"Soo"#
        try partial.write(to: file, atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: logs, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let first = await service.scan()
        XCTAssertTrue(first.errors.isEmpty, first.errors.joined(separator: "\n"))
        let before = try await service.session(SessionID(agent: "codex", externalID: "same-id"))
        XCTAssertEqual(before?.messages.count, 2)
        XCTAssertFalse(before?.messages.contains { $0.content.contains("Soon") } ?? true)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"n"}]}}"#.utf8 + Data("\n".utf8)))
        try handle.close()
        let second = await service.scan()
        XCTAssertTrue(second.errors.isEmpty, second.errors.joined(separator: "\n"))
        let after = try await service.session(SessionID(agent: "codex", externalID: "same-id"))
        XCTAssertEqual(after?.messages.map(\.content).last, "Soon")
    }
    func testLegacyPayloadDatabaseMigratesToMessageRows() async throws {
        let root = try directory()
        let db = root.appendingPathComponent("data.sqlite")
        let session = Session(source: SessionSource(id: try SessionID(agent: "codex", externalID: "legacy"), sourcePath: "/tmp/legacy.jsonl"), projectID: "/tmp/project-a", messages: [SessionMessage(id: "1", role: .user, content: "Legacy hello", timestampMilliseconds: 42)])
        let payload = String(decoding: try JSONEncoder().encode(session), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE sessions(agent TEXT NOT NULL, external_id TEXT NOT NULL, project TEXT, payload TEXT NOT NULL, activity INTEGER NOT NULL, PRIMARY KEY(agent, external_id));
        CREATE TABLE capture_files(path TEXT PRIMARY KEY, signature TEXT NOT NULL);
        CREATE TABLE progress(id TEXT PRIMARY KEY, project TEXT NOT NULL, payload TEXT NOT NULL, timestamp INTEGER NOT NULL);
        INSERT INTO sessions VALUES('codex','legacy','/tmp/project-a','\(payload)',42);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: db))
        let rows = try await service.sessions()
        XCTAssertEqual(rows.map(\.title), ["Legacy hello"])
        let loaded = try await service.session(SessionID(agent: "codex", externalID: "legacy"))
        XCTAssertEqual(loaded?.messages.map(\.content), ["Legacy hello"])
        let again = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: db))
        let migrated = try await again.sessions()
        XCTAssertEqual(migrated.map(\.title), ["Legacy hello"])
    }
    func testHarnessFramesResumeAfterAPartialFrame() async throws {
        let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(zstd, "zstd is required to decode Harness frames")
        func frame(_ text: String) -> Data {
            let payload = Data(text.utf8), header = (payload.count << 3) | 1
            return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(payload.count), UInt8(header & 255), UInt8((header >> 8) & 255), 0]) + payload
        }
        let root = try directory(), logs = root.appendingPathComponent("dsh/s1")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("session.v2.jsonl.zstd")
        let first = frame("{\"type\":\"session\",\"id\":\"z1\",\"cwd\":\"/tmp/project-a\"}\n{\"type\":\"user/message\",\"data\":{\"content\":\"First\"}}\n")
        let second = frame("{\"type\":\"user/message\",\"data\":{\"content\":\"Second\"}}\n")
        try (first + second.prefix(4)).write(to: file)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("codex"), dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let started = await service.scan()
        XCTAssertTrue(started.errors.isEmpty, started.errors.joined(separator: "\n"))
        let opened = try await service.session(SessionID(agent: "dsh", externalID: "z1"))
        XCTAssertEqual(opened?.messages.map(\.content), ["First"])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: second.dropFirst(4))
        try handle.close()
        let finished = await service.scan()
        XCTAssertTrue(finished.errors.isEmpty, finished.errors.joined(separator: "\n"))
        let resumed = try await service.session(SessionID(agent: "dsh", externalID: "z1"))
        XCTAssertEqual(resumed?.messages.map(\.content), ["First", "Second"])
    }
    func testStaleProcessCannotOverwriteNewerCapture() throws {
        let root = try directory(), database = root.appendingPathComponent("data.sqlite")
        let first = try SessionStore(url: database), second = try SessionStore(url: database)
        let path = "/tmp/capture.jsonl"
        let id = try SessionID(agent: "codex", externalID: "race")
        let source = SessionSource(id: id, sourcePath: path)
        let one = SessionMessage(id: "1", role: .user, content: "First", timestampMilliseconds: 1)
        let two = SessionMessage(id: "2", role: .assistant, content: "Second", timestampMilliseconds: 2)
        let cursor = FileCursor(inode: "1:2", parserVersion: "v1", observedSize: 100, observedMtimeMS: 1, offset: 100, pending: "", lineIndex: 2, externalID: "race", project: "/tmp/project-a", ordinals: false, rejected: false)
        try first.commitCapture(path: path, cursor: cursor, session: Session(source: source, projectID: "/tmp/project-a", messages: [one]), fullReplace: true, previousAgent: nil, previousExternalID: nil, expectedCursor: nil)
        let stale = try XCTUnwrap(second.cursors(path: path)[path])
        var newer = cursor; newer.offset = 200; newer.observedSize = 200; newer.lineIndex = 3
        try first.commitCapture(path: path, cursor: newer, session: Session(source: source, projectID: "/tmp/project-a", messages: [two]), fullReplace: false, previousAgent: "codex", previousExternalID: "race", expectedCursor: cursor)
        XCTAssertThrowsError(try second.commitCapture(path: path, cursor: stale, session: Session(source: source, projectID: "/tmp/project-a", messages: [one]), fullReplace: true, previousAgent: "codex", previousExternalID: "race", expectedCursor: stale)) { error in
            guard case CaptureError.staleCursor = error else { return XCTFail("Expected stale cursor, got \(error)") }
        }
        XCTAssertEqual(try second.cursors(path: path)[path], newer)
        XCTAssertEqual(try second.get(id)?.messages.map(\.content), ["First", "Second"])
    }
    func testEmbeddedNullInMessagesAndProgressRoundTrips() async throws {
        let root = try directory(), logs = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try codex("before\0after").write(to: logs.appendingPathComponent("rollout-null.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: logs, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let report = await service.scan(); XCTAssertTrue(report.errors.isEmpty, report.errors.joined(separator: "\n"))
        let session = try await service.session(SessionID(agent: "codex", externalID: "same-id"))
        XCTAssertEqual(session?.messages.first?.content, "before\0after")
        _ = try await service.logProgress(project: "/tmp/project-a", agent: "dsh", done: "left\0right")
        let context = try await service.context(project: "/tmp/project-a", targetAgent: "codex")
        XCTAssertTrue(context.contains("left\0right"))
    }
    func testVersionTwoUpgradePreservesProgressAndAddsIndexes() throws {
        let root = try directory(), db = root.appendingPathComponent("upgrade.sqlite")
        let entry = ProgressEntry(id: "progress-1", project: "/tmp/project-a", agent: "codex", done: "Keep this", next: "", issues: "", timestamp: 42)
        do { let store = try SessionStore(url: db); try store.log(entry) }
        let downgrade = Process(); downgrade.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        downgrade.arguments = [db.path, "DROP TRIGGER sessions_project_insert_guard; DROP TRIGGER sessions_project_update_guard; DROP TRIGGER progress_project_insert_guard; DROP INDEX sessions_stable_project_activity; DROP INDEX progress_stable_project_timestamp; ALTER TABLE sessions DROP COLUMN stable_project_id; ALTER TABLE progress DROP COLUMN stable_project_id; DROP TABLE workspaces; DROP TABLE devices; DROP TABLE projects; DROP INDEX progress_project_timestamp; DROP INDEX messages_session_timestamp; PRAGMA user_version=2;"]
        try downgrade.run(); downgrade.waitUntilExit(); XCTAssertEqual(downgrade.terminationStatus, 0)
        let upgraded = try SessionStore(url: db)
        XCTAssertEqual(try upgraded.progress(project: ProjectIdentity.canonicalPath("/tmp/project-a")).map(\.done), ["Keep this"])
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = [db.path, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('progress_project_timestamp','messages_session_timestamp'); PRAGMA user_version;"]
        let pipe = Pipe(); check.standardOutput = pipe
        try check.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); check.waitUntilExit()
        XCTAssertEqual(output, "2\n6\n")
    }
    func testRejectsNewerSchemaWithoutChangingIt() throws {
        let root = try directory(), db = root.appendingPathComponent("future.sqlite")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, "PRAGMA user_version=999; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('preserve');"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try SessionStore(url: db)) { error in XCTAssertTrue(error.localizedDescription.contains("newer")) }
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = [db.path, "SELECT value FROM future_data; PRAGMA user_version;"]
        let pipe = Pipe(); check.standardOutput = pipe
        try check.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); check.waitUntilExit()
        XCTAssertEqual(output, "preserve\n999\n")
    }
    func testMCPHandshakeNotificationsErrorsAndRoundTrip() async throws {
        let root = try directory()
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: root.appendingPathComponent("c"), dshRoot: root.appendingPathComponent("d"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let handler = MCPHandler(service: service)
        func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let response = await handler.handle(data)
            return try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
        }
        let initialize = try await rpc("initialize", ["protocolVersion": "2024-11-05"])
        XCTAssertEqual((initialize["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
        let notification = await handler.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)); XCTAssertNil(notification)
        let unknown = try await rpc("unknown"); XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let missing = try await rpc("tools/call", ["name": "memory_get_context", "arguments": [:]])
        XCTAssertEqual((missing["result"] as? [String: Any])?["isError"] as? Bool, true)
        let write = try await rpc("tools/call", ["name": "memory_log_progress", "arguments": ["project": "/tmp/a", "agent": "dsh", "done": "Harness finished"]])
        XCTAssertNil((write["result"] as? [String: Any])?["isError"])
        let read = try await rpc("tools/call", ["name": "memory_get_context", "arguments": ["project": "/tmp/a", "target_agent": "codex"]])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: read), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Harness finished"))
    }

    func testAgentRenameAndProjectMoveStayOnTheSameConversation() async throws {
        let root = try directory()
        let codexHome = root.appendingPathComponent("codex")
        let dshHome = root.appendingPathComponent("dsh")
        let codexRoot = codexHome.appendingPathComponent("sessions")
        let dshRoot = dshHome.appendingPathComponent("sessions")
        let old = root.appendingPathComponent("old-project")
        let moved = root.appendingPathComponent("moved-project")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dshRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let rollout = try jsonl([
            ["type": "session_meta", "payload": ["id": "thread-1", "cwd": old.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "Original prompt"]]]]
        ])
        try rollout.write(to: codexRoot.appendingPathComponent("rollout-thread.jsonl"), atomically: true, encoding: .utf8)
        let harness = try jsonl([
            ["type": "session", "id": "harness-1", "version": 4, "cwd": old.path, "createdAt": 1_700_000_000_000],
            ["type": "user/message", "seq": 1, "time": 1_700_000_000_001, "data": ["source": ["kind": "user"], "content": "继续原来的任务"]]
        ])
        try harness.write(to: dshRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: codexRoot, dshRoot: dshRoot, databaseURL: root.appendingPathComponent("data.sqlite")))
        let imported = await service.scan()
        XCTAssertTrue(imported.errors.isEmpty, imported.errors.joined(separator: "\n"))
        let codexID = try SessionID(agent: "codex", externalID: "thread-1")
        let importedRows = try await service.sessions()
        let before = try XCTUnwrap(importedRows.first { $0.id == codexID })
        XCTAssertEqual(before.title, "Original prompt")
        let project = try XCTUnwrap(before.stableProjectID)
        _ = try await service.logProgress(project: old.path, agent: "codex", done: "keep this")

        let index = "{\"id\":\"thread-1\",\"thread_name\":\"改好的名字\",\"updated_at\":\"2026-11-09T00:00:00Z\"}\n"
        try index.write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        try sqlite(codexHome.appendingPathComponent("state_5.sqlite"), "CREATE TABLE threads(id TEXT, cwd TEXT, name TEXT, title TEXT); INSERT INTO threads VALUES('thread-1','\(moved.path)','改好的名字','Original prompt');")
        let cache = dshHome.appendingPathComponent("storages/session_projcache/sessions")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let record: [String: Any] = ["record": ["identity": ["cwd": old.path], "rows": ["title": ["val": "Harness 新标题"], "workingDirectory": ["val": moved.path]]]]
        try JSONSerialization.data(withJSONObject: record).write(to: cache.appendingPathComponent("harness-1.json"))
        let workspace: [String: Any] = ["tables": ["workspaces": ["w1": ["path": moved.path, "title": "moved", "sessionIds": ["harness-1"]]]]]
        try JSONSerialization.data(withJSONObject: workspace).write(to: dshHome.appendingPathComponent("storages/workspace.json"))
        try FileManager.default.removeItem(at: old)

        let renamed = await service.scan()
        XCTAssertTrue(renamed.errors.isEmpty, renamed.errors.joined(separator: "\n"))
        let canonical = try ProjectIdentity.canonicalPath(moved.path)
        let renamedRows = try await service.sessions()
        let after = try XCTUnwrap(renamedRows.first { $0.id == codexID })
        XCTAssertEqual(after.title, "改好的名字")
        XCTAssertEqual(after.projectID, canonical)
        XCTAssertEqual(after.stableProjectID, project)
        let harnessID = try SessionID(agent: "dsh", externalID: "harness-1")
        let harnessSession = try XCTUnwrap(renamedRows.first { $0.id == harnessID })
        XCTAssertEqual(harnessSession.title, "Harness 新标题")
        XCTAssertEqual(harnessSession.projectID, canonical)
        XCTAssertEqual(harnessSession.stableProjectID, project)
        let context = try await service.context(project: moved.path, targetAgent: "dsh")
        XCTAssertTrue(context.contains("keep this"))
    }

    func testConversationMovesToAnotherLiveProjectWithoutTakingItsNeighbors() async throws {
        let root = try directory()
        let codexHome = root.appendingPathComponent("codex")
        let codexRoot = codexHome.appendingPathComponent("sessions")
        let first = root.appendingPathComponent("project-a")
        let second = root.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let stayLog = try jsonl([
            ["type": "session_meta", "payload": ["id": "stay", "cwd": second.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "Stay here"]]]]
        ])
        let moveLog = try jsonl([
            ["type": "session_meta", "payload": ["id": "move", "cwd": first.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "Move me"]]]]
        ])
        try stayLog.write(to: codexRoot.appendingPathComponent("rollout-stay.jsonl"), atomically: true, encoding: .utf8)
        try moveLog.write(to: codexRoot.appendingPathComponent("rollout-move.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: codexRoot, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let imported = await service.scan()
        XCTAssertTrue(imported.errors.isEmpty, imported.errors.joined(separator: "\n"))
        let stayID = try SessionID(agent: "codex", externalID: "stay")
        let moveID = try SessionID(agent: "codex", externalID: "move")
        let beforeRows = try await service.sessions()
        let stayBefore = try XCTUnwrap(beforeRows.first { $0.id == stayID })
        try sqlite(codexHome.appendingPathComponent("state_5.sqlite"), "CREATE TABLE threads(id TEXT, cwd TEXT, name TEXT, title TEXT); INSERT INTO threads VALUES('move','\(second.path)','Moved chat','Move me'); INSERT INTO threads VALUES('stay','\(second.path)','Stay here','Stay here');")
        let moved = await service.scan()
        XCTAssertTrue(moved.errors.isEmpty, moved.errors.joined(separator: "\n"))
        let afterRows = try await service.sessions()
        let stay = try XCTUnwrap(afterRows.first { $0.id == stayID })
        let relocated = try XCTUnwrap(afterRows.first { $0.id == moveID })
        XCTAssertEqual(relocated.title, "Moved chat")
        let secondPath = try ProjectIdentity.canonicalPath(second.path)
        XCTAssertEqual(relocated.projectID, secondPath)
        XCTAssertEqual(relocated.stableProjectID, stay.stableProjectID)
        XCTAssertEqual(stay.stableProjectID, stayBefore.stableProjectID)
        let leftBehind = try await service.projectID(forWorkspace: first.path)
        XCTAssertNotNil(leftBehind)
        XCTAssertNotEqual(leftBehind, stay.stableProjectID)
    }

    func testRunningUpdateDoesNotReplaceAgentNameWithFirstMessage() async throws {
        let root = try directory()
        let codexHome = root.appendingPathComponent("codex")
        let codexRoot = codexHome.appendingPathComponent("sessions")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let original = try jsonl([
            ["type": "session_meta", "payload": ["id": "thread-1", "cwd": project.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "Original prompt that should not flash"]]]]
        ])
        let file = codexRoot.appendingPathComponent("rollout-thread.jsonl")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let index = "{\"id\":\"thread-1\",\"thread_name\":\"稳定的名字\",\"updated_at\":\"2026-11-09T00:00:00Z\"}\n"
        try index.write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let service = try HandoffService(configuration: CaptureConfiguration(codexRoot: codexRoot, dshRoot: root.appendingPathComponent("dsh"), databaseURL: root.appendingPathComponent("data.sqlite")))
        let imported = await service.scan()
        XCTAssertTrue(imported.errors.isEmpty, imported.errors.joined(separator: "\n"))
        try FileManager.default.removeItem(at: codexHome.appendingPathComponent("session_index.jsonl"))
        let appended = original + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"text\":\"still working\"}]}}\n"
        try appended.write(to: file, atomically: true, encoding: .utf8)
        let updated = await service.scan()
        XCTAssertTrue(updated.errors.isEmpty, updated.errors.joined(separator: "\n"))
        let id = try SessionID(agent: "codex", externalID: "thread-1")
        let rows = try await service.sessions()
        XCTAssertEqual(rows.first { $0.id == id }?.title, "稳定的名字")
    }

    private func sqlite(_ database: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
