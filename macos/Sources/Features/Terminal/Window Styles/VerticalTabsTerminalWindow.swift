import AppKit
import SwiftUI

/// A terminal window that keeps AppKit tab grouping but renders tabs in the content sidebar.
final class VerticalTabsTerminalWindow: TransparentTitlebarTerminalWindow {
    override var supportsUpdateAccessory: Bool { false }
    override var usesNativeTitleDecorations: Bool { false }

    private let sidebarToggleAccessory = NSTitlebarAccessoryViewController()
    private var sidebarToggleWidthConstraint: NSLayoutConstraint?
    private(set) var nativeTabBarRejectionCount = 0

    override func awakeFromNib() {
        super.awakeFromNib()
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var title: String {
        didSet { if titleVisibility != .hidden { titleVisibility = .hidden } }
    }

    override func becomeMain() {
        super.becomeMain()
        titleVisibility = .hidden
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        titleVisibility = .hidden
    }

    func installSidebarToggle(controller: TerminalController) {
        let isInstalled = titlebarAccessoryViewControllers.contains(sidebarToggleAccessory)
        sidebarToggleAccessory.layoutAttribute = .left
        sidebarToggleAccessory.view = AlignedTerminalTitlebarControlsView(
            minimumWidth: TerminalTitlebarMetrics.leftAccessoryWidth,
            rootView: VerticalTabsTitlebarControls(
                layoutState: controller.tabLayoutState,
                toggleSidebar: { [weak controller] in controller?.toggleSidebar(nil) },
                newTab: { [weak controller] in controller?.newVerticalTab() }
            )
        )
        sidebarToggleAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleWidthConstraint?.isActive = false
        let widthConstraint = sidebarToggleAccessory.view.widthAnchor.constraint(
            equalToConstant: TerminalTitlebarMetrics.leftAccessoryWidth
        )
        sidebarToggleWidthConstraint = widthConstraint
        widthConstraint.isActive = true
        if !isInstalled {
            addTitlebarAccessoryViewController(sidebarToggleAccessory)
        }
    }

    override func addTitlebarAccessoryViewController(
        _ childViewController: NSTitlebarAccessoryViewController
    ) {
        // AppKit creates this controller before displaying its horizontal tab strip.
        // Keep the NSWindowTabGroup, but never let the strip enter our view hierarchy.
        guard !isTabBar(childViewController) else {
            nativeTabBarRejectionCount += 1
            return
        }
        super.addTitlebarAccessoryViewController(childViewController)
    }

    var sidebarToggleIsInstalled: Bool {
        titlebarAccessoryViewControllers.contains(sidebarToggleAccessory)
    }

    var titlebarControlsCenterY: CGFloat? {
        (sidebarToggleAccessory.view as? TerminalTitlebarControlsCentering)?.contentCenterYInWindow
    }

    var titlebarControlsHeight: CGFloat? {
        guard sidebarToggleAccessory.view.window != nil else { return nil }
        return sidebarToggleAccessory.view.bounds.height
    }

    var titlebarControlsWidth: CGFloat? {
        guard sidebarToggleAccessory.view.window != nil else { return nil }
        return sidebarToggleAccessory.view.bounds.width
    }

    var trafficLightsCenterY: CGFloat? {
        let buttons = [
            standardWindowButton(.closeButton),
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        guard !buttons.isEmpty else { return nil }
        let centers = buttons.compactMap { button -> CGFloat? in
            guard let superview = button.superview else { return nil }
            return superview.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            ).y
        }
        guard !centers.isEmpty else { return nil }
        return centers.reduce(0, +) / CGFloat(centers.count)
    }

    var nativeTabBarIsSuppressed: Bool {
        !titlebarAccessoryViewControllers.contains(where: isTabBar) && tabBarView == nil
    }
}

private struct VerticalTabsTitlebarControls: View {
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    let toggleSidebar: () -> Void
    let newTab: () -> Void

    var body: some View {
        HStack(spacing: TerminalTitlebarControlStyle.itemSpacing) {
            TerminalTitlebarIconButton(
                systemName: "sidebar.left",
                help: layoutState.isSidebarVisible ? "Hide Tabs" : "Show Tabs",
                action: toggleSidebar
            )
            TerminalTitlebarIconButton(
                systemName: "plus",
                help: "New Tab",
                action: newTab
            )
            Spacer(minLength: 0)
        }
    }
}
