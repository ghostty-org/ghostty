import AppKit
import Combine
import Foundation
import UserNotifications

/// Externally-reported state of the agent running in a tab.
enum AgentTabState: String {
    /// The agent is processing (spinner).
    case working

    /// The agent is waiting for user input.
    case awaiting

    /// The agent finished and produced output (attention until the tab
    /// is selected).
    case done

    /// The agent session ended cleanly; shows nothing, but the file's
    /// presence tells session restore not to resume it.
    case ended
}

/// Watches the tab-state directory that terminal-side tools write into.
///
/// Each surface exports `GHOSTTY_TAB_STATE_FILE` pointing at a file named
/// after its UUID inside this directory. External hooks (e.g. Claude Code
/// hooks) write `working` / `awaiting` / `done` into that file atomically
/// (write to a temp name, then `mv`), and the sidebar reflects it live.
@MainActor
final class TabStateCenter: ObservableObject {
    static let shared = TabStateCenter()

    @Published private(set) var states: [UUID: AgentTabState] = [:]

    static let stateDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("tab-states", isDirectory: true)

    static func stateFileURL(for surfaceId: UUID) -> URL {
        stateDir.appendingPathComponent(surfaceId.uuidString)
    }

    /// State files older than this are stale leftovers from closed tabs.
    private static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    private var source: DispatchSourceFileSystemObject?

    init() {
        try? FileManager.default.createDirectory(
            at: Self.stateDir,
            withIntermediateDirectories: true
        )
        pruneStale()
        watch()
        refresh()
    }

    deinit {
        source?.cancel()
    }

    private func watch() {
        let fd = open(Self.stateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func refresh() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Self.stateDir,
            includingPropertiesForKeys: nil
        )) ?? []

        var result: [UUID: AgentTabState] = [:]
        for url in entries {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let raw = try? String(contentsOf: url, encoding: .utf8),
                  let state = AgentTabState(
                    rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)
                  )
            else { continue }
            if state == .ended { continue }
            result[id] = state
        }

        notifyTransitions(from: states, to: result)
        if result != states { states = result }
    }

    /// Clears a `done` marker once its tab has been seen (selected).
    func clearDone(surfaceId: UUID) {
        guard states[surfaceId] == .done else { return }
        try? FileManager.default.removeItem(at: Self.stateFileURL(for: surfaceId))
        states.removeValue(forKey: surfaceId)
    }

    /// Posts a system notification when an unfocused tab's agent needs
    /// input or finishes, mirroring the in-sidebar indicators.
    private func notifyTransitions(
        from old: [UUID: AgentTabState],
        to new: [UUID: AgentTabState]
    ) {
        let enabled = UserDefaults.standard.object(
            forKey: "AgentNotificationsEnabled"
        ) as? Bool ?? true
        guard enabled else { return }

        for (id, state) in new {
            guard old[id] != state else { continue }

            let message: String
            switch state {
            case .done: message = "Task complete"
            case .awaiting: message = "Waiting for your input"
            default: continue
            }

            let info = tabInfo(for: id)
            if NSApp.isActive, info?.isSelected == true { continue }
            deliver(message: message, tabTitle: info?.title)
        }
    }

    private func tabInfo(for surfaceId: UUID) -> (title: String, isSelected: Bool)? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController,
                  let model = controller.sidebarTabManager?.models
                    .first(where: { $0.surfaceId == surfaceId })
            else { continue }
            return (model.title, model.isSelected)
        }
        return nil
    }

    private var didRequestNotificationAuth = false

    private func deliver(message: String, tabTitle: String?) {
        let center = UNUserNotificationCenter.current()

        let fire = {
            let content = UNMutableNotificationContent()
            content.title = "Claude Code"
            if let tabTitle, !tabTitle.isEmpty {
                content.body = "\(message) \u{2014} \(tabTitle)"
            } else {
                content.body = message
            }
            content.sound = nil
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }

        if didRequestNotificationAuth {
            fire()
        } else {
            didRequestNotificationAuth = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                if granted { DispatchQueue.main.async { fire() } }
            }
        }
    }

    private func pruneStale() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: Self.stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        for url in entries {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
