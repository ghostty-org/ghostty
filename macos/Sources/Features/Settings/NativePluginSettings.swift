import AppKit

extension NativeSettingsController {
    func plugins(_ form: NativeSettingsForm) {
        let manager = PluginInstallationManager.shared
        form.section(text("Plugins", "插件"))
        let official = PluginInstallationManager.officialPlugins
        let manifests = official + manager.installed.filter { installed in !official.contains { $0.id == installed.id } }
        for manifest in manifests {
            let enabled = manager.isEnabled(manifest.id)
            let name = manifest.id == SSHPlugin.pluginID ? "SSH" : manifest.id
            let control = SettingsSwitch(value: enabled) { [weak self] on in
                do {
                    if !manager.isInstalled(manifest.id) { try manager.installOfficial(manifest.id) }
                    if on { try manager.enable(manifest.id) } else { try manager.disable(manifest.id) }
                } catch { self?.showError(error) }
            }
            let details = SettingsActionButton(text("Details…", "详情…")) { [weak self] in
                guard let self else { return }
                self.push(name, previous: { [weak self] in self?.select(.plugins) }, build: { page in
                    page.section(name)
                    page.row(self.text("Version", "版本"), control: NSTextField(labelWithString: manifest.version))
                    if official.contains(where: { $0.id == manifest.id }) {
                        page.row(self.text("Update package", "更新插件包"), control: SettingsActionButton(self.text("Update", "更新")) { [weak self] in
                            do { try manager.installOfficial(manifest.id) } catch { self?.showError(error) }
                        })
                    }
                    page.note(manifest.id == SSHPlugin.pluginID ? self.strings.sshPluginCaption : self.strings.genericPluginCaption)
                    page.note(manifest.capabilities.map { String(describing: $0) }.joined(separator: " · "))
                })
            }
            form.row(name, control: NSStackView(views: [control, details]))
        }
        form.section(text("Plugin packages", "插件包"))
        let repository = SettingsTextField("", placeholder: "https://github.com/owner/repo") { _ in }
        form.row("GitHub", control: repository)
        let install = SettingsActionButton(strings.installButton) {}
        install.invoke = { [weak self, weak install, weak repository] in
            guard let self, let text = repository?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text), !text.isEmpty else { return }
            install?.isEnabled = false
            Task { @MainActor [weak self, weak install] in
                defer { install?.isEnabled = true }
                do {
                    _ = try await manager.install(from: url)
                    if self?.isShowing(OhMyGhosttySettingsTab.plugins.rawValue) == true { self?.select(.plugins) }
                } catch { self?.showError(error) }
            }
        }
        form.row(text("Install package", "安装插件包"), control: install)
        form.note(strings.installFromGitHubCaption)
        for manifest in manager.installed {
            form.row(manifest.id, control: SettingsActionButton(text("Uninstall…", "卸载…")) { [weak self] in
                self?.confirm(self?.text("Uninstall \(manifest.id)?", "卸载 \(manifest.id)？") ?? "") { [weak self] in
                    do { try manager.uninstall(manifest.id); self?.select(.plugins) } catch { self?.showError(error) }
                }
            })
        }
    }
}
