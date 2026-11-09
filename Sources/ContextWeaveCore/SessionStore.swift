import Foundation
import CSQLite

public struct SessionSummary: Identifiable, Codable, Sendable {
    public var id: SessionID { source.id }
    public let source: SessionSource
    /// Legacy workspace path retained for existing clients.
    public let projectID: String?
    public let stableProjectID: String?
    public let title: String
    public let messageCount: Int
    public let lastActivity: Int64
    public let runState: SessionRunState?
}

public struct ProgressEntry: Codable, Sendable {
    public let id: String
    public let project: String
    public let agent: String
    public let done: String
    public let next: String
    public let issues: String
    public let timestamp: Int64
    public let stableProjectID: String?

    public init(id: String, project: String, agent: String, done: String, next: String, issues: String, timestamp: Int64, stableProjectID: String? = nil) {
        self.id = id; self.project = project; self.agent = agent; self.done = done
        self.next = next; self.issues = issues; self.timestamp = timestamp; self.stableProjectID = stableProjectID
    }
}

public struct StoreStats: Sendable, Equatable {
    public let sessions: Int
    public let messages: Int
    public let databaseBytes: Int64

    public init(sessions: Int, messages: Int, databaseBytes: Int64) {
        self.sessions = sessions
        self.messages = messages
        self.databaseBytes = databaseBytes
    }
}

struct FileCursor: Equatable {
    var inode: String
    var parserVersion: String
    var observedSize: Int64
    var observedMtimeMS: Int64
    var offset: Int64
    var pending: String
    var lineIndex: Int
    var externalID: String?
    var project: String?
    var ordinals: Bool
    var rejected: Bool
    var runState: String? = nil
}

