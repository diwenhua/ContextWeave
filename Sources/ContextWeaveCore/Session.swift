import Foundation

/// A source identity is scoped to the agent; file paths may change over time.
public struct SessionID: Hashable, Codable, Sendable {
    public let agent: String
    public let externalID: String

    public init(agent: String, externalID: String) throws {
        guard !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyIdentity
        }
        self.agent = agent
        self.externalID = externalID
    }

    public enum ValidationError: Error, Equatable {
        case emptyIdentity
    }
}

public struct SessionSource: Codable, Sendable {
    public let id: SessionID
    public let sourcePath: String

    public init(id: SessionID, sourcePath: String) {
        self.id = id
        self.sourcePath = sourcePath
    }
}

public enum SessionRunState: String, Codable, Sendable {
    case running
    case awaitingApproval
    case finished
    case aborted
}

public struct SessionMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, tool, system
    }

    public let id: String
    public let role: Role
    public let content: String
    /// UTC Unix timestamp in milliseconds, if supplied by the source.
    public let timestampMilliseconds: Int64?

    public init(id: String, role: Role, content: String, timestampMilliseconds: Int64?) {
        self.id = id
        self.role = role
        self.content = content
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct Session: Codable, Sendable {
    public let source: SessionSource
    /// Legacy local workspace path; use stableProjectID for cross-workspace identity.
    public let projectID: String?
    public let stableProjectID: String?
    public let messages: [SessionMessage]
    /// Codex history shards share globally ordered event IDs.
    public let messageIDsAreOrdinals: Bool?
    /// Latest source turn boundary. Nil when the log has no start or end event.
    public let runState: SessionRunState?
    /// Name currently set in the agent. Nil when the agent has no separate conversation name.
    public let agentTitle: String?

    public init(source: SessionSource, projectID: String?, messages: [SessionMessage], messageIDsAreOrdinals: Bool? = nil, stableProjectID: String? = nil, runState: SessionRunState? = nil, agentTitle: String? = nil) {
        self.source = source
        self.projectID = projectID
        self.stableProjectID = stableProjectID
        self.messages = messages
        self.messageIDsAreOrdinals = messageIDsAreOrdinals
        self.runState = runState
        self.agentTitle = agentTitle
    }
}
