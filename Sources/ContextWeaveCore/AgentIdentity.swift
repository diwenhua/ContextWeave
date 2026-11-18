import Foundation
import CSQLite

/// The agent's current name and project path for one conversation.
/// Transcript files often keep the original title and directory, so these come from the agent's own index.
struct AgentSessionIdentity: Sendable {
    var agent: String
    var externalID: String
    var title: String?
    var projectPath: String?
    var runState: SessionRunState? = nil
}

struct AntigravityConversationMetadata: Sendable {
    var externalID: String
    var title: String?
    var projectPath: String?
    var runState: SessionRunState?
    var isSubagent: Bool
    var isArchived: Bool
}

enum AgentIdentityCatalog {
    static func identities(agent: String, root: URL) -> [AgentSessionIdentity] {
        switch agent {
        case "codex": return codex(root: root)
        case "dsh": return dsh(root: root)
        case "antigravity": return antigravity(root: root)
        default: return []
        }
    }

    /// `session_index.jsonl` is the rename log. `state_N.sqlite` holds the current thread name and cwd.
    /// The scanner root is `~/.codex/sessions`; both files live in the parent home.
    private static func codex(root: URL) -> [AgentSessionIdentity] {
        var records: [String: AgentSessionIdentity] = [:]
        for home in locations(root) {
            if let database = latestStateDatabase(in: home) {
                for row in threads(in: database) {
                    records[row.id] = AgentSessionIdentity(agent: "codex", externalID: row.id, title: row.name ?? row.title, projectPath: row.cwd)
                }
            }
            for (id, name) in sessionIndex(home.appendingPathComponent("session_index.jsonl")) {
                var record = records[id] ?? AgentSessionIdentity(agent: "codex", externalID: id, title: nil, projectPath: nil)
                record.title = name
                records[id] = record
            }
        }
        return Array(records.values)
    }

    /// The projection cache stores the edited title. The workspace table stores the current project address.
    /// The scanner root is `~/.dsh/sessions`; the cache lives in the parent home.
    private static func dsh(root: URL) -> [AgentSessionIdentity] {
        var records: [String: AgentSessionIdentity] = [:]
        for home in locations(root) {
            records.merge(dshCache(home)) { _, later in later }
        }
        return Array(records.values)
    }

    private static func locations(_ root: URL) -> [URL] {
        let parent = root.deletingLastPathComponent()
        return parent.path == root.path ? [root] : [root, parent]
    }

