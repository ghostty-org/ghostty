import Foundation
import Combine

/// Detects dev servers running in terminal tabs and exposes the port they
/// listen on, keyed by the surface's foreground process group.
///
/// Detection is by listening socket rather than by matching startup banners:
/// the port is then found the same way whatever the runtime is (node, go,
/// java, a plain `python -m http.server`), including the ones that print
/// nothing parseable. The process that owns the socket is usually several
/// levels below the shell's foreground job — `pnpm` spawns `nx`, which
/// spawns `vite` — so the search walks the process tree rather than looking
/// only at the job itself.
@MainActor
final class DevServerCenter: ObservableObject {
    static let shared = DevServerCenter()

    struct ServerInfo: Equatable {
        var port: Int?
        var checkedAt: Date = .distantPast
    }

    @Published private(set) var servers: [Int: ServerInfo] = [:]

    /// The foreground PIDs the sidebar is currently showing. One scan
    /// resolves all of them, so cost doesn't grow with the tab count.
    private var tracked: Set<Int> = []
    private var isScanning = false
    private var scannedAt: Date = .distantPast

    private static let ttl: TimeInterval = 4

    /// `lsof` lives outside the default PATH lookup this uses, and is
    /// always at this path on macOS.
    private static let lsofPath = "/usr/sbin/lsof"
    private static let psPath = "/bin/ps"

    func port(forPID pid: Int?) -> Int? {
        pid.flatMap { servers[$0] }?.port
    }

    /// Tracks a surface's foreground PID and refreshes the whole tracked
    /// set when the last scan went stale. Cheap no-op while fresh.
    func requestRefresh(pid: Int) {
        tracked.insert(pid)

        guard !isScanning,
              Date().timeIntervalSince(scannedAt) > Self.ttl
        else { return }

        isScanning = true
        let pids = tracked

        Task.detached(priority: .utility) {
            let listeners = Self.listeningPorts()
            let parents = Self.parentPIDs()

            await MainActor.run { [weak self] in
                guard let self else { return }
                let resolved = Self.resolve(
                    tracked: pids,
                    listeners: listeners,
                    parents: parents
                )

                let now = Date()
                for pid in pids {
                    self.servers[pid] = ServerInfo(port: resolved[pid], checkedAt: now)
                }
                // Drop tabs that went away between scans.
                self.servers = self.servers.filter { self.tracked.contains($0.key) }
                self.scannedAt = now
                self.isScanning = false
            }
        }
    }

    /// Walks up from each listening process until it reaches a tracked PID,
    /// which attributes the socket to the tab that started it.
    ///
    /// Going up from the (few) listeners is much less work than computing
    /// the descendants of every tracked PID.
    nonisolated static func resolve(
        tracked: Set<Int>,
        listeners: [Int: [Int]],
        parents: [Int: Int]
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]

        for (listenerPID, ports) in listeners {
            guard let port = ports.min() else { continue }

            var current = listenerPID
            var hops = 0
            while current > 1, hops < 64 {
                if tracked.contains(current) {
                    // The lowest port is the server itself; anything higher
                    // in the same tree tends to be an HMR/debug side channel.
                    result[current] = min(result[current] ?? port, port)
                    break
                }
                guard let parent = parents[current] else { break }
                current = parent
                hops += 1
            }
        }

        return result
    }

    /// Every process listening on TCP, as pid -> ports.
    nonisolated private static func listeningPorts() -> [Int: [Int]] {
        guard let output = ShellCommand.run(
            lsofPath,
            ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: 5
        ) else { return [:] }

        var result: [Int: [Int]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2,
                  let pid = Int(columns[1]),
                  let port = port(inColumns: columns)
            else { continue }
            result[pid, default: []].append(port)
        }
        return result
    }

    /// Pulls the port out of an lsof row.
    ///
    /// The address sits in the NAME column, which is neither first nor last
    /// (`… TCP 127.0.0.1:3000 (LISTEN)`) and varies in width, so the row is
    /// scanned from the right for the first `host:port` shaped column —
    /// matching `*:3000`, `127.0.0.1:3000` and `[::1]:3000` alike.
    nonisolated static func port(inColumns columns: [Substring]) -> Int? {
        for column in columns.reversed() {
            guard let colon = column.lastIndex(of: ":") else { continue }
            if let port = Int(column[column.index(after: colon)...]) {
                return port
            }
        }
        return nil
    }

    /// The whole process table as pid -> ppid.
    ///
    /// `-e` would override `-p`, so the table is fetched unscoped and
    /// walked in memory.
    nonisolated private static func parentPIDs() -> [Int: Int] {
        guard let output = ShellCommand.run(
            psPath,
            ["-ax", "-o", "pid=,ppid="],
            timeout: 5
        ) else { return [:] }

        var result: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2,
                  let pid = Int(columns[0]),
                  let ppid = Int(columns[1])
            else { continue }
            result[pid] = ppid
        }
        return result
    }
}
