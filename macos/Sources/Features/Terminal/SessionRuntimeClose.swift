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
    private var activeCloseProcess: Process?

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
        let staging = url.deletingLastPathComponent().appendingPathComponent(".pending-close-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SessionRuntimeBridgeStorage.writePrivateFile(at: staging, data: JSONEncoder().encode(value), permissions: 0o600)
        guard rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
        if let process = activeCloseProcess, process.isRunning { process.terminate() }
    }

    private func launchClose(_ request: SessionRuntimeCloseRequest, socket prepared: URL? = nil) throws -> Process {
        let socket = try prepared ?? SessionRuntimeConnections.shared.prepare(request.descriptor, interactive: false)
        let process = Process()
        process.executableURL = SessionRuntimeConnections.resources.appendingPathComponent("omgd")
        process.arguments = ["close-local", socket.path, request.pane.uuidString.lowercased()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Persist before calling. Every request is sent independently so one
    /// unreachable host cannot hold up cleanup on the other hosts.
    func finishForQuit(
        sockets: [UUID: URL] = [:],
        timeout: Duration = .seconds(2),
        launch: ((SessionRuntimeCloseRequest) throws -> Process)? = nil
    ) async {
        guard !requests.isEmpty else { return }
        stop()
        // End remote viewers before their local carriers. Password-authenticated
        // inline sessions can use the already authenticated relay socket.
        for local in [false, true] {
            await finishForQuit(requests.filter { $0.descriptor.isLocal == local },
                                sockets: sockets, timeout: timeout, launch: launch)
        }
    }

    private func finishForQuit(
        _ requests: [SessionRuntimeCloseRequest],
        sockets: [UUID: URL],
        timeout: Duration,
        launch: ((SessionRuntimeCloseRequest) throws -> Process)?
    ) async {
        var pending: [(SessionRuntimeCloseRequest, URL?)] = []
        for request in requests {
            if launch != nil {
                pending.append((request, nil))
            } else if let socket = sockets[request.pane], FileManager.default.fileExists(atPath: socket.path) {
                pending.append((request, socket))
            } else if let socket = try? SessionRuntimeConnections.shared.prepare(request.descriptor, interactive: false) {
                pending.append((request, socket))
            }
        }
        var helpers: [(SessionRuntimeCloseRequest, Process)] = []
        var prepared: [UUID: URL] = [:]
        for (request, socket) in pending { prepared[request.pane] = socket }
        var attempts: [UUID: Int] = [:]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !pending.isEmpty || !helpers.isEmpty {
            for (request, socket) in pending {
                guard helpers.count < 16 else { break }
                guard launch != nil || socket.map({ FileManager.default.fileExists(atPath: $0.path) }) == true else { continue }
                if let process = try? (launch.map { try $0(request) } ?? launchClose(request, socket: socket)) {
                    helpers.append((request, process))
                    attempts[request.pane, default: 0] += 1
                }
                pending.removeAll { $0.0 == request }
            }
            var waiting: [(SessionRuntimeCloseRequest, Process)] = []
            for (request, process) in helpers {
                if process.isRunning {
                    waiting.append((request, process))
                } else {
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        try? acknowledge(request)
                    } else if attempts[request.pane, default: 0] < 3 {
                        pending.append((request, prepared[request.pane]))
                    }
                }
            }
            helpers = waiting
            if pending.isEmpty && helpers.isEmpty || clock.now >= deadline { break }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        for (_, process) in helpers where process.isRunning {
            process.terminate()
        }
    }

    func retry() {
        guard url != nil, !stopped, !running, !requests.isEmpty else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            for request in requests {
                guard !stopped else { break }
                do {
                    let process = try launchClose(request)
                    activeCloseProcess = process
                    let success = await Task.detached {
                        process.waitUntilExit()
                        return process.terminationStatus == 0
                    }.value
                    activeCloseProcess = nil
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
        let requests = node.leaves().flatMap { view -> [SessionRuntimeCloseRequest] in
            var result = view.runtimeDescriptor.map { [SessionRuntimeCloseRequest(pane: view.id, descriptor: $0)] } ?? []
            if let inline = view.runtimeInlineSession {
                result.append(.init(pane: inline.pane, descriptor: inline.descriptor))
            }
            return result
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
