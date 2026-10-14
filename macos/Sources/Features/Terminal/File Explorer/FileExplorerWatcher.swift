import CoreServices
import Foundation

/// Watches a directory tree with FSEvents and reports the directories in which something
/// changed. Events are delivered on the main queue.
final class FileExplorerWatcher {
    /// Called with the paths (without a trailing slash) of the directories that changed.
    private let onChange: ([String]) -> Void

    private var stream: FSEventStreamRef?

    /// The path being watched, if any.
    private(set) var path: String?

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Starts watching the given directory tree, replacing any previous one.
    func start(path: String) {
        guard path != self.path || stream == nil else { return }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileExplorerWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(Array(paths.prefix(count)).map { path in
                path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            })
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        self.stream = stream
        self.path = path
    }

    /// Stops watching.
    func stop() {
        path = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
