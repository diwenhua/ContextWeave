import Foundation
import CSQLite
import CryptoKit

/// Cursor's local composer storage is an undocumented format. Read one consistent SQLite
/// snapshot, never mutate it, and only associate conversations with a verified local workspace.
enum CursorCapture {
    static let version = "cursor-composer-v3"
    enum Error: Swift.Error { case unavailable; case invalid(String) }
    struct Snapshot: Sendable {
        let cursorPath: String
        let fingerprint: String
        let session: Session
    }
    struct Result {
        var snapshots: [Snapshot] = []
        var incompleteSessions = 0
    }

    static func read(userRoot: URL, onSnapshot: ((Snapshot) -> Void)? = nil) throws -> Result {
        let database = userRoot.appendingPathComponent("globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { throw Error.unavailable }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw Error.invalid("Unable to open Cursor's database")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw Error.invalid("Unable to read Cursor snapshot") }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let workspaces = workspacePaths(userRoot: userRoot)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT composerId, workspaceId, value FROM composerHeaders WHERE COALESCE(isSubagent, 0)=0", -1, &query, nil) == SQLITE_OK, let query else {
            throw Error.invalid("Unsupported Cursor database schema (composerHeaders)")
        }
        defer { sqlite3_finalize(query) }
        var get: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM cursorDiskKV WHERE key=?", -1, &get, nil) == SQLITE_OK, let get else { throw Error.invalid("Unsupported Cursor database schema (cursorDiskKV)") }
        defer { sqlite3_finalize(get) }
        func value(_ key: String) throws -> Data? {
            sqlite3_reset(get); sqlite3_clear_bindings(get)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(get, 1, key, -1, transient) == SQLITE_OK else { throw Error.invalid("Cursor database bind failed") }
            let result = sqlite3_step(get)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(get, 0) else { throw Error.invalid("Cursor database read failed") }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(get, 0)))
        }
        var output = Result()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Error.invalid("Cursor header read failed") }
            guard let idPtr = sqlite3_column_text(query, 0), let workspacePtr = sqlite3_column_text(query, 1) else { continue }
            let id = String(cString: idPtr), workspaceID = String(cString: workspacePtr)
            let headerData: Data = sqlite3_column_blob(query, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(query, 2))) } ?? Data()
            let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] ?? [:]
            let identifier = header["workspaceIdentifier"] as? [String: Any]
            let uri = identifier?["uri"] as? [String: Any]
            let uriPath = uri?["scheme"] as? String == "file" ? (uri?["fsPath"] as? String ?? uri?["path"] as? String) : nil
            guard let rawPath = workspaces[workspaceID] ?? uriPath, rawPath.hasPrefix("/"), let project = try? ProjectIdentity.canonicalPath(rawPath),
                  let composerData = try value("composerData:" + id),
                  let composer = try? JSONSerialization.jsonObject(with: composerData) as? [String: Any] else { continue }
            var hasher = SHA256(); hasher.update(data: headerData); hasher.update(data: composerData)
            var headers = composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
            if let log = composer["headerLog"] as? [String: Any], let count = log["chunkCount"] as? Int, count > 0 {
                guard count <= 100_000 else { throw Error.invalid("Cursor header chunk count is invalid") }
                headers = []
                var completeHeaders = true
                for index in 0..<count {
                    guard let data = try value("composerConvHeaders:\(id):" + String(format: "%06d", index)),
                          let chunk = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        completeHeaders = false; break
                    }
                    hasher.update(data: data); headers.append(contentsOf: chunk)
                }
                if !completeHeaders || (log["count"] as? Int).map({ headers.count != $0 }) == true {
                    output.incompleteSessions += 1; continue
                }
            }
            guard !headers.isEmpty else { continue }
            var messages: [SessionMessage] = []
            var awaitingApproval = header["hasBlockingPendingActions"] as? Bool == true
            var complete = true
            for (index, reference) in headers.enumerated() {
                guard let bubbleID = reference["bubbleId"] as? String,
                      let data = try value("bubbleId:\(id):\(bubbleID)"),
                      let bubble = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { complete = false; break }
                hasher.update(data: data)
                let role: SessionMessage.Role = (bubble["type"] as? Int ?? reference["type"] as? Int) == 1 ? .user : .assistant
                let timestamp = time(bubble["createdAt"] ?? reference["createdAt"]) ?? time(composer["lastUpdatedAt"] ?? composer["createdAt"])
                if let text = bubble["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(SessionMessage(id: "\(index):0", role: role, content: text, timestampMilliseconds: timestamp))
                }
                if let tool = bubble["toolFormerData"] as? [String: Any] {
                    if Self.needsApproval(tool) { awaitingApproval = true }
                    var parts: [String] = []
                    if let name = tool["name"] as? String { parts.append("Tool: \(name)") }
                    if let args = tool["rawArgs"] as? String, !args.isEmpty { parts.append("Arguments: \(args)") }
                    if let result = tool["result"], let text = render(result), !text.isEmpty { parts.append("Result: \(text)") }
                    if !parts.isEmpty { messages.append(SessionMessage(id: "\(index):1", role: .tool, content: parts.joined(separator: "\n"), timestampMilliseconds: timestamp)) }
                }
            }
            guard complete else { output.incompleteSessions += 1; continue }
            guard !messages.isEmpty else { continue }
            let source = SessionSource(id: try SessionID(agent: "cursor", externalID: id), sourcePath: database.path)
            let session = Session(source: source, projectID: project, messages: messages, runState: runState(composer, awaitingApproval: awaitingApproval), agentTitle: conversationName(header: header, composer: composer))
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let snapshot = Snapshot(cursorPath: database.path + "#composer:" + id, fingerprint: fingerprint, session: session)
            if let onSnapshot { onSnapshot(snapshot) } else { output.snapshots.append(snapshot) }
        }
        return output
    }

    private static func workspacePaths(userRoot: URL) -> [String: String] {
        let root = userRoot.appendingPathComponent("workspaceStorage")
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: String] = [:]
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("workspace.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = object["folder"] as? String, let url = URL(string: folder), url.isFileURL else { continue }
            result[directory.lastPathComponent] = url.path
        }
        return result
    }
    private static func conversationName(header: [String: Any], composer: [String: Any]) -> String? {
        for value in [header["name"], composer["name"]] {
            guard let text = value as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func needsApproval(_ tool: [String: Any]) -> Bool {
        if tool["status"] as? String == "needs_user_approval" { return true }
        let extra = tool["additionalData"] as? [String: Any]
        return extra?["status"] as? String == "needs_user_approval"
    }

    /// A tool waiting on the user takes precedence over a still-open generation. A finished turn does not.
    ///
    /// Cursor can persist `status = "aborted"` while a resumed/continued run is still writing checkpoints.
    /// In that state `unfinishedRunAt` is set and `conversationCheckpointLastUpdatedAt` moves forward. Treat
    /// that recent activity as running instead of reporting the run as ended.
    static func runState(_ composer: [String: Any], awaitingApproval: Bool, now: Date = Date()) -> SessionRunState? {
        let status = composer["status"] as? String
        let generating = composer["generatingBubbleIds"] as? [Any]
        let active = status == "generating"
            || generating?.isEmpty == false
            || unfinishedRunIsActive(composer, now: now)

        if status == "completed" { return .finished }
        if awaitingApproval, status != "aborted" || active { return .awaitingApproval }
        if active { return .running }
        switch status {
        case "aborted", "cancelled", "canceled": return .aborted
        default: return nil
        }
    }

    private static func unfinishedRunIsActive(_ composer: [String: Any], now: Date) -> Bool {
        guard let unfinished = time(composer["unfinishedRunAt"]) else { return false }
        let checkpoint = time(composer["conversationCheckpointLastUpdatedAt"])
        let lastUpdated = time(composer["lastUpdatedAt"])
        let activity = max(checkpoint ?? 0, lastUpdated ?? 0)
        guard activity > unfinished else { return false }
        let age = Int64(now.timeIntervalSince1970 * 1000) - activity
        return age >= 0 && age <= 120_000
    }

    private static func time(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    private static func render(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
