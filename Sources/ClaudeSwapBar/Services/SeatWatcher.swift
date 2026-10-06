import CoreServices
import Foundation

/// Watches the folders `cseat` and Claude Code write to, so the menu follows
/// `cseat use`, logins, new accounts and starting or ending sessions within
/// a second instead of on the next timer tick.
final class SeatWatcher {
    enum Change {
        /// Only session records changed: cheap to pick up.
        case sessions
        /// Usage numbers fetched by `cseat`.
        case usage
        /// Default account, accounts or logins changed.
        case seats
    }

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let seatsRoot: String
    private let usagePath: String
    private let onChange: (Set<Change>) -> Void
    private var pending = Set<Change>()
    private var flushScheduled = false

    init(seatsRoot: URL, paths: [URL], usageFile: URL, onChange: @escaping (Set<Change>) -> Void) {
        self.seatsRoot = seatsRoot.path
        self.paths = [seatsRoot.path] + paths.map(\.path)
        self.usagePath = usageFile.path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        stop()
        // FSEvents only watches folders that exist.
        for path in paths {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SeatWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            watcher.record(paths.prefix(count))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Seat folders also hold prompt history, caches and debug logs that
    /// change constantly; only the files the menu shows count.
    private func classify(_ path: String) -> Change? {
        if path == usagePath { return .usage }
        if path.contains("/sessions/") || path.hasSuffix("/sessions") { return .sessions }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        if parent == seatsRoot, !name.hasPrefix(".") || name == ".default" { return .seats }
        if name == ".claude.json" || name == ".credentials.json" { return .seats }
        return nil
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func record<S: Sequence>(_ paths: S) where S.Element == String {
        for path in paths {
            if let change = classify(path) { pending.insert(change) }
        }
        // Claude Code rewrites session records on every status change;
        // collect a burst into one update.
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let changes = self.pending
            self.pending.removeAll()
            self.flushScheduled = false
            self.onChange(changes)
        }
    }
}
