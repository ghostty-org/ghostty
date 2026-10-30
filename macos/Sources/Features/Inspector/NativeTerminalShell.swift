import AppKit
import SwiftUI

/// Only this native container assigns the three shell frames. Hosted leaves
/// cannot feed their fitting sizes back into the terminal's available geometry.
struct NativeTerminalShell: NSViewControllerRepresentable {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let leadingVisible: Bool
    let trailingVisible: Bool
    let leading: AnyView
    let center: AnyView
    let trailing: AnyView

    func makeNSViewController(context: Context) -> TerminalShellController {
        TerminalShellController()
    }

    func updateNSViewController(_ controller: TerminalShellController, context: Context) {
        controller.update(
            leading: AnyView(leading.environment(\.self, context.environment)),
            center: AnyView(center.environment(\.self, context.environment)),
            trailing: AnyView(trailing.environment(\.self, context.environment)),
            layout: .init(leadingWidth: leadingWidth, trailingWidth: trailingWidth,
                          leadingVisible: leadingVisible, trailingVisible: trailingVisible)
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: TerminalShellController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct TerminalShellGeometry {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let leadingVisible: Bool
    let trailingVisible: Bool
}

final class TerminalShellController: NSViewController {
    let container = TerminalShellNativeView()

    override func loadView() { view = container }

    func update(leading: AnyView, center: AnyView, trailing: AnyView,
                layout: TerminalShellGeometry) {
        _ = view
        container.update(leading: leading, center: center, trailing: trailing,
                         layout: layout)
    }
}

final class TerminalShellNativeView: NSView {
    private(set) var leadingHost: NSHostingView<AnyView>?
    private(set) var trailingHost: NSHostingView<AnyView>?
    let centerHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var leadingWidth: CGFloat = 0
    private var trailingWidth: CGFloat = 0
    private var leadingVisible = false
    private var trailingVisible = false
    private weak var lastContentResponder: NSView?
    private var windowObservation: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        centerHost.sizingOptions = []
        addSubview(centerHost)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        lastContentResponder = nil
        guard let window else { return }
        windowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberContentResponder() }
        }
    }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    private func rememberContentResponder() {
        if let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: centerHost), !responder.isHiddenOrHasHiddenAncestor {
            lastContentResponder = responder
        }
    }

    func update(leading: AnyView, center: AnyView, trailing: AnyView,
                layout: TerminalShellGeometry) {
        self.leadingWidth = layout.leadingWidth
        self.trailingWidth = layout.trailingWidth
        self.leadingVisible = layout.leadingVisible
        self.trailingVisible = layout.trailingVisible
        rememberContentResponder()
        centerHost.rootView = center
        updateHost(&leadingHost, content: leading, visible: layout.leadingVisible)
        updateHost(&trailingHost, content: trailing, visible: layout.trailingVisible)
        // The existing tab-group sidebar owns one shared live list. Preserve
        // its unregister-on-collapse contract until the separate tab migration.
        if !layout.leadingVisible, let host = leadingHost {
            host.rootView = AnyView(EmptyView())
            host.removeFromSuperview()
            leadingHost = nil
        }
        needsLayout = true
    }

    private func updateHost(_ host: inout NSHostingView<AnyView>?, content: AnyView, visible: Bool) {
        if host == nil, visible {
            let created = NSHostingView(rootView: content)
            created.sizingOptions = []
            addSubview(created)
            host = created
        } else {
            // Hidden Inspector still receives visibility=false so its native
            // presenter can stop provider work while keeping the cached views.
            host?.rootView = content
        }
        if !visible, let host, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: host) {
            if let previous = lastContentResponder, previous.window === window,
               previous.isDescendant(of: centerHost), !previous.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(previous)
            } else {
                window?.makeFirstResponder(nil)
            }
        }
        host?.isHidden = !visible
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let left = leadingVisible ? min(max(0, leadingWidth), width) : 0
        let right = trailingVisible ? min(width - left, TerminalShellStyle.presentedInspectorWidth(
            preferred: trailingWidth, totalWidth: width, leadingWidth: left
        ) + TerminalShellStyle.dividerWidth) : 0
        if leadingVisible {
            setFrame(NSRect(x: 0, y: 0, width: left, height: bounds.height), on: leadingHost)
        }
        setFrame(NSRect(x: left, y: 0, width: max(0, width - left - right), height: bounds.height), on: centerHost)
        if trailingVisible {
            setFrame(NSRect(x: width - right, y: 0, width: right, height: bounds.height), on: trailingHost)
        }
    }

    private func setFrame(_ frame: NSRect, on view: NSView?) {
        guard let view, view.frame != frame else { return }
        view.frame = frame
    }
}
