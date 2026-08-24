import CoreServices
import Dispatch
import Foundation

/// Thin, `Sendable` wrapper around a file-level FSEvents stream (DS-4).
///
/// File-level events with a 0.5 s latency: the kernel coalesces bursts for us,
/// so an editor that writes a file three times in a second wakes the reconciler
/// once. `kFSEventStreamCreateFlagWatchRoot` keeps the stream alive if the notes
/// folder itself is renamed or moved (NFR-5).
final class FSEventsMonitor: @unchecked Sendable {
    /// Absolute paths reported by the last batch, plus whether FSEvents asked
    /// for a full rescan (event coalescing overflow, or the root itself moved).
    typealias Handler = @Sendable (_ paths: [String], _ needsFullScan: Bool) -> Void

    private let root: URL
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.tejaspanse.filaway.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(root: URL, latency: TimeInterval, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { stream != nil }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return false
        }
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(paths: [String], needsFullScan: Bool) {
        handler(paths, needsFullScan)
    }
}

private let eventCallback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
    guard let info else { return }
    let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []

    var needsFullScan = false
    let rescanFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )
    for index in 0 ..< count where rawFlags[index] & rescanFlags != 0 {
        needsFullScan = true
    }
    monitor.deliver(paths: paths, needsFullScan: needsFullScan)
}
