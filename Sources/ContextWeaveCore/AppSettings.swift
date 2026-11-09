import Foundation

/// User-editable configuration shared by the app and the separately launched MCP helper.
/// It is stored as JSON so both processes resolve the same session folders and database.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Absolute path, or empty to use `CODEX_HOME` / the home directory default.
    public var codexSessionsPath: String
    /// Absolute path, or empty to use `DSH_HOME` / the home directory default.
    public var dshSessionsPath: String
    /// Cursor User directory, or empty to use its macOS default.
    public var cursorUserPath: String
    /// Absolute file path, or empty to use `CONTEXTWEAVE_DB` / Application Support.
    public var databasePath: String
    public var watchAutomatically: Bool
    public var scanIntervalSeconds: Int
    /// GUI-only preference; the MCP helper ignores it.
    public var appearance: AppearancePreference

    public static let defaultScanIntervalSeconds = 300
    public static let scanIntervalChoices = [15, 30, 60, 300, 900, 1800]

    public init(
        codexSessionsPath: String = "",
        dshSessionsPath: String = "",
        cursorUserPath: String = "",
        databasePath: String = "",
        watchAutomatically: Bool = true,
        scanIntervalSeconds: Int = AppSettings.defaultScanIntervalSeconds,
        appearance: AppearancePreference = .system
    ) {
        self.codexSessionsPath = codexSessionsPath
        self.dshSessionsPath = dshSessionsPath
        self.cursorUserPath = cursorUserPath
        self.databasePath = databasePath
        self.watchAutomatically = watchAutomatically
        self.scanIntervalSeconds = scanIntervalSeconds
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case codexSessionsPath, dshSessionsPath, cursorUserPath, databasePath, watchAutomatically, scanIntervalSeconds, appearance
    }

    /// Missing or unknown keys fall back to defaults so older files stay readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexSessionsPath = try container.decodeIfPresent(String.self, forKey: .codexSessionsPath) ?? ""
        dshSessionsPath = try container.decodeIfPresent(String.self, forKey: .dshSessionsPath) ?? ""
        cursorUserPath = try container.decodeIfPresent(String.self, forKey: .cursorUserPath) ?? ""
        databasePath = try container.decodeIfPresent(String.self, forKey: .databasePath) ?? ""
        watchAutomatically = try container.decodeIfPresent(Bool.self, forKey: .watchAutomatically) ?? true
        let interval = try container.decodeIfPresent(Int.self, forKey: .scanIntervalSeconds) ?? Self.defaultScanIntervalSeconds
        scanIntervalSeconds = Self.scanIntervalChoices.contains(interval) ? interval : Self.defaultScanIntervalSeconds
        let appearance = try container.decodeIfPresent(String.self, forKey: .appearance)
        self.appearance = appearance.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    public var hasCustomPaths: Bool {
        !codexSessionsPath.isEmpty || !dshSessionsPath.isEmpty || !cursorUserPath.isEmpty || !databasePath.isEmpty
    }

    /// Explicit app settings win over environment variables; environment variables win over defaults.
    public func resolvedPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ResolvedPaths {
        let codexHome = environment["CODEX_HOME"]
            .flatMap { Self.standardizedPath($0, home: home) }
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let dshHome = environment["DSH_HOME"]
            .flatMap { Self.standardizedPath($0, home: home) }
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
        let defaultDatabase = environment["CONTEXTWEAVE_DB"]
            .flatMap { Self.standardizedPath($0, home: home) }
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Application Support/ContextWeave/contextweave.sqlite")

        func resolve(_ raw: String, fallback: URL) -> URL {
            Self.standardizedPath(raw, home: home).map { URL(fileURLWithPath: $0) } ?? fallback
        }

        return ResolvedPaths(
            codexSessions: resolve(codexSessionsPath, fallback: codexHome.appendingPathComponent("sessions")),
            dshSessions: resolve(dshSessionsPath, fallback: dshHome.appendingPathComponent("sessions")),
            database: resolve(databasePath, fallback: defaultDatabase),
            cursorUser: resolve(cursorUserPath, fallback: home.appendingPathComponent("Library/Application Support/Cursor/User"))
        )
    }

    public func captureConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CaptureConfiguration {
        let paths = resolvedPaths(environment: environment, home: home)
        return CaptureConfiguration(codexRoot: paths.codexSessions, dshRoot: paths.dshSessions, databaseURL: paths.database, deviceIdentityDirectory: SettingsFile.defaultURL(environment: environment, home: home).deletingLastPathComponent(), cursorUserRoot: paths.cursorUser)
    }

    /// Returns a standardized absolute path, or nil for blank/relative input.
    public static func standardizedPath(_ raw: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "~" {
            value = home.path
        } else if value.hasPrefix("~/") {
            value = home.path + String(value.dropFirst(1))
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}

public struct ResolvedPaths: Equatable, Sendable {
    public let codexSessions: URL
    public let dshSessions: URL
    public let database: URL
    public let cursorUser: URL

    public init(codexSessions: URL, dshSessions: URL, database: URL, cursorUser: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User")) {
        self.codexSessions = codexSessions
        self.dshSessions = dshSessions
        self.database = database
        self.cursorUser = cursorUser
    }
}

/// The JSON file read by both the app and the MCP helper.
public enum SettingsFile {
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CONTEXTWEAVE_SETTINGS"],
           let path = AppSettings.standardizedPath(override, home: home) {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Library/Application Support/ContextWeave/settings.json")
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppSettings {
        (try? read(from: defaultURL(environment: environment, home: home))) ?? AppSettings()
    }

    public static func read(from url: URL) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
    }

    public static func write(_ settings: AppSettings, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
