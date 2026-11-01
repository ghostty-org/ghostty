import AppKit
import Foundation
import GhosttyKit

/// A close request survives pane destruction and app exit. It is removed only
/// after the host confirms cleanup; a disconnected pane is never proof of exit.
struct SessionRuntimeCloseRequest: Codable, Equatable {
    let pane: UUID
    let descriptor: SessionRuntimeDescriptor
}

@MainActor
final class SessionRuntimeCloseQueue: ObservableObject {
    static let shared = SessionRuntimeCloseQueue(url: OMGApplicationEnvironment.isRunningTests ? nil :
        OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("session-runtime/pending-closes.json"))
    private let url: URL?
    @Published private(set) var requests: [SessionRuntimeCloseRequest] = []
    private var loadError: Error?
    private var timer: Timer?
    private var running = false
    private var stopped = false

    init(url: URL?) {
        self.url = url
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                requests = try JSONDecoder().decode([SessionRuntimeCloseRequest].self, from: Data(contentsOf: url))
            }
        } catch { loadError = error }
    }

    private func save(_ value: [SessionRuntimeCloseRequest]) throws {
        guard let url else {
            requests = value
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        requests = value
    }

    func enqueue(_ additions: [SessionRuntimeCloseRequest]) throws {
        if let loadError { throw loadError }
        var next = requests
        for request in additions where !next.contains(request) { next.append(request) }
        try save(next)
    }

    func acknowledge(_ request: SessionRuntimeCloseRequest) throws {
        try save(requests.filter { $0 != request })
    }

    func start() {
        guard url != nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in SessionRuntimeCloseQueue.shared.retry() }
        }
        retry()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    func retry() {
        guard url != nil, !stopped, !running, !requests.isEmpty else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            for request in requests {
                guard !stopped else { break }
                do {
                    let socket = try SessionRuntimeConnections.shared.prepare(request.descriptor, interactive: false)
                    let helper = SessionRuntimeConnections.resources.appendingPathComponent("omgd")
                    let success = await Task.detached {
                        let process = Process()
                        process.executableURL = helper
                        process.arguments = ["close-local", socket.path, request.pane.uuidString.lowercased()]
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        do {
                            try process.run()
                            process.waitUntilExit()
                            return process.terminationStatus == 0
                        } catch { return false }
                    }.value
                    if success { try acknowledge(request) }
                } catch {
                    // Keep durable intent. A later retry/startup can authenticate
                    // using the normal connection path without silently dropping it.
                }
            }
        }
    }
}

enum SessionRuntimeClose {
    @MainActor
    static func close(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> Bool {
        let requests = node.leaves().compactMap { view in
            view.runtimeDescriptor.map { SessionRuntimeCloseRequest(pane: view.id, descriptor: $0) }
        }
        guard !requests.isEmpty else { return true }
        do {
            try SessionRuntimeCloseQueue.shared.enqueue(requests)
            // Compatibility: older pinned hosts understand only the existing
            // attached Close frame. Keep intent pending until a host can confirm.
            for view in node.leaves() where view.runtimeDescriptor != nil {
                if let surface = view.surface { ghostty_surface_close_session(surface) }
            }
            SessionRuntimeCloseQueue.shared.start()
            SessionRuntimeCloseQueue.shared.retry()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
