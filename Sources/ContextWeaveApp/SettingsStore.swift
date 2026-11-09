import Foundation
import Combine
import ContextWeaveCore

/// Persists settings to the shared JSON file so the MCP helper resolves the same paths.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var error: String?
    let fileURL: URL
    private let writer = DispatchQueue(label: "contextweave.settings.writer", qos: .utility)
    private var writeRevision = 0

    init(fileURL: URL = SettingsFile.defaultURL()) {
        self.fileURL = fileURL
        do {
            settings = try SettingsFile.read(from: fileURL)
        } catch {
            settings = AppSettings()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                self.error = String(localized: "settings.error.read", bundle: .module) + " " + error.localizedDescription
            }
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        writeRevision += 1
        let revision = writeRevision
        let url = fileURL
        let snapshot = copy
        writer.async { [weak self] in
            let failure: String?
            do { try SettingsFile.write(snapshot, to: url); failure = nil }
            catch { failure = error.localizedDescription }
            Task { @MainActor [weak self] in
                guard let self, self.writeRevision == revision else { return }
                self.error = failure.map { String(localized: "settings.error.write", bundle: .module) + " " + $0 }
            }
        }
    }
}

enum AppPaths {
    /// The helper lives beside the app binary inside a bundle, or beside the development executable.
    static var helperExecutable: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/contextweave-mcp").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("contextweave-mcp")
            .path
    }

    static var helperAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperExecutable)
    }

    static var codexHome: URL {
        environmentHome("CODEX_HOME", fallback: ".codex")
    }

    static var dshHome: URL {
        environmentHome("DSH_HOME", fallback: ".dsh")
    }

    static var cursorHome: URL {
        environmentHome("CURSOR_HOME", fallback: ".cursor")
    }

    static var settingsURL: URL { SettingsFile.defaultURL() }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private static func environmentHome(_ key: String, fallback: String) -> URL {
        if let value = ProcessInfo.processInfo.environment[key],
           let path = AppSettings.standardizedPath(value) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
    }
}
