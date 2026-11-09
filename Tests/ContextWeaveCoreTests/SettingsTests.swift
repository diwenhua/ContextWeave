import XCTest
@testable import ContextWeaveCore

final class SettingsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")

    func testDefaultsUseEnvironmentHomesThenHome() {
        let resolved = AppSettings().resolvedPaths(
            environment: ["CODEX_HOME": "/opt/codex", "DSH_HOME": "~/dsh-home"],
            home: home
        )
        XCTAssertEqual(resolved.codexSessions.path, "/opt/codex/sessions")
        XCTAssertEqual(resolved.dshSessions.path, "/Users/example/dsh-home/sessions")
        XCTAssertEqual(resolved.database.path, "/Users/example/Library/Application Support/ContextWeave/contextweave.sqlite")
    }

    func testCustomPathsOverrideEnvironmentAndExpandTilde() {
        let settings = AppSettings(
            codexSessionsPath: "~/codex-sessions",
            dshSessionsPath: "/tmp/dsh sessions",
            databasePath: "/tmp/custom.sqlite"
        )
        let environment = ["CODEX_HOME": "/opt/codex", "CONTEXTWEAVE_DB": "/tmp/env.sqlite"]
        let resolved = settings.resolvedPaths(environment: environment, home: home)
        XCTAssertEqual(resolved.codexSessions.path, "/Users/example/codex-sessions")
        XCTAssertEqual(resolved.dshSessions.path, "/tmp/dsh sessions")
        XCTAssertEqual(resolved.database.path, "/tmp/custom.sqlite")

        let configuration = settings.captureConfiguration(environment: environment, home: home)
        XCTAssertEqual(configuration.codexRoot, resolved.codexSessions)
        XCTAssertEqual(configuration.dshRoot, resolved.dshSessions)
        XCTAssertEqual(configuration.databaseURL, resolved.database)
    }

    func testRelativeAndStandardizedPaths() {
        XCTAssertNil(AppSettings.standardizedPath("relative/path", home: home))
        XCTAssertNil(AppSettings.standardizedPath("   ", home: home))
        XCTAssertEqual(AppSettings.standardizedPath("~/a/../b", home: home), "/Users/example/b")
        XCTAssertEqual(AppSettings.standardizedPath("~", home: home), "/Users/example")

        let settings = AppSettings(codexSessionsPath: "relative/path")
        XCTAssertEqual(
            settings.resolvedPaths(environment: [:], home: home).codexSessions.path,
            "/Users/example/.codex/sessions"
        )
    }

    func testCodableRoundTripAndInvalidIntervalFallback() throws {
        let settings = AppSettings(
            codexSessionsPath: "/a",
            dshSessionsPath: "/b",
            databasePath: "/c.sqlite",
            watchAutomatically: false,
            scanIntervalSeconds: 900,
            appearance: .dark
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)

        let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AppSettings())

        let invalid = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"scanIntervalSeconds": 7, "watchAutomatically": false, "appearance": "sepia"}"#.utf8)
        )
        XCTAssertEqual(invalid.scanIntervalSeconds, AppSettings.defaultScanIntervalSeconds)
        XCTAssertFalse(invalid.watchAutomatically)
        XCTAssertEqual(invalid.appearance, .system)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance": "light"}"#.utf8))
        XCTAssertEqual(legacy.appearance, .light)
    }

    func testSettingsFileRoundTripAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["CONTEXTWEAVE_SETTINGS": url.path]
        XCTAssertEqual(SettingsFile.load(environment: environment, home: home), AppSettings())

        let settings = AppSettings(
            codexSessionsPath: "/sessions",
            databasePath: "/custom.sqlite",
            watchAutomatically: false,
            scanIntervalSeconds: 60,
            appearance: .light
        )
        try SettingsFile.write(settings, to: url)
        XCTAssertEqual(try SettingsFile.read(from: url), settings)
        XCTAssertEqual(SettingsFile.load(environment: environment, home: home), settings)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSettingsFileDefaultLocationAndOverride() {
        let defaultURL = SettingsFile.defaultURL(environment: [:], home: home)
        XCTAssertEqual(defaultURL.path, "/Users/example/Library/Application Support/ContextWeave/settings.json")

        let override = SettingsFile.defaultURL(environment: ["CONTEXTWEAVE_SETTINGS": "~/alt/settings.json"], home: home)
        XCTAssertEqual(override.path, "/Users/example/alt/settings.json")
    }
}
