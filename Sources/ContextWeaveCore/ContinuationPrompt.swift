import Foundation

/// The selected conversation a handoff should continue. The clipboard names it and does not include the transcript.
public struct ContinuationBrief: Sendable, Equatable {
    public let projectID: String
    public let agent: String
    public let sessionID: String
    public let title: String

    public init(projectID: String, agent: String, sessionID: String, title: String) {
        self.projectID = projectID
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
    }
}

/// Clipboard text that tells another agent which conversation to load through MCP.
public enum ContinuationPrompt {
    public static func normalized(_ title: String) -> String {
        title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func text(_ brief: ContinuationBrief, chinese: Bool) -> String {
        let source = displayName(brief.agent)
        let title = brief.title.isEmpty ? brief.sessionID : brief.title
        if chinese {
            return """
            接续这一条已有对话。调用 memory_read_agent 读取它，并据此理解问题。不要改接到同项目里的其他对话。

            project: \(brief.projectID)
            agent: \(brief.agent)
            session_id: \(brief.sessionID)
            session_name: \(title)

            来源是 \(source)。session_id 是唯一编号；名称相同时以 session_id 为准。
            """
        }
        return """
        Continue this existing conversation. Call memory_read_agent, read it, and understand the problem from that result. Do not switch to another conversation in the same project.

        project: \(brief.projectID)
        agent: \(brief.agent)
        session_id: \(brief.sessionID)
        session_name: \(title)

        Source is \(source). session_id is the unique id; when names match, session_id wins.
        """
    }

    private static func displayName(_ agent: String) -> String {
        switch agent {
        case "dsh": "DeepSeek Harness"
        case "cursor": "Cursor"
        case "antigravity": "Antigravity"
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: agent
        }
    }
}
