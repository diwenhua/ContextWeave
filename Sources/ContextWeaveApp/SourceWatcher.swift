import Foundation
import CoreServices

/// Coalesces recursive filesystem events under the session roots.
final class SourceWatcher: @unchecked Sendable {
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "contextweave.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var pendingPaths: [String] = []
    private var stopped = false
    private(set) var isActive = false

    init(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        let existing = Array(Set(paths.filter { FileManager.default.fileExists(atPath: $0) }))
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let values = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue().schedule(values)
        }, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        isActive = FSEventStreamStart(stream)
    }

    func stop() {
        lock.lock()
        stopped = true
        pending?.cancel()
        pending = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func schedule(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return }
        pendingPaths.append(contentsOf: paths)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let paths = self.pendingPaths
            self.pendingPaths = []
            self.lock.unlock()
            guard !paths.isEmpty else { return }
            self.onChange(paths)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit { stop() }
}
