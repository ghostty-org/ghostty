import Foundation

/// Watches a directory via `DispatchSourceFileSystemObject` (vnode events on the
/// directory fd) and fires a debounced callback when contents change.
///
/// The callback coalesces bursts of filesystem activity (e.g. a bulk rewrite
/// touching several fixtures) into one reload ~150 ms after the last event.
///
/// If the watched directory itself is deleted, the watcher cancels the source
/// and periodically retries until the directory reappears, so a one-shot
/// `rm -rf .ghostties/tasks && mkdir -p .ghostties/tasks` doesn't permanently
/// break the watch.
///
/// The `onChange` closure is always invoked on the main queue so callers can
/// mutate `@MainActor` state without hopping themselves.
final class TaskFileWatcher {
    private let url: URL
    private let debounceInterval: DispatchTimeInterval
    private let onChange: () -> Void

    private let queue = DispatchQueue(label: "com.ghostties.taskfilewatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pendingReload: DispatchWorkItem?
    private var retryItem: DispatchWorkItem?
    private var isRunning = false

    /// - Parameters:
    ///   - url: Directory to watch.
    ///   - debounceInterval: How long to wait after the last event before
    ///     firing `onChange`. Defaults to 150 ms.
    ///   - onChange: Invoked on the main queue after a debounced change event.
    init(url: URL,
         debounceInterval: DispatchTimeInterval = .milliseconds(150),
         onChange: @escaping () -> Void) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stopInternal()
    }

    func start() {
        queue.async { [weak self] in self?.openAndWatch() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopInternal() }
    }

    // MARK: - Private

    private func openAndWatch() {
        guard !isRunning else { return }

        let path = url.path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            #if DEBUG
            print("[TaskFileWatcher] Failed to open \(path); scheduling retry")
            #endif
            scheduleRetry()
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self = self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Directory gone (or moved). Tear down and retry until it reappears.
                self.stopInternal()
                self.scheduleRetry()
                return
            }
            self.scheduleDebouncedFire()
        }

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }

        self.fd = descriptor
        self.source = src
        self.isRunning = true
        src.resume()

        // Always fire once on (re)attach so callers see current state after a
        // recreate cycle, not just incremental diffs.
        scheduleDebouncedFire()
    }

    private func scheduleDebouncedFire() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let callback = self.onChange
            DispatchQueue.main.async { callback() }
        }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func scheduleRetry() {
        retryItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.openAndWatch() }
        retryItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func stopInternal() {
        pendingReload?.cancel()
        pendingReload = nil
        retryItem?.cancel()
        retryItem = nil
        if let src = source {
            src.cancel()
            source = nil
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
        isRunning = false
    }
}