    private static func dshCache(_ root: URL) -> [String: AgentSessionIdentity] {
        let directory = root.appendingPathComponent("storages/session_projcache/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let stems = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        let workspacePaths = workspaceSessions(root.appendingPathComponent("storages/workspace.json"))
        var records: [String: AgentSessionIdentity] = [:]
        for file in files where file.pathExtension == "json" {
            guard let object = json(file) as? [String: Any],
                  let record = object["record"] as? [String: Any] else { continue }
            let identity = record["identity"] as? [String: Any] ?? [:]
            let rows = record["rows"] as? [String: Any] ?? [:]
            let stem = file.deletingPathExtension().lastPathComponent
            var ids = [stem]
            if stem.hasPrefix("session-") {
                let stripped = String(stem.dropFirst("session-".count))
                if !stems.contains(stripped) { ids.append(stripped) }
            }
            let title = rowString(rows["title"])
            let path = ids.compactMap { workspacePaths[$0] }.first ?? rowString(rows["workingDirectory"]) ?? identity["cwd"] as? String
            guard title != nil || path != nil else { continue }
            for id in ids where !id.isEmpty {
                records[id] = AgentSessionIdentity(agent: "dsh", externalID: id, title: title, projectPath: path)
            }
        }
        return records
    }

    private static func sessionIndex(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty,
                  let name = object["thread_name"] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names[id] = trimmed }
        }
        return names
    }

    private static func latestStateDatabase(in root: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.range(of: #"^state_\d+\.sqlite$"#, options: .regularExpression) != nil }
            .max { generation($0) < generation($1) }
    }

    private static func generation(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        return Int(name.dropFirst("state_".count)) ?? 0
    }

    private struct ThreadRow { var id: String; var cwd: String?; var name: String?; var title: String? }

    private static func threads(in database: URL) -> [ThreadRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, cwd, name, title FROM threads", -1, &query, nil) == SQLITE_OK, let query else { return [] }
        defer { sqlite3_finalize(query) }
        var rows: [ThreadRow] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let id = column(query, 0), !id.isEmpty else { continue }
            rows.append(ThreadRow(id: id, cwd: column(query, 1), name: column(query, 2), title: column(query, 3)))
        }
        return rows
    }

    private static func column(_ query: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(query, index) != SQLITE_NULL, let text = sqlite3_column_text(query, index) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func workspaceSessions(_ url: URL) -> [String: String] {
        guard let object = json(url) as? [String: Any],
              let tables = object["tables"] as? [String: Any],
              let workspaces = tables["workspaces"] as? [String: Any] else { return [:] }
        var paths: [String: String] = [:]
        for value in workspaces.values {
            guard let item = value as? [String: Any], let path = item["path"] as? String, path.hasPrefix("/"),
                  let ids = item["sessionIds"] as? [String] else { continue }
            for id in ids where !id.isEmpty { paths[id] = path }
        }
        return paths
    }

    private static func rowString(_ value: Any?) -> String? {
        guard let row = value as? [String: Any], let text = row["val"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func antigravity(root: URL) -> [AgentSessionIdentity] {
        antigravityMetadata(root: root).values
            .filter { !$0.isSubagent && !$0.isArchived }
            .map {
                AgentSessionIdentity(
                    agent: "antigravity",
                    externalID: $0.externalID,
                    title: $0.title,
                    projectPath: $0.projectPath,
                    runState: $0.runState
                )
            }
    }

    static func antigravityMetadata(root: URL) -> [String: AntigravityConversationMetadata] {
        let database = root.appendingPathComponent("conversation_summaries.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let projectFallbacks = antigravityProjectPaths(root: root)
        var archivedIDs = Set<String>()
        var archivedQuery: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT DISTINCT conversation_id FROM conversations_fts WHERE archived = 1", -1, &archivedQuery, nil) == SQLITE_OK, let archivedQuery {
            defer { sqlite3_finalize(archivedQuery) }
            while sqlite3_step(archivedQuery) == SQLITE_ROW {
                if let id = column(archivedQuery, 0) { archivedIDs.insert(id) }
            }
        }

        var query: OpaquePointer?
        let sql = """
            SELECT conversation_id, title, workspace_uris, status, project_id, parent_conversation_id, nesting_depth, not_fully_idle, killed
            FROM conversation_summaries
            """
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { return [:] }
        defer { sqlite3_finalize(query) }

        var result: [String: AntigravityConversationMetadata] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            guard let id = column(query, 0) else { continue }
            let title = column(query, 1)
            let workspaceURIs = column(query, 2)
            let status = column(query, 3) ?? ""
            let projectID = column(query, 4)
            let parentID = column(query, 5)
            let nestingDepth = sqlite3_column_int(query, 6)
            let notFullyIdle = sqlite3_column_int(query, 7) != 0
            let killed = sqlite3_column_int(query, 8) != 0

            let projectPath = firstWorkspacePath(from: workspaceURIs) ?? projectID.flatMap { projectFallbacks[$0] }
            let isSubagent = (parentID != nil) || nestingDepth > 0
            let runState = antigravityRunState(status: status, notFullyIdle: notFullyIdle, killed: killed)

            result[id] = AntigravityConversationMetadata(
                externalID: id,
                title: title,
                projectPath: projectPath,
                runState: runState,
                isSubagent: isSubagent,
                isArchived: archivedIDs.contains(id)
            )
        }
        return result
    }

    static func antigravityRunState(status: String, notFullyIdle: Bool, killed: Bool) -> SessionRunState? {
        if status.contains("WAITING") { return .awaitingApproval }
        if status == "CASCADE_RUN_STATUS_RUNNING" || status == "CASCADE_RUN_STATUS_BUSY" { return .running }
        if status == "CASCADE_RUN_STATUS_CANCELING" || killed { return .aborted }
        if status == "CASCADE_RUN_STATUS_IDLE" { return notFullyIdle ? .running : .finished }
        if notFullyIdle { return .running }
        return nil
    }

    private static func firstWorkspacePath(from jsonArrayText: String?) -> String? {
        guard let jsonArrayText,
              let data = jsonArrayText.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        for raw in values {
            if raw.hasPrefix("/") { return raw }
            if let url = URL(string: raw), url.isFileURL, url.path.hasPrefix("/") { return url.path }
        }
        return nil
    }

    private static func antigravityProjectPaths(root: URL) -> [String: String] {
        let projectsDir = root.deletingLastPathComponent().appendingPathComponent("config/projects")
        let files = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        var paths: [String: String] = [:]
        for file in files where file.pathExtension == "json" {
            guard let object = json(file) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty,
                  let projectResources = object["projectResources"] as? [String: Any],
                  let resources = projectResources["resources"] as? [[String: Any]] else { continue }
            for resource in resources {
                let gitFolder = resource["gitFolder"] as? [String: Any]
                let candidate = gitFolder?["folderUri"] as? String ?? resource["folderUri"] as? String ?? resource["uri"] as? String
                if let candidate, let url = URL(string: candidate), url.isFileURL, url.path.hasPrefix("/") {
                    paths[id] = url.path
                    break
                }
            }
        }
        return paths
    }
}
