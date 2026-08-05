import AppKit
import Combine

/// Observes the native tab group of a window and publishes a flat list
/// of tab metadata for the sidebar to render.
///
/// The sidebar never replaces native tabbing: each tab is still an
/// `NSWindow` in the window's `tabGroup`, so shortcuts, splits and
/// restoration keep working. This manager is a read-model on top.
@MainActor
final class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let surfaceId: UUID?
        let isSelected: Bool
        let needsAttention: Bool
        unowned let window: NSWindow

        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd
                && lhs.surfaceId == rhs.surfaceId
                && lhs.isSelected == rhs.isSelected
                && lhs.needsAttention == rhs.needsAttention
        }
    }

    @Published private(set) var tabs: [TabItem] = []

    private weak var window: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var attentionWindows: Set<ObjectIdentifier> = []
    private var pendingRefresh = false

    init(window: NSWindow) {
        self.window = window
        setupObservers()
        refresh()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// All windows participating in this sidebar: the tab group when one
    /// exists, otherwise just our own window.
    private var groupWindows: [NSWindow] {
        guard let window else { return [] }
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

                if hasBell, bellWindow != NSApp.keyWindow {
                    self.attentionWindows.insert(ObjectIdentifier(bellWindow))
                } else {
                    self.attentionWindows.remove(ObjectIdentifier(bellWindow))
                }
                self.scheduleRefresh()
            }
        })
    }

    /// Coalesces bursts of notifications into a single rebuild per runloop turn.
    func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh()
        }
    }

    func refresh() {
        surfaceCancellables.removeAll()

        let items: [TabItem] = groupWindows.compactMap { tabWindow in
            guard let controller = tabWindow.windowController as? BaseTerminalController
            else { return nil }

            let surface = controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
            let identifier = ObjectIdentifier(tabWindow)
            let isSelected = tabWindow.isKeyWindow
                || (tabWindow.tabGroup?.selectedWindow == tabWindow)

            if isSelected { attentionWindows.remove(identifier) }

            subscribe(to: surface)

            return TabItem(
                id: identifier,
                title: tabWindow.title,
                pwd: surface?.pwd,
                surfaceId: surface?.id,
                isSelected: isSelected,
                needsAttention: attentionWindows.contains(identifier),
                window: tabWindow
            )
        }

        if items != tabs { tabs = items }
    }

    private func subscribe(to surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        surface.$title
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &surfaceCancellables)
        surface.$pwd
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &surfaceCancellables)
    }

    /// Activates the given tab (window) within the group.
    func select(_ item: TabItem) {
        item.window.makeKeyAndOrderFront(nil)
    }
}
