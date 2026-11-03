import AppKit
import GhosttyKit

struct SessionRuntimeQuitPolicy: Equatable {
    var keepLocal = true
    var keepSSH = true

    func keeps(_ descriptor: SessionRuntimeDescriptor) -> Bool {
        descriptor.isLocal ? keepLocal : keepSSH
    }

    func message(sessions: [SessionRuntimeQuitSession], ordinary: Bool, strings: SettingsStrings) -> String {
        var lines: [String] = []
        if sessions.contains(where: { $0.descriptor?.isLocal == true }) {
            lines.append(keepLocal
                ? strings.t("Local sessions will continue in the background.", "本地会话会在后台继续运行。")
                : strings.t("Local sessions will be ended.", "本地会话会被结束。"))
        }
        if sessions.contains(where: { $0.descriptor?.isLocal == false || $0.inline != nil }) {
            lines.append(keepSSH
                ? strings.t("SSH sessions will continue on their hosts.", "SSH 会话会在远端继续运行。")
                : strings.t("SSH session termination will be requested; unconfirmed closes are retained for retry.",
                            "退出时请求结束 SSH 会话；未确认的关闭请求会保留并重试。"))
        }
        if ordinary {
            lines.append(strings.t("Ordinary terminal processes will be terminated.", "普通终端进程将被终止。"))
        }
        return lines.joined(separator: "\n")
    }
}

struct SessionRuntimeQuitSession: Equatable {
    let pane: UUID
    let descriptor: SessionRuntimeDescriptor?
    let inline: SessionRuntimeInlineSession?
    let workingDirectory: String?

    @MainActor init(_ surface: Ghostty.SurfaceView) {
        pane = surface.id
        descriptor = surface.runtimeDescriptor
        inline = surface.runtimeInlineSession
        workingDirectory = surface.runtimeInlineSession?.descriptor.launchWorkingDirectory ?? surface.pwd
    }

    init(pane: UUID, descriptor: SessionRuntimeDescriptor?, inline: SessionRuntimeInlineSession? = nil,
         workingDirectory: String? = nil) {
        self.pane = pane
        self.descriptor = descriptor
        self.inline = inline
        self.workingDirectory = workingDirectory
    }
}

struct SessionRuntimeQuitReplacement {
    let pane: UUID
    let descriptor: SessionRuntimeDescriptor
    let create: Bool
}

struct SessionRuntimeQuitPlan {
    var requests: [SessionRuntimeCloseRequest] = []
    var replacements: [UUID: SessionRuntimeQuitReplacement] = [:]
    var sockets: [UUID: URL] = [:]
    var isEmpty: Bool { requests.isEmpty && replacements.isEmpty }

    init(sessions: [SessionRuntimeQuitSession], policy: SessionRuntimeQuitPolicy) {
        for session in sessions {
            let closesBackingSession = session.descriptor.map { !policy.keeps($0) } ?? false
            if let descriptor = session.descriptor, closesBackingSession {
                append(.init(pane: session.pane, descriptor: descriptor))
            }
            if let inline = session.inline, !policy.keepSSH {
                append(.init(pane: inline.pane, descriptor: inline.descriptor))
                sockets[inline.pane] = inline.socket
            }
            if let inline = session.inline, policy.keepSSH,
               closesBackingSession || session.descriptor == nil {
                // The local carrier is ending, but the remote PTY keeps its exact identity.
                replacements[session.pane] = .init(pane: inline.pane, descriptor: inline.descriptor, create: false)
            } else if var descriptor = session.descriptor, closesBackingSession {
                descriptor.initialWorkingDirectory = SessionRuntimeDescriptor.validWorkingDirectory(session.workingDirectory)
                replacements[session.pane] = .init(pane: UUID(), descriptor: descriptor, create: true)
            }
        }
    }

    private mutating func append(_ request: SessionRuntimeCloseRequest) {
        if !requests.contains(request) { requests.append(request) }
    }
}

/// Runs only after the user accepts quit. Session hosts are shared; close owned
/// pane IDs rather than stopping a daemon or signalling recorded remote PIDs.
@MainActor
final class SessionRuntimeQuit {
    static let shared = SessionRuntimeQuit()
    private var operation: Task<Bool, Never>?

    private func sessions() -> [SessionRuntimeQuitSession] {
        var records = Dictionary(uniqueKeysWithValues:
            TerminalWorkspaceSessionStore.shared.runtimeQuitSessions.map { ($0.pane, $0) })
        for surface in surfaces() { records[surface.id] = SessionRuntimeQuitSession(surface) }
        return Array(records.values)
    }

    private func surfaces() -> [Ghostty.SurfaceView] {
        let controllers = NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
        return (controllers.flatMap { Array($0.surfaceTree) } +
            TerminalWorkspaceCoordinator.shared.liveControllers.flatMap { Array($0.surfaceTree) })
    }

    func terminationReply(_ reply: NSApplication.TerminateReply) -> NSApplication.TerminateReply {
        guard reply == .terminateNow else { return reply }
        let plan = SessionRuntimeQuitPlan(sessions: sessions(), policy: OhMyGhosttySettings.shared.runtimeQuitPolicy)
        guard !plan.isEmpty else { return .terminateNow }
        Task {
            let allowed = await prepare(plan)
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func replyToAcceptedQuit() async {
        let plan = SessionRuntimeQuitPlan(sessions: sessions(), policy: OhMyGhosttySettings.shared.runtimeQuitPolicy)
        let allowed = await prepare(plan)
        NSApp.reply(toApplicationShouldTerminate: allowed)
    }

    private func prepare(_ plan: SessionRuntimeQuitPlan) async -> Bool {
        if let operation { return await operation.value }
        guard !plan.isEmpty else { return true }
        let operation = Task { @MainActor in
            do {
                try TerminalWorkspaceSessionStore.shared.prepareRuntimeQuit(plan.replacements)
                try SessionRuntimeCloseQueue.shared.enqueue(plan.requests)
                TerminalWorkspaceCoordinator.shared.commitTermination()
                await SessionRuntimeCloseQueue.shared.finishForQuit(sockets: plan.sockets)
                for surface in self.surfaces() {
                    if let descriptor = surface.runtimeDescriptor,
                       plan.requests.contains(.init(pane: surface.id, descriptor: descriptor)),
                       let native = surface.surface {
                        ghostty_surface_close_session(native)
                    }
                }
                return true
            } catch {
                TerminalTabSelectionRestoration.shared.cancelQuit()
                TerminalWorkspaceSessionStore.shared.cancelQuit()
                NSAlert(error: error).runModal()
                return false
            }
        }
        self.operation = operation
        let result = await operation.value
        self.operation = nil
        return result
    }
}
