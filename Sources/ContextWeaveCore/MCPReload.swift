import Darwin
import Foundation

/// Identity of the MCP executable. In-place copies keep the inode, so size and modification time are included.
public struct ExecutableStamp: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modifiedNanoseconds: Int64

    public static func capture(_ path: String) -> ExecutableStamp? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return ExecutableStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(info.st_size), modifiedNanoseconds: modified)
    }
}

public enum MCPReload {
    public static let environmentKey = "CONTEXTWEAVE_MCP_RELOADED"
    public static let toolsChangedNotification = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)

    /// A missing file is a replacement in progress, not a request to exit.
    public static func shouldReload(started: ExecutableStamp, current: ExecutableStamp?, retryAfter: Date? = nil, now: Date = Date()) -> Bool {
        guard let current, current != started else { return false }
        if let retryAfter, now < retryAfter { return false }
        return true
    }
}
