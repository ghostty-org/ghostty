import Cocoa
import SwiftUI

// MARK: - Main Window Manager

/// Manages a single custom-framed window containing the sidebar,
/// a custom tab bar, and embedded Ghostty terminal child windows.
/// The sidebar lives ONLY here — TerminalControllers are terminal-only.
@MainActor
class KanbanWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = KanbanWindowManager()

    private(set) var window: NSWindow?
    private var tabs: [TabItem] = []
    private var activeIndex: Int = 0 {
        didSet { syncTabVisibility() }
    }

    // MARK: - Launch

    func launch(ghostty: Ghostty.App) {
        // Ensure shared view model is set
        if TerminalController.sharedSidebarViewModel == nil {
            TerminalController.sharedSidebarViewModel = SidePanelViewModel()
            TerminalController.sharedSidebarViewModel?.setGhosttyApp(ghostty)
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.tabbingMode = .disallowed
        w.delegate = self
        w.center()
        window = w

        let sbw = sidebarWidth
        let hosting = NSHostingView(rootView: _KanbanRootView(manager: self, sbw: sbw))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = w.contentView?.bounds ?? .zero
        w.contentView = hosting
        w.makeKeyAndOrderFront(nil)

        // First tab
        let controller = TerminalController(ghostty, withBaseConfig: nil)
        addTab(controller: controller)
    }

    // MARK: - Tab management

    func addTab(controller: TerminalController) {
        configureChildWindow(controller)
        tabs.append(TabItem(controller: controller, title: "Tab \(tabs.count + 1)"))
        activeIndex = tabs.count - 1
    }

    func newTab(ghostty: Ghostty.App) {
        let controller = TerminalController(ghostty, withBaseConfig: nil)
        addTab(controller: controller)
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeIndex = index
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count, tabs.count > 1 else { return }
        let item = tabs.remove(at: index)
        item.controller.closeWindow(nil)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        syncTabVisibility()
    }

    // MARK: - Sidebar

    var sidebarWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "kanban_sidebar_width")
            return max(60, v > 0 ? v : 85)
        }
        set { UserDefaults.standard.set(newValue, forKey: "kanban_sidebar_width") }
    }

    var sidebarVisible: Bool = true {
        didSet {
            // SwiftUI won't see this directly; use a published state
            objectWillChange.send()
        }
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    // MARK: - Internal

    private func configureChildWindow(_ controller: TerminalController) {
        guard let cw = controller.window else { return }
        cw.styleMask = [] // borderless
        cw.titlebarAppearsTransparent = true
        cw.titleVisibility = .hidden
        cw.hasShadow = false
        cw.tabbingMode = .disallowed
        window?.addChildWindow(cw, ordered: .above)
    }

    private func syncTabVisibility() {
        for (i, item) in tabs.enumerated() {
            if i == activeIndex {
                item.controller.window?.orderFront(nil)
            } else {
                item.controller.window?.orderOut(nil)
            }
        }
        positionChildWindows()
    }

    func positionChildWindows() {
        guard let main = window else { return }
        let f = main.frame
        let tabH: CGFloat = 28
        let sbw = sidebarVisible ? sidebarWidth : 0
        let x = f.minX + sbw
        let y = f.minY + tabH
        let w = f.width - sbw
        let h = f.height - tabH
        guard w > 40, h > 40 else { return }
        for item in tabs {
            item.controller.window?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ n: Notification) { positionChildWindows() }
    func windowDidMove(_ n: Notification) { positionChildWindows() }

    func windowWillClose(_ n: Notification) {
        for item in tabs { item.controller.closeWindow(nil) }
        tabs.removeAll()
        window = nil
    }

    struct TabItem {
        let controller: TerminalController
        var title: String
        let id = UUID()
    }

    var tabItems: [TabItem] { tabs }
    var activeTabIndex: Int { activeIndex }
}

// MARK: - SwiftUI Root View

struct _KanbanRootView: View {
    let manager: KanbanWindowManager
    @State var sidebarWidth: CGFloat
    @State var selTabIndex: Int = 0
    /// Mirror manager.sidebarVisible for SwiftUI reactivity.
    @State var sbVisible: Bool = true

    init(manager: KanbanWindowManager, sbw: CGFloat) {
        self.manager = manager
        self._sidebarWidth = State(initialValue: sbw)
    }

    var body: some View {
        HStack(spacing: 0) {
            if sbVisible {
                SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
                    .frame(width: sidebarWidth)
                    .ignoresSafeArea(.all)

                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { v in
                        sidebarWidth = max(60, v.location.x)
                        manager.sidebarWidth = sidebarWidth
                        manager.positionChildWindows()
                    })
                    .backport.pointerStyle(.resizeLeftRight)
            }

            VStack(spacing: 0) {
                _KanbanTabBar(manager: manager, selTabIndex: $selTabIndex)
                    .frame(height: 28)

                Rectangle().fill(.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selTabIndex) { new in manager.selectTab(at: new) }
    }
}

// MARK: - Custom Tab Bar

struct _KanbanTabBar: View {
    let manager: KanbanWindowManager
    @Binding var selTabIndex: Int

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(manager.tabItems.enumerated()), id: \.element.id) { idx, t in
                        HStack(spacing: 4) {
                            Text(t.title).font(.system(size: 12)).lineLimit(1)
                            if manager.tabItems.count > 1 {
                                Button(action: { manager.closeTab(at: idx) }) {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(idx == selTabIndex ? Color(nsColor: .windowBackgroundColor) : .clear)
                        .cornerRadius(4)
                        .onTapGesture { selTabIndex = idx }
                    }
                }.padding(.horizontal, 4)
            }

            Button(action: {
                if let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty {
                    manager.newTab(ghostty: ghostty)
                    selTabIndex = manager.tabItems.count - 1
                }
            }) {
                Image(systemName: "plus").font(.system(size: 12))
            }.buttonStyle(.plain).padding(.horizontal, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
    }
}
