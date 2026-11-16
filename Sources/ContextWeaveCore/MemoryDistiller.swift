import Foundation
import CryptoKit

/// A compressed note ContextWeave keeps for one captured conversation.
public struct ProjectMemory: Sendable, Equatable {
    public let id: String
    public let scope: String
    public let status: String
    public let sourceMessageID: String?
    public let kind: String
    public let agent: String
    public let externalID: String
    public let stableProjectID: String
    public let content: String
    public let updatedAt: Int64

    public init(kind: String, agent: String, externalID: String, stableProjectID: String, content: String, updatedAt: Int64, id: String = "", status: String = "candidate", sourceMessageID: String? = nil, scope: String = "session") {
        self.id = id; self.scope = scope; self.status = status; self.sourceMessageID = sourceMessageID
        self.kind = kind
        self.agent = agent
        self.externalID = externalID
        self.stableProjectID = stableProjectID
        self.content = content
        self.updatedAt = updatedAt
    }
}
