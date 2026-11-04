import Foundation

extension TerminalController {
    func importRemoteQuickInputDraft(
        for surface: Ghostty.SurfaceView, context: PaneSessionContext, setting: String
    ) {
        guard !setting.isEmpty, !SecureInput.shared.enabled,
              case .sshReady(let ssh, _) = context.state,
              let connection = try? GitSSHConnection(session: context) else { return }
        let descriptor = surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor
        let runtime = descriptor.flatMap { $0.isLocal ? nil : $0 }
        let inlinePane = surface.runtimeInlineSession?.pane
        let runtimePane = inlinePane ?? surface.id
        let runtimeIdentity = descriptor?.identity
        let agent = agentActivity(for: surface).flatMap { SupportedAgent(rawValue: $0.source) }
            ?? agentResumeDescriptor(for: surface)?.agent
        let hasAgentActivity = agentActivity(for: surface) != nil
        let request = UUID().uuidString
        quickInputDraftImportTask = Task { @MainActor [weak self, weak surface] in
            var snapshot: QuickInputTerminalSnapshot?
            var target: QuickInputRemoteDraftBridge.Target?
            defer {
                snapshot?.removeAfterRedraw()
                self?.quickInputDraftImportTask = nil
            }
            do {
                let resolved: QuickInputRemoteDraftBridge.Target
                let foregroundAgent: SupportedAgent?
                if let runtime {
                    resolved = try await QuickInputRemoteDraftBridge.runtimeTarget(
                        connection: connection, revision: runtime.revision, pane: runtimePane)
                    foregroundAgent = resolved.commands.flatMap { LocalAgentProcessDetector.detect(in: $0) }
                } else {
                    guard ssh.connectionID.hasPrefix("omg-ssh-"), ssh.localProcessGroupID == nil,
                          let tty = ssh.remoteTTY else { return }
                    resolved = .init(session: ssh.connectionID, tty: tty)
                    foregroundAgent = try await QuickInputRemoteDraftBridge.foregroundAgent(
                        connection: connection, session: resolved.session, tty: resolved.tty)
                }
                target = resolved
                guard !Task.isCancelled,
                      let keys = QuickInputDraftBridge.importKeys(
                        setting: setting, agent: foregroundAgent ?? agent, hasAgentActivity: hasAgentActivity
                      ) else { return }
                try await QuickInputRemoteDraftBridge.begin(
                    connection: connection, session: resolved.session, request: request, tty: resolved.tty, root: resolved.root,
                    generation: resolved.generation
                )
                guard !Task.isCancelled, let self, let surface,
                      self.quickInputModel.isPresented,
                      self.quickInputModel.targetSurfaceID == surface.id,
                      self.paneSessionContext(for: surface)?.state == context.state,
                      surface.runtimeInlineSession?.pane == inlinePane,
                      (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)?.identity == runtimeIdentity,
                      !SecureInput.shared.enabled, let terminal = surface.surfaceModel else {
                    await QuickInputRemoteDraftBridge.finish(connection: connection, session: resolved.session, request: request, root: resolved.root)
                    return
                }
                snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .milliseconds(150))
                for key in keys {
                    terminal.sendKeyEvent(key)
                    terminal.sendKeyEvent(.init(key: key.key, action: .release, mods: key.mods,
                                                unshiftedCodepoint: key.unshiftedCodepoint))
                }
                let text = try await QuickInputRemoteDraftBridge.receive(
                    connection: connection, session: resolved.session, request: request, root: resolved.root
                )
                guard !Task.isCancelled, self.quickInputModel.isPresented,
                      self.quickInputModel.targetSurfaceID == surface.id,
                      self.paneSessionContext(for: surface)?.state == context.state,
                      surface.runtimeInlineSession?.pane == inlinePane,
                      (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)?.identity == runtimeIdentity,
                      !SecureInput.shared.enabled else {
                    await QuickInputRemoteDraftBridge.finish(connection: connection, session: resolved.session, request: request, root: resolved.root)
                    return
                }
                self.quickInputModel.importAgentDraft(text)
                self.quickInputModel.setStatusMessage(SettingsStrings(language: OhMyGhosttySettings.shared.language).quickInputDraftImported)
            } catch {
                if !Task.isCancelled, let self, let surface, self.quickInputModel.isPresented,
                   self.quickInputModel.targetSurfaceID == surface.id {
                    let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                    let legacy = (error as NSError).domain == "OMGRemoteDraft" && (error as NSError).code == 1
                    self.quickInputModel.setStatusMessage(legacy
                        ? strings.t("This SSH session has no draft bridge. Ensure remote Python 3 is available, then resume the agent in a new SSH session.",
                                    "此 SSH 会话没有草稿桥接。请确认远端有 Python 3，再在新建 SSH 会话中恢复 Agent。")
                        : strings.t("Remote draft unavailable. Check the connection and the agent's external editor.",
                                    "远程草稿暂不可用，请检查连接和 Agent 的外部编辑器配置。"))
                }
            }
            if let target {
                await QuickInputRemoteDraftBridge.finish(connection: connection, session: target.session, request: request, root: target.root)
            }
        }
    }
}
