import Foundation

/// CLI and local Desktop Code sessions share the user-scoped MCP registration.
public struct ClaudePaths: Sendable {
    public let directory: URL
    public let configuration: URL
    public var projects: URL { directory.appendingPathComponent("projects") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let raw = environment["CLAUDE_CONFIG_DIR"],
           let path = AppSettings.standardizedPath(raw, home: home) {
            directory = URL(fileURLWithPath: path)
            configuration = directory.appendingPathComponent(".claude.json")
        } else {
            directory = home.appendingPathComponent(".claude")
            configuration = home.appendingPathComponent(".claude.json")
        }
    }
}
