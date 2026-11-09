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
    public let projectID: String?
    public let messages: [SessionMessage]

    public init(source: SessionSource, projectID: String?, messages: [SessionMessage]) {
        self.source = source
        self.projectID = projectID
        self.messages = messages
    }
}
