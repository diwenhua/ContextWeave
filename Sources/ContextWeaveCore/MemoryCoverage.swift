import Foundation

/// Coverage is measured against stored source messages, not wall-clock age.
public struct MemoryCoverage: Codable, Sendable, Equatable {
    public let status: String // current, stale, unknown, missing
    public let reason: String
    public let coveredMessages: Int
    public let totalMessages: Int
    public let coveredDialogueMessages: Int
    public let totalDialogueMessages: Int
    public let lastCoveredMessageID: String?
    public let updatedAt: Int64?
    public let pendingDialogueMessages: Int
    public let minimumNewMessages: Int
    public let autoUpdate: String // off, accumulating, pending, retrying, idle, model_changed
    public var uncoveredMessages: Int { max(0, totalMessages - coveredMessages) }
    public var inputScope: String { "user_and_assistant_text; tool messages inside the source boundary are not summarized" }
}

struct MemorySourceSnapshot: Equatable {
    let count: Int
    let lastID: String
    let digest: String
}

public struct MemoryCatchUp: Encodable, Sendable {
    public let offset: Int
    public let nextOffset: Int?
    public let total: Int
    public let messages: [SessionMessage]
    public let latestMessages: [SessionMessage]
    public let truncatedMessageIDs: [String]
    public let instructions: String
}

/// Missing preference means inherit, including sessions captured in the future.
public enum MemoryUpdatePreference: String, Codable, Sendable, CaseIterable {
    case inherit, enabled, disabled

    public func isEnabled(agentDefault: Bool) -> Bool {
        switch self {
        case .inherit: agentDefault
        case .enabled: true
        case .disabled: false
        }
    }
}
