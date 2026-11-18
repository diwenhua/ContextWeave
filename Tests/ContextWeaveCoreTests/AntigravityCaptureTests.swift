import Foundation
import XCTest
import CSQLite
@testable import ContextWeaveCore

final class AntigravityCaptureTests: XCTestCase {
    func testCaptureTranscriptMetadataIncrementalAppendArchiveAndHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let antigravity = root.appendingPathComponent(".gemini/antigravity")
        let projectsConfig = root.appendingPathComponent(".gemini/config/projects")
        let project = root.appendingPathComponent("workspace/demo").resolvingSymlinksInPath()
        let fallbackProject = root.appendingPathComponent("workspace/fallback").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: antigravity.appendingPathComponent("brain/conv-1/.system_generated/logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: antigravity.appendingPathComponent("brain/conv-sub/.system_generated/logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: antigravity.appendingPathComponent("brain/conv-2/.system_generated/logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsConfig, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackProject, withIntermediateDirectories: true)

        let projectMeta = try JSONSerialization.data(withJSONObject: [
            "id": "proj-fallback",
            "projectResources": [
                "resources": [
                    ["gitFolder": ["folderUri": fallbackProject.absoluteString]]
                ]
            ]
        ])
        try projectMeta.write(to: projectsConfig.appendingPathComponent("proj-fallback.json"))

        let dbURL = antigravity.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) {
            XCTAssertEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK, text)
        }
        sql("""
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                workspace_uris TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL DEFAULT '',
                project_id TEXT NOT NULL DEFAULT '',
                parent_conversation_id TEXT NOT NULL DEFAULT '',
                nesting_depth INTEGER NOT NULL DEFAULT 0,
                not_fully_idle INTEGER NOT NULL DEFAULT 0,
                killed INTEGER NOT NULL DEFAULT 0
            )
            """)
        sql("CREATE TABLE conversations_fts (conversation_id TEXT, archived INTEGER DEFAULT 0)")
        sql("INSERT INTO conversation_summaries VALUES('conv-1', 'Initial Antigravity Chat', '[\"\(project.absoluteString)\"]', 'CASCADE_RUN_STATUS_RUNNING', '', '', 0, 1, 0)")
        sql("INSERT INTO conversation_summaries VALUES('conv-sub', 'Subagent Chat', '[\"\(project.absoluteString)\"]', 'CASCADE_RUN_STATUS_IDLE', '', 'conv-1', 1, 0, 0)")
        sql("INSERT INTO conversation_summaries VALUES('conv-2', 'Fallback Project Chat', '[]', 'CASCADE_RUN_STATUS_IDLE', 'proj-fallback', '', 0, 0, 0)")
        sql("INSERT INTO conversations_fts VALUES('conv-1', 0)")
        sql("INSERT INTO conversations_fts VALUES('conv-2', 0)")

        let transcript1 = antigravity.appendingPathComponent("brain/conv-1/.system_generated/logs/transcript_full.jsonl")
        let initialLines = try jsonl([
            [
                "step_index": 0,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "status": "DONE",
                "created_at": "2026-11-18T08:36:39Z",
                "content": "<USER_REQUEST>\nInspect \(project.path)/Sources/Main.swift\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nIgnored\n</ADDITIONAL_METADATA>"
            ],
            [
                "step_index": 1,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-18T08:36:41.500Z",
                "thinking": "Private chain of thought must not be captured",
                "tool_calls": [["name": "read_file", "args": ["Path": "\(project.path)/Sources/Main.swift"]]]
            ],
            [
                "step_index": 2,
                "source": "MODEL",
                "type": "GENERIC",
                "status": "DONE",
                "created_at": "2026-11-18T08:36:42Z",
                "content": "File read successfully"
            ]
        ])
        try initialLines.write(to: transcript1, atomically: true, encoding: .utf8)

        // conv-2 only has compact transcript.jsonl to verify fallback discovery.
        let transcript2 = antigravity.appendingPathComponent("brain/conv-2/.system_generated/logs/transcript.jsonl")
        try jsonl([
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": "2026-11-18T08:40:00Z", "content": "Hello fallback"]
        ]).write(to: transcript2, atomically: true, encoding: .utf8)

        // Subagent transcript should be excluded.
        let subTranscript = antigravity.appendingPathComponent("brain/conv-sub/.system_generated/logs/transcript_full.jsonl")
        try jsonl([
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": "2026-11-18T08:37:00Z", "content": "Subagent task"]
        ]).write(to: subTranscript, atomically: true, encoding: .utf8)

        let config = CaptureConfiguration(
            codexRoot: root.appendingPathComponent("codex"),
            dshRoot: root.appendingPathComponent("dsh"),
            databaseURL: root.appendingPathComponent("contextweave.sqlite"),
            antigravityRoot: antigravity
        )
        let service = try HandoffService(configuration: config)
        let first = await service.scan()
        XCTAssertEqual(first.imported, 2)
        XCTAssertTrue(first.errors.isEmpty, first.errors.joined(separator: "\n"))

        let id1 = try SessionID(agent: "antigravity", externalID: "conv-1")
        let rawSession1 = try await service.session(id1)
        let session1 = try XCTUnwrap(rawSession1)
        XCTAssertEqual(session1.messages.map(\.role), [.user, .tool, .tool])
        XCTAssertEqual(session1.messages[0].content, "Inspect \(project.path)/Sources/Main.swift")
        XCTAssertTrue(session1.messages[1].content.hasPrefix("Call read_file:"))
        XCTAssertTrue(session1.messages[2].content.hasPrefix("Result:\nFile read successfully"))
        XCTAssertFalse(session1.messages.contains { $0.content.contains("Private chain of thought") })
        XCTAssertEqual(session1.runState, .running)

