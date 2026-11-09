import Foundation
import Darwin

/// Stable, opaque identifiers are generated locally and never derived from paths or names.
public struct ProjectRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let createdAtMilliseconds: Int64
}

public struct WorkspaceBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let deviceID: String
    public let path: String
}

/// This file identifies an installation/device, not the database. Do not sync or back it up
/// alongside the shared logical data when provisioning another device.
enum LocalDeviceIdentity {
    static func loadOrCreate(in directory: URL) throws -> String {
        let file = directory.appendingPathComponent(".contextweave-device-id")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.invalid("Cannot open local device identity: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CaptureError.invalid("Cannot lock local device identity") }
        defer { flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        if !bytes.isEmpty {
            guard let value = String(data: bytes, encoding: .utf8), let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CaptureError.invalid("Local device identity is invalid; refusing to replace it.")
            }
            return uuid.uuidString
        }
        let value = UUID().uuidString
        try handle.write(contentsOf: Data(value.utf8))
        try handle.synchronize()
        return value
    }
}
