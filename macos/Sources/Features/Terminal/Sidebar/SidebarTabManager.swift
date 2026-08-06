import AppKit
import Combine

/// Observes the native tab group of a window and maintains one
/// `SidebarTabModel` per tab.
///
/// The published `models` array changes only when tabs are added,
/// removed or natively reordered; everything else (title, pwd, git,
/// selection, agent state) mutates the affected model in place so only
/// its row re-renders. `groupingVersion` bumps when group membership
/// inputs (pwd, surface id) change, signalling the view to re-resolve
/// sections without rebuilding rows.
@MainActor
final class SidebarTabManager: ObservableObject {
    @Published private(set) var models: [SidebarTabModel] = []
    @Published private(set) var groupingVersion = 0

    /// List animations stay off while a fresh sidebar populates: a new
    /// window's sidebar first sees only itself, then the whole group a
    /// beat later — animating that burst unfolds the entire list.
    @Published private(set) var animationsEnabled = false

    private weak var window: NSWindow?

    /// A newly created tab's window renders its sidebar before AppKit
    /// adds it to the tab group; until then, the parent group (the key
    /// window's at creation time) seeds the list so the sidebar never
    /// flashes empty.
    private weak var seedTabGroup: NSWindowTabGroup?

    private var modelsById: [ObjectIdentifier: SidebarTabModel] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var centerCancellables: Set<AnyCancellable> = []
    private var attentionWindows: Set<ObjectIdentifier> = []
    private var pendingRefresh = false
    private var didInitialPopulation = false

    /// Some metadata changes with no pwd/title event to observe — `git
    /// checkout`, or a dev server starting — so a slow timer keeps it fresh.
    private var metadataRefreshTimer: Timer?

    init(window: NSWindow) {
        self.window = window

        if let keyWindow = NSApp.keyWindow as? TerminalWindow,
           keyWindow !== window,
           let parentGroup = keyWindow.tabGroup {
            self.seedTabGroup = parentGroup
        }

        setupObservers()
        subscribeCenters()
        refresh()
        didInitialPopulation = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.animationsEnabled = true
        }

        metadataRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMetadata() }
        }
    }

    deinit {
        metadataRefreshTimer?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// All windows participating in this sidebar: our tab group once
    /// joined, else the seed (parent) group plus ourselves, else just us.
    private var groupWindows: [NSWindow] {
        guard let window else { return [] }

        if let own = window.tabGroup?.windows, own.count > 1 {
            seedTabGroup = nil
            return own
        }

        if let seeded = seedTabGroup?.windows, !seeded.isEmpty {
            return seeded.contains(window) ? seeded : seeded + [window]
        }

        return window.tabGroup?.windows ?? [window]
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let refreshNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for name in refreshNames {
            notificationObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }

        notificationObservers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let bellWindow = controller.window
                else { return }

                let hasBell = notification.userInfo?[
                    Notification.Name.terminalWindowHasBellKey
                ] as? Bool ?? false

                let identifier = ObjectIdentifier(bellWindow)
                if hasBell, bellWindow != NSApp.keyWindow {
                    self.attentionWindows.insert(identifier)
                } else {
                    self.attentionWindows.remove(identifier)
                }
                self.modelsById[identifier]?.setNeedsAttention(
                    self.attentionWindows.contains(identifier)
                )
            }
        })
    }

    /// Shared centers are observed once here and distributed into the
    /// affected models, so rows never observe app-wide state.
    private func subscribeCenters() {
        TabStateCenter.shared.$states
            .sink { [weak self] states in
                guard let self else { return }
                for model in self.models {
                    guard let surfaceId = model.surfaceId else { continue }
                    model.setAgentState(states[surfaceId])
                }
            }
            .store(in: &centerCancellables)

        GitStatusCenter.shared.$repos
            .sink { [weak self] repos in
                guard let self else { return }
                for model in self.models {
                    guard let root = model.repoRoot, let info = repos[root] else {
                        model.setRepoStatus(isDirty: nil, prNumber: nil, prURL: nil)
                        continue
                    }
                    model.setRepoStatus(
                        isDirty: info.isDirty,
                        prNumber: info.prNumber,
                        prURL: info.prURL
                    )
                }
            }
            .store(in: &centerCancellables)

        DevServerCenter.shared.$servers
            .sink { [weak self] servers in
                guard let self else { return }
                for model in self.models {
                    guard let pid = model.foregroundPID else {
                        model.setDevServerPort(nil)
                        continue
                    }
                    model.setDevServerPort(servers[pid]?.port)
                }
            }
            .store(in: &centerCancellables)
    }

    /// Only the selected tab's sidebar is on screen; hidden ones skip
    /// work entirely and catch up when their window is revealed (its
    /// didBecomeKey notification lands here as a scheduleRefresh).
    private var isSidebarVisible: Bool {
        guard let window else { return false }
        guard let group = window.tabGroup, group.windows.count > 1 else {
            return true
        }
        return group.selectedWindow == window
    }

    /// Coalesces bursts of notifications into a single pass per runloop turn.
    func scheduleRefresh() {
        guard !pendingRefresh, isSidebarVisible else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh()
        }
    }

    /// Reconciles models against the native tab group: updates existing
    /// models in place, creates models for new tabs, drops closed ones.
    /// The published array is only reassigned when membership or native
    /// order actually changed.
    func refresh() {
        let windows = groupWindows
        var seen = Set<ObjectIdentifier>()

        for tabWindow in windows {
            guard let controller = tabWindow.windowController as? BaseTerminalController
            else { continue }

            let identifier = ObjectIdentifier(tabWindow)
            seen.insert(identifier)

            let model: SidebarTabModel
            if let existing = modelsById[identifier] {
                model = existing
            } else {
                model = SidebarTabModel(window: tabWindow)
                modelsById[identifier] = model
                if didInitialPopulation {
                    registerNewTab(model, controller: controller)
                }
            }

            update(model, window: tabWindow, controller: controller)
        }

        for (identifier, _) in modelsById where !seen.contains(identifier) {
            modelsById.removeValue(forKey: identifier)
            attentionWindows.remove(identifier)
        }

        let ordered = windows.compactMap { modelsById[ObjectIdentifier($0)] }
        if ordered.map(\.id) != models.map(\.id) {
            models = ordered
        }
    }

    private func update(
        _ model: SidebarTabModel,
        window tabWindow: NSWindow,
        controller: BaseTerminalController
    ) {
        let surface = controller.focusedSurface
            ?? controller.surfaceTree.root?.leftmostLeaf()

        model.setTitle(tabWindow.title)
        model.setSelected(
            tabWindow.isKeyWindow || (tabWindow.tabGroup?.selectedWindow == tabWindow)
        )
        if model.isSelected {
            attentionWindows.remove(model.id)
        }
        model.setNeedsAttention(attentionWindows.contains(model.id))

        if model.surfaceId != surface?.id {
            model.setSurfaceId(surface?.id)
            if let surfaceId = surface?.id {
                model.setAgentState(TabStateCenter.shared.states[surfaceId])
            } else {
                model.setAgentState(nil)
            }
            bumpGrouping()
        }

        applyPwd(surface?.pwd, to: model)
        applyDevServer(surface, to: model)
        subscribe(model, to: surface)
    }

    /// The foreground PID changes every time a command starts or stops, so
    /// it is re-read on each pass and the scan is asked for again — the
    /// center coalesces that into one system-wide scan per TTL window.
    private func applyDevServer(
        _ surface: Ghostty.SurfaceView?,
        to model: SidebarTabModel
    ) {
        guard let pid = surface?.surfaceModel?.foregroundPID else {
            model.setForegroundPID(nil)
            model.setDevServerPort(nil)
            return
        }

        model.setForegroundPID(pid)
        model.setDevServerPort(DevServerCenter.shared.port(forPID: pid))
        DevServerCenter.shared.requestRefresh(pid: pid)
    }

    private func applyPwd(_ pwd: String?, to model: SidebarTabModel) {
        guard model.pwd != pwd else { return }
        model.setPwd(pwd)
        bumpGrouping()

        let git = Self.gitInfo(for: pwd)
        model.setGit(branch: git?.branch, root: git?.root)
        if let git {
            GitStatusCenter.shared.requestRefresh(root: git.root, branch: git.branch)
            let info = GitStatusCenter.shared.info(forRoot: git.root)
            model.setRepoStatus(
                isDirty: info?.isDirty,
                prNumber: info?.prNumber,
                prURL: info?.prURL
            )
        } else {
            model.setRepoStatus(isDirty: nil, prNumber: nil, prURL: nil)
        }
    }

    /// Surface publishers update the model directly — no list refresh.
    private func subscribe(_ model: SidebarTabModel, to surface: Ghostty.SurfaceView?) {
        guard let surface, model.surfaceCancellables.isEmpty else { return }

        surface.$title
            .removeDuplicates()
            .sink { [weak model] _ in
                guard let model else { return }
                model.setTitle(model.window.title)
            }
            .store(in: &model.surfaceCancellables)

        surface.$pwd
            .removeDuplicates()
            .sink { [weak self, weak model] pwd in
                guard let self, let model else { return }
                self.applyPwd(pwd, to: model)
            }
            .store(in: &model.surfaceCancellables)
    }

    private func bumpGrouping() {
        groupingVersion &+= 1
    }

    /// New tabs are placed at the top or bottom of the sidebar order,
    /// per the user's setting.
    private func registerNewTab(
        _ model: SidebarTabModel,
        controller: BaseTerminalController
    ) {
        let surface = controller.focusedSurface
            ?? controller.surfaceTree.root?.leftmostLeaf()
        guard let surfaceId = surface?.id else { return }

        let atStart = UserDefaults.standard.string(
            forKey: "SidebarNewTabPosition"
        ) == "start"
        SidebarGroupStore.shared.registerNewTab(surfaceId: surfaceId, atStart: atStart)
    }

    /// The periodic pass: re-reads what changes with no notification to
    /// hang off of — git state, and the process each tab is running.
    private func refreshMetadata() {
        guard isSidebarVisible else { return }

        for model in models {
            let git = Self.gitInfo(for: model.pwd)
            model.setGit(branch: git?.branch, root: git?.root)
            if let git {
                GitStatusCenter.shared.requestRefresh(root: git.root, branch: git.branch)
            }
        }

        for tabWindow in groupWindows {
            guard let controller = tabWindow.windowController as? BaseTerminalController,
                  let model = modelsById[ObjectIdentifier(tabWindow)]
            else { continue }
            applyDevServer(
                controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf(),
                to: model
            )
        }
    }

    /// Activates the given tab (window) within the group.
    func select(_ model: SidebarTabModel) {
        model.window.makeKeyAndOrderFront(nil)
    }

    /// Resolves the repository root and current branch for a working
    /// directory by walking up to `.git` and reading `HEAD` directly —
    /// no git execution. Worktrees (a `.git` file pointing at the real
    /// git dir) are followed; a detached HEAD yields the short hash.
    nonisolated static func gitInfo(for pwd: String?) -> (root: String, branch: String?)? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: pwd)

        for _ in 0..<16 {
            let gitURL = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                let headURL: URL
                if isDir.boolValue {
                    headURL = gitURL.appendingPathComponent("HEAD")
                } else {
                    guard let content = try? String(contentsOf: gitURL, encoding: .utf8),
                          content.hasPrefix("gitdir:")
                    else { return (dir.path, nil) }
                    let path = content.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDir = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : dir.appendingPathComponent(path)
                    headURL = gitDir.appendingPathComponent("HEAD")
                }

                guard let head = try? String(contentsOf: headURL, encoding: .utf8)
                else { return (dir.path, nil) }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return (dir.path, String(trimmed.dropFirst("ref: refs/heads/".count)))
                }
                return (dir.path, String(trimmed.prefix(7)))
            }

            if dir.path == "/" { break }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}