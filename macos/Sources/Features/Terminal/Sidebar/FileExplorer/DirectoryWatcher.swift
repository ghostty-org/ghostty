import Foundation

/// Watches a changing set of directories and reports which ones changed,
/// coalesced.
///
/// Modelled on `TabStateCenter`'s single-directory watch, with two
/// differences that matter here: the watched set changes constantly as the
/// user expands and collapses folders, so descriptors have to be released
/// as carefully as they're taken; and a directory being written to (a build
/// running, a `git checkout`) fires a burst of events, so they're debounced
/// instead of triggering a rescan each.
///
/// Only *expanded* directories are watched — the set is bounded by what's
/// actually on screen, which is why this can use one descriptor per
/// directory instead of reaching for FSEvents.
@MainActor
final class DirectoryWatcher {
    /// Called with the paths that changed since the last flush.
    var onChange: (Set<String>) -> Void = { _ in }

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Set<String> = []
    private var flushTask: Task<Void, Never>?

    /// Long enough to swallow the burst from a checkout or an install,
    /// short enough that saving a file feels immediate.
    private static let debounce = Duration.milliseconds(250)

    deinit {
        for source in sources.values { source.cancel() }
    }

    /// Makes the watched set exactly `paths`, adding and releasing
    /// descriptors as needed.
    func watch(_ paths: Set<String>) {
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources.removeValue(forKey: path)
        }

        for path in paths where sources[path] == nil {
            guard let source = makeSource(for: path) else { continue }
            sources[path] = source
        }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    private func makeSource(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.note(path) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func note(_ path: String) {
        pending.insert(path)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let changed = self.pending
            self.pending.removeAll()
            self.flushTask = nil
            guard !changed.isEmpty else { return }
            self.onChange(changed)
        }
    }
}