        let rawSummary1 = try await service.summary(id1)
        let summary1 = try XCTUnwrap(rawSummary1)
        XCTAssertEqual(summary1.title, "Initial Antigravity Chat")
        let projectID1 = try XCTUnwrap(summary1.stableProjectID)

        let id2 = try SessionID(agent: "antigravity", externalID: "conv-2")
        let rawSummary2 = try await service.summary(id2)
        let summary2 = try XCTUnwrap(rawSummary2)
        XCTAssertEqual(summary2.projectID, try ProjectIdentity.canonicalPath(fallbackProject.path))
        XCTAssertEqual(summary2.runState, .finished)

        let subSession = try await service.session(try SessionID(agent: "antigravity", externalID: "conv-sub"))
        XCTAssertNil(subSession)

        // Append assistant reply + system message and transition status to IDLE.
        let rawOffsetBefore = try await service.capturedOffset(transcript1.resolvingSymlinksInPath().path)
        let offsetBefore = try XCTUnwrap(rawOffsetBefore)
        let appended = initialLines + (try jsonl([
            ["step_index": 3, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "created_at": "2026-11-18T08:36:45Z", "content": "<SYSTEM_MESSAGE>\nDone\n</SYSTEM_MESSAGE>"],
            ["step_index": 4, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-11-18T08:36:46Z", "content": "Updated \(project.path)/Sources/Main.swift"]
        ]))
        try appended.write(to: transcript1, atomically: false, encoding: .utf8)
        sql("UPDATE conversation_summaries SET title='Renamed Antigravity Chat', status='CASCADE_RUN_STATUS_IDLE', not_fully_idle=0 WHERE conversation_id='conv-1'")

        let second = await service.scan()
        XCTAssertEqual(second.imported, 1)
        let rawOffsetAfter = try await service.capturedOffset(transcript1.resolvingSymlinksInPath().path)
        let offsetAfter = try XCTUnwrap(rawOffsetAfter)
        XCTAssertGreaterThan(offsetAfter, offsetBefore)

        let rawUpdated1 = try await service.session(id1)
        let updated1 = try XCTUnwrap(rawUpdated1)
        XCTAssertEqual(updated1.messages.map(\.role), [.user, .tool, .tool, .system, .assistant])
        XCTAssertEqual(updated1.messages[3].content, "Done")
        XCTAssertEqual(updated1.messages[4].content, "Updated \(project.path)/Sources/Main.swift")
        XCTAssertEqual(updated1.runState, .finished)
        let rawRenamedSummary = try await service.summary(id1)
        let renamedSummary = try XCTUnwrap(rawRenamedSummary)
        XCTAssertEqual(renamedSummary.title, "Renamed Antigravity Chat")

        // Verify MCP handoff & redaction with antigravity agent.
        let handler = MCPHandler(service: service)
        _ = try await service.logProgress(project: projectID1, agent: "codex", done: "Finished parser")
        let contextResponse = try await callTool(handler, name: "memory_get_context", arguments: ["project": projectID1, "target_agent": "antigravity"])
        XCTAssertTrue(contextResponse.contains("Finished parser"))
        XCTAssertTrue(contextResponse.contains("[PROJECT]/Sources/Main.swift"))
        XCTAssertFalse(contextResponse.contains(project.path))

        let readResponse = try await callTool(handler, name: "memory_read_agent", arguments: ["project": projectID1, "agent": "antigravity"])
        let readObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(readResponse.utf8)) as? [String: Any])
        let selectedChat = try XCTUnwrap(readObject["selected"] as? [String: Any])
        XCTAssertEqual(selectedChat["title"] as? String, "Renamed Antigravity Chat")
        let readMessages = try XCTUnwrap(selectedChat["messages"] as? [[String: Any]])
        XCTAssertTrue(readMessages.contains { ($0["content"] as? String)?.contains("[PROJECT]/Sources/Main.swift") == true })

        let progressResponse = try await callTool(handler, name: "memory_log_progress", arguments: ["project": projectID1, "agent": "antigravity", "done": "Integrated Antigravity"])
        XCTAssertTrue(progressResponse.contains("Integrated Antigravity"))

        // Archive and restore via conversations_fts.
        sql("UPDATE conversations_fts SET archived=1 WHERE conversation_id='conv-1'")
        let archivedScan = await service.scan()
        XCTAssertEqual(archivedScan.archived, 1)
        let liveIDs = try await service.sessions().map(\.id)
        XCTAssertFalse(liveIDs.contains(id1))

        sql("UPDATE conversations_fts SET archived=0 WHERE conversation_id='conv-1'")
        _ = await service.scan()
        let restoredIDs = try await service.sessions().map(\.id)
        XCTAssertTrue(restoredIDs.contains(id1))
    }

    func testAntigravityRunStateMapping() {
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_RUNNING", notFullyIdle: true, killed: false), .running)
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_BUSY", notFullyIdle: false, killed: false), .running)
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_WAITING_FOR_USER", notFullyIdle: true, killed: false), .awaitingApproval)
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_CANCELING", notFullyIdle: true, killed: false), .aborted)
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_IDLE", notFullyIdle: false, killed: false), .finished)
        XCTAssertEqual(AgentIdentityCatalog.antigravityRunState(status: "CASCADE_RUN_STATUS_IDLE", notFullyIdle: false, killed: true), .aborted)
    }

    private func jsonl(_ items: [[String: Any]]) throws -> String {
        try items.map { item in
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    private func callTool(_ handler: MCPHandler, name: String, arguments: [String: Any]) async throws -> String {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let raw = try JSONSerialization.data(withJSONObject: request)
        let rawResponseData = await handler.handle(raw)
        let responseData = try XCTUnwrap(rawResponseData)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
