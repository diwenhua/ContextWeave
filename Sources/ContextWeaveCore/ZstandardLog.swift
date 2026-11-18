import Foundation
import Darwin

/// DSH appends independent zstd frames. Only complete frames are passed to the decoder.
public enum ZstandardLog {
    public static func completePrefix(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var position = 0
        while position < bytes.count {
            let start = position
            guard bytes.count - position >= 5 else { break }
            guard Array(bytes[position..<position + 4]) == [0x28, 0xb5, 0x2f, 0xfd] else { throw CaptureError.invalid("Invalid Zstandard frame at byte \(position)") }
            let descriptor = Int(bytes[position + 4])
            guard descriptor & 0x18 == 0 else { throw CaptureError.invalid("Unsupported Zstandard frame header") }
            let single = descriptor & 0x20 != 0
            let sizeFlag = descriptor >> 6
            let sizeBytes = sizeFlag == 0 ? (single ? 1 : 0) : [0, 2, 4, 8][sizeFlag]
            position += 5 + (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + sizeBytes
            if position > bytes.count { position = start; break }
            var complete = false
            while bytes.count - position >= 3 {
                let block = Int(bytes[position]) | Int(bytes[position + 1]) << 8 | Int(bytes[position + 2]) << 16
                position += 3
                let kind = (block >> 1) & 3
                guard kind != 3 else { throw CaptureError.invalid("Invalid Zstandard block") }
                position += kind == 1 ? 1 : block >> 3
                if position > bytes.count { break }
                if block & 1 == 1 { complete = true; break }
            }
            if descriptor & 4 != 0 { position += 4 }
            if !complete || position > bytes.count { position = start; break }
        }
        guard position > 0 || bytes.isEmpty else { throw CaptureError.invalid("No complete Zstandard frame yet") }
        return data.prefix(position)
    }

    /// Decodes only complete frames. An incomplete trailing frame returns an empty prefix instead of failing.
    public static func decodeCompleteFrames(_ data: Data) throws -> (text: String, bytes: Int) {
        if data.isEmpty { return ("", 0) }
        let prefix: Data
        do { prefix = try completePrefix(data) } catch let error as CaptureError {
            if case let .invalid(message) = error, message.hasPrefix("No complete Zstandard frame") { return ("", 0) }
            throw error
        }
        if prefix.isEmpty { return ("", 0) }
        return (try decodeFrames(prefix), prefix.count)
    }

    public static func decode(_ data: Data) throws -> String {
        let (text, bytes) = try decodeCompleteFrames(data)
        guard bytes > 0 else { throw CaptureError.invalid("No complete Zstandard frame yet") }
        return text
    }

    private static func decodeFrames(_ prefix: Data) throws -> String {
        let candidates = [ProcessInfo.processInfo.environment["CONTEXTWEAVE_ZSTD"], "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CaptureError.invalid("DeepSeek Harness compressed logs require zstd. Install with brew install zstd, or set CONTEXTWEAVE_ZSTD.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("session.zstd")
        try prefix.write(to: input)
        let output = directory.appendingPathComponent("decoded.jsonl")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.invalid("Cannot create temporary Zstandard output")
        }
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-q", "-d", "-c", input.path]
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let configured = ProcessInfo.processInfo.environment["CONTEXTWEAVE_ZSTD_TIMEOUT_SECONDS"].flatMap(Int.init) ?? 30
        let timeout = min(max(configured, 1), 120)
        if finished.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            // The child cannot be allowed to occupy a scan indefinitely. Use the process
            // identifier only while Foundation still considers this exact child running.
            if process.isRunning { kill(process.processIdentifier, SIGTERM) }
            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw CaptureError.invalid("Zstandard decoder timed out")
        }
        process.waitUntilExit()
        let decoded = try Data(contentsOf: output)
        guard process.terminationStatus == 0, let text = String(data: decoded, encoding: .utf8) else { throw CaptureError.invalid("Zstandard decoding failed") }
        return text
    }
}
