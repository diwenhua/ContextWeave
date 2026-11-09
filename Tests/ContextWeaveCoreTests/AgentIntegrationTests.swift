import XCTest
@testable import ContextWeaveCore

final class AgentIntegrationTests: XCTestCase {
    func testCursorConfigurationPreservesServersAndRejectsUnmanagedEntry() throws {
        let original = #"{"mcpServers":{"other":{"command":"keep"}},"otherSetting":true}"#
        let configured = try AgentIntegration.cursorConfiguration(original, executable: "/tmp/helper with spaces")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configured.utf8)) as? [String: Any])
        XCTAssertEqual(object["otherSetting"] as? Bool, true)
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: String])?["command"], "keep")
        XCTAssertEqual(try AgentIntegration.cursorConfiguration(configured, executable: "/tmp/helper with spaces"), configured)
        let removed = try AgentIntegration.cursorConfiguration(configured, executable: nil)
        XCTAssertTrue(removed.contains("other")); XCTAssertFalse(removed.contains("contextweave"))
        XCTAssertThrowsError(try AgentIntegration.cursorConfiguration(#"{"mcpServers":{"contextweave":{"command":"custom"}}}"#, executable: "/tmp/helper"))
    }

    func testCursorStatusAndConnectionRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AgentIntegration.cursorStatus(home: root).state, .notConfigured)
        _ = try AgentIntegration.configureCursor(executable: "/usr/bin/true", home: root)
        XCTAssertEqual(AgentIntegration.cursorStatus(home: root).state, .connected)
        XCTAssertEqual(AgentIntegration.cursorStatus(home: root).helperPath, "/usr/bin/true")
        _ = try AgentIntegration.configureCursor(executable: nil, home: root)
        XCTAssertEqual(AgentIntegration.cursorStatus(home: root).state, .notConfigured)
    }
    func testManagedConfigurationPreservesOtherServersAndIsIdempotent() throws {
        let original = "[mcp_servers.other]\r\ncommand = \"other\"\r\n"
        let snippet = AgentIntegration.codexSnippet(executable: "/tmp/path with spaces/helper")
        let once = try AgentIntegration.merging(original, snippet: snippet)
        XCTAssertTrue(once.hasPrefix(original))
        XCTAssertEqual(try AgentIntegration.merging(once, snippet: snippet), once)
        let updated = try AgentIntegration.merging(once, snippet: AgentIntegration.codexSnippet(executable: "/new/helper"))
        XCTAssertTrue(updated.hasPrefix(original)); XCTAssertTrue(updated.contains("/new/helper")); XCTAssertFalse(updated.contains("path with spaces"))
        XCTAssertThrowsError(try AgentIntegration.merging("[mcp_servers.contextweave]\ncommand=\"existing\"", snippet: snippet))
    }
    func testConnectPreflightsBothAndBacksUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("config.toml"), dsh = root.appendingPathComponent("cordis.patch.yml")
        try Data("# keep me\n".utf8).write(to: codex)
        try Data("- id: contextweave\n".utf8).write(to: dsh)
        XCTAssertThrowsError(try AgentIntegration.connect(executable: "/usr/bin/true", codexHome: root, dshHome: root))
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), "# keep me\n")
        try Data("# other patches\n".utf8).write(to: dsh)
        let messages = try AgentIntegration.connect(executable: "/usr/bin/true", codexHome: root, dshHome: root)
        XCTAssertEqual(messages.filter { $0.hasPrefix("Backup:") }.count, 2)
        let again = try AgentIntegration.connect(executable: "/usr/bin/true", codexHome: root, dshHome: root)
        XCTAssertEqual(again.filter { $0.hasPrefix("Already connected:") }.count, 2)
    }

    func testStatusRemoveRoundTripRestoresOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexHome = root.appendingPathComponent("codex"), dshHome = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codex = codexHome.appendingPathComponent("config.toml")
        let dsh = dshHome.appendingPathComponent("cordis.patch.yml")
        let originalCodex = "# keep me\r\n"
        let originalDsh = "# other patches\n"
        try Data(originalCodex.utf8).write(to: codex)
        try Data(originalDsh.utf8).write(to: dsh)

        XCTAssertEqual(
            AgentIntegration.status(codexHome: codexHome, dshHome: dshHome).map(\.state),
            [.notConfigured, .notConfigured]
        )
        _ = try AgentIntegration.connect(executable: "/usr/bin/true", codexHome: codexHome, dshHome: dshHome)

        let statuses = AgentIntegration.status(codexHome: codexHome, dshHome: dshHome)
        XCTAssertEqual(statuses.map(\.state), [.connected, .connected])
        XCTAssertEqual(statuses.map(\.helperPath), ["/usr/bin/true", "/usr/bin/true"])
        XCTAssertEqual(statuses.map(\.configPath), [codex.path, dsh.path])

        let messages = try AgentIntegration.remove(codexHome: codexHome, dshHome: dshHome)
        XCTAssertEqual(messages.filter { $0.hasPrefix("Removed:") }.count, 2)
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), originalCodex)
        XCTAssertEqual(try String(contentsOf: dsh, encoding: .utf8), originalDsh)
        XCTAssertEqual(
            AgentIntegration.status(codexHome: codexHome, dshHome: dshHome).map(\.state),
            [.notConfigured, .notConfigured]
        )
    }

    func testRemoveEmptyRegistrationAndPreserveCRLF() throws {
        let snippet = AgentIntegration.codexSnippet(executable: "/tmp/helper")
        let connected = try AgentIntegration.merging("", snippet: snippet)
        XCTAssertEqual(try AgentIntegration.removing(connected), "")

        let connectedCRLF = try AgentIntegration.merging("# keep\r\n", snippet: snippet)
        XCTAssertEqual(try AgentIntegration.removing(connectedCRLF), "# keep\r\n")
        XCTAssertEqual(try AgentIntegration.removing("# untouched\n"), "# untouched\n")
    }

    func testUnmanagedEntryIsReportedAndRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexHome = root.appendingPathComponent("codex"), dshHome = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codex = codexHome.appendingPathComponent("config.toml")
        let dsh = dshHome.appendingPathComponent("cordis.patch.yml")
        let unmanaged = "# hand written\n[mcp_servers.contextweave]\ncommand = \"/tmp/old\"\n"
        try Data(unmanaged.utf8).write(to: codex)
        try Data("# unrelated\n".utf8).write(to: dsh)

        let statuses = AgentIntegration.status(codexHome: codexHome, dshHome: dshHome)
        XCTAssertEqual(statuses.map(\.state), [.unmanaged, .notConfigured])
        XCTAssertThrowsError(try AgentIntegration.remove(codexHome: codexHome, dshHome: dshHome))
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), unmanaged)
        XCTAssertEqual(try String(contentsOf: dsh, encoding: .utf8), "# unrelated\n")
    }
}