/// Confined to HandoffService's actor. WAL permits app and MCP processes to share data.
final class SessionStore {
    private static let skippedTitlePrefixes = ["<environment_context>", "# AGENTS.md instructions", "<external_codex_apps_", "Side conversation boundary."]
    private var db: OpaquePointer?
    let deviceID: String
    init(url: URL, deviceID explicitDeviceID: String? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let explicitDeviceID {
            guard let uuid = UUID(uuidString: explicitDeviceID) else { throw CaptureError.invalid("Invalid device ID") }
            deviceID = uuid.uuidString
        } else {
            deviceID = try LocalDeviceIdentity.loadOrCreate(in: url.deletingLastPathComponent())
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CaptureError.invalid("Cannot open local session database.")
        }
        do {
            sqlite3_busy_timeout(db, 10_000)
            let version = try userVersion()
            guard version <= 6 else { throw CaptureError.invalid("Database schema version \(version) is newer than this application supports.") }
            try run("PRAGMA journal_mode=WAL")
            try run("PRAGMA foreign_keys=ON")
            try migrate()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    func cursors(path: String? = nil) throws -> [String: FileCursor] {
        var result: [String: FileCursor] = [:]
        let sql = "SELECT path, inode, parser_version, observed_size, observed_mtime_ms, offset, pending, line_index, external_id, project, ordinals, rejected, run_state FROM capture_files" + (path == nil ? "" : " WHERE path=?")
        for row in try rows(sql, path.map { [$0] } ?? []) {
            guard let path = row[0] else { continue }
            result[path] = FileCursor(
                inode: row[1] ?? "",
                parserVersion: row[2] ?? "",
                observedSize: Int64(row[3] ?? "") ?? 0,
                observedMtimeMS: Int64(row[4] ?? "") ?? 0,
                offset: Int64(row[5] ?? "") ?? 0,
                pending: row[6] ?? "",
                lineIndex: Int(row[7] ?? "") ?? 0,
                externalID: row[8],
                project: row[9],
                ordinals: row[10] == "1",
                rejected: row[11] == "1",
                runState: row[12]
            )
        }
        return result
    }

    /// Commits parsed messages and the file cursor together. A shorter full reread keeps the stored history.
    func commitCapture(path: String, cursor: FileCursor, session: Session?, fullReplace: Bool, previousAgent: String?, previousExternalID: String?, expectedCursor: FileCursor?) throws {
        try run("BEGIN IMMEDIATE")
        do {
            // The file was parsed outside the write transaction. Another process may have
            // committed a newer cursor meanwhile; never apply this stale snapshot.
            guard try cursors(path: path)[path] == expectedCursor else { throw CaptureError.staleCursor }
            if !cursor.rejected {
                let agent = session?.source.id.agent ?? previousAgent
                let externalID = session?.source.id.externalID ?? previousExternalID
                if fullReplace, let agent, let externalID {
                    let baseline = try count(cursor.ordinals
                        ? "SELECT COUNT(*) FROM messages WHERE agent=? AND external_id=? AND source_path=?"
                        : "SELECT COUNT(*) FROM messages WHERE agent=? AND external_id=?",
                        cursor.ordinals ? [agent, externalID, path] : [agent, externalID])
                    if baseline > (session?.messages.count ?? 0) {
                        throw CaptureError.invalid("Session became shorter; retaining stored history: \(path)")
                    }
                }
                if let session {
                    let agent = session.source.id.agent, externalID = session.source.id.externalID
                    let storedStableID = try text("SELECT stable_project_id FROM sessions WHERE agent=? AND external_id=?", [agent, externalID])
                    let storedProject = try text("SELECT project FROM sessions WHERE agent=? AND external_id=?", [agent, externalID])
                    let assignment = try preservedProject(storedPath: storedProject, storedStableID: storedStableID, incomingPath: session.projectID)
                    if fullReplace {
                        if cursor.ordinals {
                            try run("DELETE FROM messages WHERE agent=? AND external_id=? AND source_path=?", [session.source.id.agent, session.source.id.externalID, path])
                        } else {
                            try run("DELETE FROM messages WHERE agent=? AND external_id=?", [session.source.id.agent, session.source.id.externalID])
                        }
                    }
                    try insertMessages(session, path: path)
                    let total = try count("SELECT COUNT(*) FROM messages WHERE agent=? AND external_id=?", [agent, externalID])
                    let activity = Int64(try text("SELECT MAX(timestamp) FROM messages WHERE agent=? AND external_id=?", [agent, externalID]) ?? "") ?? 0
                    let storedTitle = try text("SELECT title FROM sessions WHERE agent=? AND external_id=?", [agent, externalID])
                    let candidates = try titleCandidates(agent: agent, externalID: externalID)
                    // A running transcript is committed before the agent name is reapplied. Keep the current name
                    // so the first user message does not flash in place of it.
                    let title = Self.cleanTitle(session.agentTitle)
                        ?? (storedTitle?.isEmpty == false ? storedTitle : nil)
                        ?? Self.displayTitle(candidates, fallback: externalID)
                    try run("INSERT INTO sessions(agent, external_id, project, title, message_count, activity, source_path, ordinals, stable_project_id, run_state) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(agent, external_id) DO UPDATE SET project=excluded.project, title=excluded.title, message_count=excluded.message_count, activity=excluded.activity, source_path=excluded.source_path, ordinals=excluded.ordinals, stable_project_id=excluded.stable_project_id, run_state=excluded.run_state", [agent, externalID, assignment.path, title, String(total), String(activity), path, cursor.ordinals ? "1" : "0", assignment.stableID, session.runState?.rawValue])
                } else if let runState = cursor.runState, let agent, let externalID {
                    try run("UPDATE sessions SET run_state=? WHERE agent=? AND external_id=?", [runState, agent, externalID])
                }
            }
            try writeCursor(path, cursor)
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    /// Applies names and project addresses that live outside the transcript.
    /// A missing old directory with one agreed new path keeps the same project. A live directory switch moves only that conversation.
    func applyIdentities(_ items: [AgentSessionIdentity]) throws {
        guard !items.isEmpty else { return }
        var pending: [String: String] = [:]
        for item in items {
            guard let path = item.projectPath, path.hasPrefix("/") else { continue }
            pending["\(item.agent)\n\(item.externalID)"] = try ProjectIdentity.canonicalPath(path)
        }
        try run("BEGIN IMMEDIATE")
        do {
            for item in items {
                guard try text("SELECT agent FROM sessions WHERE agent=? AND external_id=?", [item.agent, item.externalID]) != nil else { continue }
                if let title = Self.cleanTitle(item.title) {
                    try run("UPDATE sessions SET title=? WHERE agent=? AND external_id=?", [title, item.agent, item.externalID])
                }
                guard let canonical = pending["\(item.agent)\n\(item.externalID)"] else { continue }
                try relocate(agent: item.agent, externalID: item.externalID, canonical: canonical, pending: pending)
            }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    /// The transcript keeps the directory from the start of the conversation. A later address change is applied from the agent's current index.
    private func preservedProject(storedPath: String?, storedStableID: String?, incomingPath: String?) throws -> (path: String?, stableID: String?) {
        if storedPath != nil { return (storedPath, storedStableID) }
        guard let incomingPath, !incomingPath.isEmpty else { return (nil, storedStableID) }
        let canonical = try ProjectIdentity.canonicalPath(incomingPath)
        if let existing = try projectID(forWorkspace: canonical) { return (canonical, existing) }
        let created = try ensureWorkspace(path: canonical)
        return (created.path, created.projectID)
    }

    private func relocate(agent: String, externalID: String, canonical: String, pending: [String: String]) throws {
        let storedPath = try text("SELECT project FROM sessions WHERE agent=? AND external_id=?", [agent, externalID])
        let storedStable = try text("SELECT stable_project_id FROM sessions WHERE agent=? AND external_id=?", [agent, externalID])
        if storedPath == canonical { return }
        if let existing = try projectID(forWorkspace: canonical) {
            try run("UPDATE sessions SET project=?, stable_project_id=? WHERE agent=? AND external_id=?", [canonical, existing, agent, externalID])
            return
        }
        if let storedPath, let storedStable, !FileManager.default.fileExists(atPath: storedPath) {
            let siblings = try rows("SELECT agent, external_id FROM sessions WHERE stable_project_id=? AND NOT (agent=? AND external_id=?)", [storedStable, agent, externalID])
            let agreed = siblings.allSatisfy { row in
                guard let target = pending["\(row[0] ?? "")\n\(row[1] ?? "")"] else { return true }
                return target == canonical
            }
            if agreed {
                try retargetWorkspace(from: storedPath, to: canonical, projectID: storedStable)
                return
            }
        }
        let created = try ensureWorkspace(path: canonical)
        try run("UPDATE sessions SET project=?, stable_project_id=? WHERE agent=? AND external_id=?", [canonical, created.projectID, agent, externalID])
    }

    private func retargetWorkspace(from old: String, to new: String, projectID: String) throws {
        try run("UPDATE workspaces SET path=? WHERE device_id=? AND path=? AND project_id=?", [new, deviceID, old, projectID])
        try run("UPDATE sessions SET project=? WHERE project=? AND stable_project_id=?", [new, old, projectID])
        for row in try rows("SELECT id, payload FROM progress WHERE project=? AND stable_project_id=?", [old, projectID]) {
            guard let id = row[0], let payload = row[1] else { throw CaptureError.invalid("Progress record is incomplete") }
            let entry = try JSONDecoder().decode(ProgressEntry.self, from: Data(payload.utf8))
            let updated = ProgressEntry(id: entry.id, project: new, agent: entry.agent, done: entry.done, next: entry.next, issues: entry.issues, timestamp: entry.timestamp, stableProjectID: projectID)
            try run("UPDATE progress SET project=?, payload=? WHERE id=?", [new, String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), id])
        }
    }

    func get(_ id: SessionID) throws -> Session? {
        guard let summary = try summary(id) else { return nil }
        let ordinals = try text("SELECT ordinals FROM sessions WHERE agent=? AND external_id=?", [id.agent, id.externalID]) == "1"
        return Session(source: summary.source, projectID: summary.projectID, messages: try messages(id, offset: 0, limit: nil), messageIDsAreOrdinals: ordinals, stableProjectID: summary.stableProjectID, runState: summary.runState)
    }
    func summary(_ id: SessionID) throws -> SessionSummary? {
        try rows("SELECT agent, external_id, project, title, message_count, activity, source_path, stable_project_id, run_state FROM sessions WHERE agent=? AND external_id=?", [id.agent, id.externalID]).first.map(summary(from:))
    }
    func messages(_ id: SessionID, offset: Int, limit: Int?) throws -> [SessionMessage] {
        try rows("SELECT message_id, role, content, timestamp FROM messages WHERE agent=? AND external_id=? ORDER BY ordinal, message_id LIMIT ? OFFSET ?", [id.agent, id.externalID, String(limit ?? -1), String(offset)]).map(Self.message(from:))
    }
    func latestMessages(_ id: SessionID, limit: Int, skip: Int) throws -> [SessionMessage] {
        try rows("SELECT message_id, role, content, timestamp FROM messages WHERE agent=? AND external_id=? ORDER BY ordinal DESC, message_id DESC LIMIT ? OFFSET ?", [id.agent, id.externalID, String(limit), String(skip)]).reversed().map(Self.message(from:))
    }
    func list(project: String? = nil, limit: Int = 200) throws -> [SessionSummary] {
        let query = "SELECT agent, external_id, project, title, message_count, activity, source_path, stable_project_id, run_state FROM sessions" + (project == nil ? "" : " WHERE stable_project_id=(SELECT project_id FROM workspaces WHERE device_id=? AND path=?)") + " ORDER BY activity DESC, agent, external_id LIMIT ?"
        let values: [String?] = (project.map { [deviceID, $0] } ?? []) + [String(limit)]
        return try rows(query, values).map(summary(from:))
    }
    func projects() throws -> [String] { try workspaces().map(\.path) }
    func projectRecords() throws -> [ProjectRecord] {
        try rows("SELECT id, created_at FROM projects ORDER BY id").compactMap { row in
            guard let id = row[0], let created = row[1].flatMap(Int64.init) else { return nil }
            return ProjectRecord(id: id, createdAtMilliseconds: created)
        }
    }
    func workspaces() throws -> [WorkspaceBinding] {
        try rows("SELECT id, project_id, device_id, path FROM workspaces WHERE device_id=? ORDER BY path", [deviceID]).compactMap { row in
            guard let id = row[0], let project = row[1], let device = row[2], let path = row[3] else { return nil }
            return WorkspaceBinding(id: id, projectID: project, deviceID: device, path: path)
        }
    }
    func projectID(forWorkspace path: String) throws -> String? {
        try text("SELECT project_id FROM workspaces WHERE device_id=? AND path=?", [deviceID, path])
    }
    private func ensureWorkspace(path: String) throws -> WorkspaceBinding {
        if let row = try rows("SELECT id, project_id FROM workspaces WHERE device_id=? AND path=?", [deviceID, path]).first,
           let id = row[0], let project = row[1] {
            return WorkspaceBinding(id: id, projectID: project, deviceID: deviceID, path: path)
        }
        let projectID = UUID().uuidString, workspaceID = UUID().uuidString
        try run("INSERT INTO projects(id,created_at) VALUES(?,?)", [projectID, String(Int64(Date().timeIntervalSince1970 * 1000))])
        try run("INSERT INTO workspaces(id,device_id,path,project_id) VALUES(?,?,?,?)", [workspaceID, deviceID, path, projectID])
        return WorkspaceBinding(id: workspaceID, projectID: projectID, deviceID: deviceID, path: path)
    }
    func bindWorkspace(path: String, projectID: String, expectedPreviousProjectID: String? = nil) throws -> WorkspaceBinding {
        try run("BEGIN IMMEDIATE")
        do {
            guard try text("SELECT id FROM projects WHERE id=?", [projectID]) != nil else { throw CaptureError.invalid("Unknown project ID") }
            if let existing = try self.projectID(forWorkspace: path) {
                if existing != projectID {
                    guard expectedPreviousProjectID == existing else { throw CaptureError.invalid("Workspace is already bound to a different project; provide its current project ID to explicitly reassign it.") }
                    guard try count("SELECT COUNT(*) FROM workspaces WHERE project_id=?", [existing]) == 1 else { throw CaptureError.invalid("Cannot reassign a workspace from a project with multiple bindings; no data was moved.") }
                    // Reassign the sole workspace and its records in one transaction.
                    try run("UPDATE workspaces SET project_id=? WHERE device_id=? AND path=?", [projectID, deviceID, path])
                    try run("UPDATE sessions SET stable_project_id=? WHERE stable_project_id=?", [projectID, existing])
                    for row in try rows("SELECT id,payload FROM progress WHERE stable_project_id=?", [existing]) {
                        guard let id = row[0], let payload = row[1] else { throw CaptureError.invalid("Progress record is incomplete") }
                        let entry = try JSONDecoder().decode(ProgressEntry.self, from: Data(payload.utf8))
                        let updated = ProgressEntry(id: entry.id, project: entry.project, agent: entry.agent, done: entry.done, next: entry.next, issues: entry.issues, timestamp: entry.timestamp, stableProjectID: projectID)
                        try run("UPDATE progress SET stable_project_id=?,payload=? WHERE id=?", [projectID, String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), id])
                    }
                }
            } else {
                try run("INSERT INTO workspaces(id,device_id,path,project_id) VALUES(?,?,?,?)", [UUID().uuidString, deviceID, path, projectID])
            }
            guard let result = try workspaces().first(where: { $0.path == path }) else { throw CaptureError.invalid("Cannot read workspace binding") }
            try run("COMMIT")
            return result
        } catch { try? run("ROLLBACK"); throw error }
    }
    func stats(databaseURL: URL) throws -> StoreStats {
        let sessions = try count("SELECT COUNT(*) FROM sessions", [])
        let messages = try count("SELECT COUNT(*) FROM messages", [])
        let bytes = [databaseURL.path, databaseURL.path + "-wal"].reduce(Int64(0)) { total, path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return total }
            return total + size.int64Value
        }
        return StoreStats(sessions: sessions, messages: messages, databaseBytes: bytes)
    }
    @discardableResult
    func log(_ entry: ProgressEntry) throws -> ProgressEntry {
        try run("BEGIN IMMEDIATE")
        do {
            let binding = try ensureWorkspace(path: entry.project)
            let saved = ProgressEntry(id: entry.id, project: entry.project, agent: entry.agent, done: entry.done, next: entry.next, issues: entry.issues, timestamp: entry.timestamp, stableProjectID: binding.projectID)
            try run("INSERT INTO progress(id,project,payload,timestamp,stable_project_id) VALUES(?,?,?,?,?)", [saved.id, saved.project, String(decoding: try JSONEncoder().encode(saved), as: UTF8.self), String(saved.timestamp), binding.projectID])
            try run("COMMIT")
            return saved
        } catch { try? run("ROLLBACK"); throw error }
    }
    func progress(project: String) throws -> [ProgressEntry] {
        try rows("SELECT payload, stable_project_id FROM progress WHERE stable_project_id=(SELECT project_id FROM workspaces WHERE device_id=? AND path=?) ORDER BY timestamp DESC LIMIT 5", [deviceID, project]).map {
            let entry = try JSONDecoder().decode(ProgressEntry.self, from: Data(($0[0] ?? "").utf8))
            return ProgressEntry(id: entry.id, project: entry.project, agent: entry.agent, done: entry.done, next: entry.next, issues: entry.issues, timestamp: entry.timestamp, stableProjectID: $0[1])
        }
    }

    private func migrate() throws {
        try run("BEGIN IMMEDIATE")
        do {
            let version = try userVersion()
            guard version <= 6 else { throw CaptureError.invalid("Database schema version \(version) is newer than this application supports.") }
            if version < 2 {
                if try columns("sessions").contains("payload") { try migratePayload() }
                try createSchema()
                if try !columns("capture_files").contains("offset") {
                    try run("DROP TABLE IF EXISTS capture_files")
                    try createCaptureTable()
                }
            } else {
                try createSchema()
            }
            if version < 3 {
                try run("CREATE INDEX IF NOT EXISTS progress_project_timestamp ON progress(project, timestamp DESC)")
                try run("CREATE INDEX IF NOT EXISTS messages_session_timestamp ON messages(agent, external_id, timestamp DESC)")
                try run("PRAGMA user_version = 3")
            }
            if version < 4 {
                try run("CREATE TABLE projects(id TEXT PRIMARY KEY NOT NULL, created_at INTEGER NOT NULL)")
                try run("CREATE TABLE devices(id TEXT PRIMARY KEY NOT NULL)")
                try run("CREATE TABLE workspaces(id TEXT PRIMARY KEY NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id), path TEXT NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), UNIQUE(device_id,path))")
                try run("INSERT INTO devices(id) VALUES(?)", [deviceID])
                try run("ALTER TABLE sessions ADD COLUMN stable_project_id TEXT REFERENCES projects(id)")
                try run("ALTER TABLE progress ADD COLUMN stable_project_id TEXT REFERENCES projects(id)")
                let paths = try rows("SELECT project FROM sessions WHERE project IS NOT NULL UNION SELECT project FROM progress").compactMap { $0[0] }
                for path in paths {
                    let canonical = try ProjectIdentity.canonicalPath(path)
                    let binding = try ensureWorkspace(path: canonical)
                    try run("UPDATE sessions SET project=?, stable_project_id=? WHERE project=?", [canonical, binding.projectID, path])
                    for row in try rows("SELECT id,payload FROM progress WHERE project=?", [path]) {
                        guard let id = row[0], let payload = row[1] else { throw CaptureError.invalid("Progress record is incomplete") }
                        let entry = try JSONDecoder().decode(ProgressEntry.self, from: Data(payload.utf8))
                        let updated = ProgressEntry(id: entry.id, project: canonical, agent: entry.agent, done: entry.done, next: entry.next, issues: entry.issues, timestamp: entry.timestamp, stableProjectID: binding.projectID)
                        try run("UPDATE progress SET project=?,stable_project_id=?,payload=? WHERE id=?", [canonical, binding.projectID, String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), id])
                    }
                }
                try run("CREATE INDEX sessions_stable_project_activity ON sessions(stable_project_id, activity DESC)")
                try run("CREATE INDEX progress_stable_project_timestamp ON progress(stable_project_id, timestamp DESC)")
                try run("PRAGMA user_version = 4")
            } else {
                try run("INSERT OR IGNORE INTO devices(id) VALUES(?)", [deviceID])
            }
            if version < 5 {
                // Old processes must not silently insert path-only rows after migration.
                try run("CREATE TRIGGER IF NOT EXISTS sessions_project_insert_guard BEFORE INSERT ON sessions WHEN NEW.project IS NOT NULL AND (NEW.stable_project_id IS NULL OR NOT EXISTS(SELECT 1 FROM workspaces WHERE path=NEW.project AND project_id=NEW.stable_project_id)) BEGIN SELECT RAISE(ABORT,'Workspace binding required; restart the older process'); END")
                try run("CREATE TRIGGER IF NOT EXISTS sessions_project_update_guard BEFORE UPDATE ON sessions WHEN NEW.project IS NOT NULL AND (NEW.stable_project_id IS NULL OR NOT EXISTS(SELECT 1 FROM workspaces WHERE path=NEW.project AND project_id=NEW.stable_project_id)) BEGIN SELECT RAISE(ABORT,'Workspace binding required; restart the older process'); END")
                try run("CREATE TRIGGER IF NOT EXISTS progress_project_insert_guard BEFORE INSERT ON progress WHEN NEW.stable_project_id IS NULL OR NOT EXISTS(SELECT 1 FROM workspaces WHERE path=NEW.project AND project_id=NEW.stable_project_id) BEGIN SELECT RAISE(ABORT,'Workspace binding required; restart the older process'); END")
                try run("PRAGMA user_version = 5")
            }
            if version < 6 {
                if try !columns("sessions").contains("run_state") { try run("ALTER TABLE sessions ADD COLUMN run_state TEXT") }
                if try !columns("capture_files").contains("run_state") { try run("ALTER TABLE capture_files ADD COLUMN run_state TEXT") }
                try run("PRAGMA user_version = 6")
            }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    private func migratePayload() throws {
        try run("DROP INDEX IF EXISTS sessions_project_activity")
        try run("ALTER TABLE sessions RENAME TO sessions_legacy")
        try createSessionTables()
        for row in try rows("SELECT payload FROM sessions_legacy") {
            guard let payload = row[0] else { continue }
            let session = try JSONDecoder().decode(Session.self, from: Data(payload.utf8))
            try insertMessages(session, path: session.source.sourcePath)
            let activity = session.messages.compactMap(\.timestampMilliseconds).max() ?? 0
            try run("INSERT INTO sessions(agent, external_id, project, title, message_count, activity, source_path, ordinals) VALUES(?,?,?,?,?,?,?,?)", [session.source.id.agent, session.source.id.externalID, session.projectID, Self.displayTitle(session.messages, fallback: session.source.id.externalID), String(session.messages.count), String(activity), session.source.sourcePath, session.messageIDsAreOrdinals == true ? "1" : "0"])
        }
        try run("DROP TABLE sessions_legacy")
    }
    private func createSchema() throws {
        try createSessionTables()
        try run("CREATE INDEX IF NOT EXISTS sessions_project_activity ON sessions(project, activity DESC)")
        try run("CREATE INDEX IF NOT EXISTS messages_session_order ON messages(agent, external_id, ordinal)")
        try run("CREATE INDEX IF NOT EXISTS messages_source ON messages(source_path)")
        try createCaptureTable()
        try run("CREATE TABLE IF NOT EXISTS progress(id TEXT PRIMARY KEY, project TEXT NOT NULL, payload TEXT NOT NULL, timestamp INTEGER NOT NULL)")
    }
    private func createSessionTables() throws {
        try run("CREATE TABLE IF NOT EXISTS sessions(agent TEXT NOT NULL, external_id TEXT NOT NULL, project TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL, activity INTEGER NOT NULL, source_path TEXT NOT NULL, ordinals INTEGER NOT NULL, PRIMARY KEY(agent, external_id))")
        try run("CREATE TABLE IF NOT EXISTS messages(agent TEXT NOT NULL, external_id TEXT NOT NULL, message_id TEXT NOT NULL, source_path TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, timestamp INTEGER, ordinal INTEGER NOT NULL, PRIMARY KEY(agent, external_id, message_id))")
    }
    private func createCaptureTable() throws {
        try run("CREATE TABLE IF NOT EXISTS capture_files(path TEXT PRIMARY KEY, inode TEXT NOT NULL, parser_version TEXT NOT NULL, observed_size INTEGER NOT NULL, observed_mtime_ms INTEGER NOT NULL, offset INTEGER NOT NULL, pending TEXT NOT NULL, line_index INTEGER NOT NULL, external_id TEXT, project TEXT, ordinals INTEGER NOT NULL, rejected INTEGER NOT NULL)")
    }
    private func writeCursor(_ path: String, _ cursor: FileCursor) throws {
        try run("INSERT INTO capture_files(path, inode, parser_version, observed_size, observed_mtime_ms, offset, pending, line_index, external_id, project, ordinals, rejected, run_state) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET inode=excluded.inode, parser_version=excluded.parser_version, observed_size=excluded.observed_size, observed_mtime_ms=excluded.observed_mtime_ms, offset=excluded.offset, pending=excluded.pending, line_index=excluded.line_index, external_id=excluded.external_id, project=excluded.project, ordinals=excluded.ordinals, rejected=excluded.rejected, run_state=excluded.run_state", [path, cursor.inode, cursor.parserVersion, String(cursor.observedSize), String(cursor.observedMtimeMS), String(cursor.offset), cursor.pending, String(cursor.lineIndex), cursor.externalID, cursor.project, cursor.ordinals ? "1" : "0", cursor.rejected ? "1" : "0", cursor.runState])
    }
    private func insertMessages(_ session: Session, path: String) throws {
        let sql = "INSERT INTO messages(agent, external_id, message_id, source_path, role, content, timestamp, ordinal) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(agent, external_id, message_id) DO UPDATE SET source_path=excluded.source_path, role=excluded.role, content=excluded.content, timestamp=excluded.timestamp, ordinal=excluded.ordinal"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for message in session.messages {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            let values = [session.source.id.agent, session.source.id.externalID, message.id, path, message.role.rawValue, message.content]
            for (offset, value) in values.enumerated() {
                let result = value.withCString { sqlite3_bind_text(stmt, Int32(offset + 1), $0, Int32(value.utf8.count), transient) }
                if result != SQLITE_OK { throw error() }
            }
            let timestampResult = message.timestampMilliseconds.map { sqlite3_bind_text(stmt, 7, String($0), -1, transient) } ?? sqlite3_bind_null(stmt, 7)
            if timestampResult != SQLITE_OK || sqlite3_bind_text(stmt, 8, String(Self.ordinal(of: message.id)), -1, transient) != SQLITE_OK { throw error() }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
        }
    }
    private func titleCandidates(agent: String, externalID: String) throws -> [SessionMessage] {
        try rows("SELECT role, substr(content, 1, 200) FROM messages WHERE agent=? AND external_id=? ORDER BY ordinal, message_id LIMIT 80", [agent, externalID]).map {
            SessionMessage(id: "", role: SessionMessage.Role(rawValue: $0[0] ?? "") ?? .system, content: $0[1] ?? "", timestampMilliseconds: nil)
        }
    }
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let collapsed = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(100))
    }

    private static func displayTitle(_ messages: [SessionMessage], fallback: String) -> String {
        let title = messages.first { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.role == .user && !skippedTitlePrefixes.contains { text.hasPrefix($0) }
        }?.content ?? fallback
        return String(title.prefix(100))
    }
    private static func ordinal(of id: String) -> Int {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let major = Int(parts.first ?? "") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return major * 1000 + minor
    }
    private static func message(from row: [String?]) -> SessionMessage {
        SessionMessage(id: row[0] ?? "", role: SessionMessage.Role(rawValue: row[1] ?? "") ?? .system, content: row[2] ?? "", timestampMilliseconds: row[3].flatMap(Int64.init))
    }
    private func summary(from row: [String?]) throws -> SessionSummary {
        let externalID = row[1] ?? ""
        return SessionSummary(source: SessionSource(id: try SessionID(agent: row[0] ?? "", externalID: externalID), sourcePath: row[6] ?? ""), projectID: row[2], stableProjectID: row[7], title: row[3] ?? externalID, messageCount: Int(row[4] ?? "") ?? 0, lastActivity: Int64(row[5] ?? "") ?? 0, runState: row[8].flatMap(SessionRunState.init(rawValue:)))
    }
    private func userVersion() throws -> Int { Int(try text("PRAGMA user_version") ?? "") ?? 0 }
    private func columns(_ table: String) throws -> Set<String> { try Set(rows("PRAGMA table_info(\(table))").compactMap { $0[1] }) }
    private func count(_ sql: String, _ args: [String?]) throws -> Int { Int(try text(sql, args) ?? "") ?? 0 }
    private func text(_ sql: String, _ args: [String?] = []) throws -> String? { try rows(sql, args).first?.first ?? nil }
    private func statement(_ sql: String, _ args: [String?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in args.enumerated() {
            let result = value.map { text in text.withCString { sqlite3_bind_text(stmt, Int32(offset + 1), $0, Int32(text.utf8.count), transient) } } ?? sqlite3_bind_null(stmt, Int32(offset + 1))
            if result != SQLITE_OK { sqlite3_finalize(stmt); throw error() }
        }
        return stmt
    }
    private func run(_ sql: String, _ args: [String?] = []) throws {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW { result = sqlite3_step(stmt) }
        guard result == SQLITE_DONE else { throw error() }
    }
    private func rows(_ sql: String, _ args: [String?] = []) throws -> [[String?]] {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return out }
            guard result == SQLITE_ROW else { throw error() }
            out.append((0..<sqlite3_column_count(stmt)).map { column in
                sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, column).map { String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(stmt, column))), as: UTF8.self) }
            })
        }
    }
    private func error() -> CaptureError { .invalid(String(cString: sqlite3_errmsg(db))) }
}
