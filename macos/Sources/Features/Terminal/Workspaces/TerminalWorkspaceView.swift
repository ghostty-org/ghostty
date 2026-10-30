import AppKit
import SwiftUI

struct TerminalWorkspaceHeaderState {
    let name: String
    let symbol: String
    let tint: NSColor
    let needsAttention: Bool
    let isPresented: Bool
    let shortcut: String
}

struct TerminalWorkspaceButton: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    @ObservedObject private var store: TerminalWorkspaceStore
    @ObservedObject private var coordinator: TerminalWorkspaceCoordinator
    @ObservedObject private var activities: TabActivityStore

    init(controller: TerminalController) {
        self.controller = controller
        self.store = controller.workspaceCoordinator.store
        self.coordinator = controller.workspaceCoordinator
        self.activities = (NSApp.delegate as? AppDelegate)?.tabActivities ?? TabActivityStore()
    }

    func makeNSView(context: Context) -> TerminalWorkspaceHeaderButton {
        TerminalWorkspaceHeaderButton()
    }

    func updateNSView(_ button: TerminalWorkspaceHeaderButton, context: Context) {
        let workspace = controller.workspaceCoordinator.presentationWorkspace(controller.workspaceID)
        let needsAttention = coordinator.liveControllers.contains { other in
            guard other.workspaceID != controller.workspaceID else { return false }
            return other.surfaceTree.contains { surface in
                let state = activities.activity(for: surface.id)?.state
                return state == .needsAttention || state == .error
            } || activities.activity(for: other.tabSessionID)?.state == .needsAttention
        }
        let shortcut = OMGKeyboardShortcut(storageValue: store.shortcut(slot: 0))?.displayValue ?? ""
        let state = TerminalWorkspaceHeaderState(
            name: workspace?.name ?? WorkspaceL10n.text("Workspace", "工作区"),
            symbol: workspace?.symbol ?? "square.grid.2x2",
            tint: NSColor(workspace?.tint ?? .secondary),
            needsAttention: needsAttention,
            isPresented: controller.workspaceSwitcherIsPresented,
            shortcut: shortcut
        )
        button.configure(state, controller: controller) { [weak controller] in
            controller?.workspaceSwitcherIsPresented.toggle()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalWorkspaceHeaderButton, context: Context) -> CGSize? {
        nsView.fittingSize(proposedWidth: proposal.width)
    }
}

@MainActor
final class TerminalWorkspaceHeaderButton: NativeActionControl {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let attentionView = NSView()
    private weak var controller: TerminalController?
    private var activate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .recessed
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        target = self
        action = #selector(activateWorkspace)
        symbolView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) }
        chevronView.contentTintColor = .secondaryLabelColor
        attentionView.wantsLayer = true
        attentionView.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        attentionView.layer?.cornerRadius = 2.5
        let row = NSStackView(views: [symbolView, titleLabel, chevronView, attentionView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
            attentionView.widthAnchor.constraint(equalToConstant: 5),
            attentionView.heightAnchor.constraint(equalToConstant: 5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        attentionView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    func configure(_ state: TerminalWorkspaceHeaderState,
                   controller: TerminalController,
                   activate: @escaping () -> Void) {
        self.controller = controller
        wantsLayer = true
        titleLabel.stringValue = state.name
        symbolView.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        symbolView.contentTintColor = state.tint
        attentionView.isHidden = !state.needsAttention
        setPresentationActive(false)
        let base = WorkspaceL10n.text("Switch workspace", "切换工作区")
        toolTip = state.shortcut.isEmpty ? base : "\(base) · \(state.shortcut)"
        setAccessibilityLabel(WorkspaceL10n.text("Workspace: ", "工作区：") + state.name)
        setAccessibilityIdentifier("workspace.switcher")
        setAccessibilityHelp(state.shortcut.isEmpty ? nil : state.shortcut)
        self.activate = activate
        controller.workspacePopover.update(anchor: self)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let controller, window != nil { controller.workspacePopover.update(anchor: self) }
    }

    override func applyTheme(_ theme: OMGNativeTheme) {
        super.applyTheme(theme)
        titleLabel.textColor = theme.foreground
        chevronView.contentTintColor = theme.secondary
    }

    func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        let textWidth = ceil((titleLabel.stringValue as NSString).size(
            withAttributes: [.font: titleLabel.font ?? .systemFont(ofSize: 12)]
        ).width)
        let chromeWidth: CGFloat = 16 + 12 + 14 + 14 + (attentionView.isHidden ? 0 : 12)
        return CGSize(width: min(textWidth + chromeWidth, max(chromeWidth, proposedWidth ?? .greatestFiniteMagnitude)),
                      height: 28)
    }

    @objc private func activateWorkspace() { activate?() }
}

/// The controller owns both the native popover and its management session.
/// Closing the native window is an explicit boundary before fullscreen commands.
@MainActor
final class WorkspacePopoverPresentation: NSObject, NSPopoverDelegate {
    private weak var controller: TerminalController?
    private let popover = NSPopover()
    private weak var anchor: NSView?
    private var pendingAction: (() -> Void)?
    private var isClosing = false
    private var management: TerminalWorkspacePickerModel?
    private(set) var contentCreationCount = 0
    var isShown: Bool { popover.isShown }
    var contentView: NSView? { popover.contentViewController?.view }
    var contentController: NSViewController? { popover.contentViewController }

    init(controller: TerminalController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func update(anchor: NSView) {
        self.anchor = anchor
        setPresented(controller?.workspaceSwitcherIsPresented == true)
    }

    func setPresented(_ presented: Bool) {
        guard presented else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard let controller, !popover.isShown, !isClosing, controller.isAvailableForWorkspace,
              !controller.workspacePresentationIsParked, let window = controller.window else { return }
        let source: NSView
        let rect: NSRect
        if let anchor, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor,
           anchor.bounds.width > 0, anchor.bounds.height > 0 {
            source = anchor
            rect = anchor.bounds
        } else {
            guard let content = window.contentView else { return }
            source = content
            rect = NSRect(x: 12, y: content.isFlipped ? 0 : max(0, content.bounds.height - 1), width: 1, height: 1)
        }
        if management == nil {
            management = TerminalWorkspacePickerModel(controller: controller, dismiss: { [weak self] action in
                self?.close(after: action)
            }, reopen: { [weak controller] in controller?.workspaceSwitcherIsPresented = true })
        }
        guard let management else { return }
        let picker = TerminalWorkspacePickerController(model: management)
        picker.onPreferredSizeChange = { [weak popover] size in
            popover?.contentSize = size
        }
        picker.bindTheme(to: window)
        popover.contentViewController = picker
        popover.contentSize = picker.fittingSize(proposedWidth: nil)
        contentCreationCount += 1
        popover.show(relativeTo: rect, of: source, preferredEdge: .maxY)
    }

    func close(after action: (() -> Void)? = nil) {
        if let action { pendingAction = action }
        guard !isClosing else { return }
        if popover.isShown {
            isClosing = true
            popover.performClose(nil)
        } else {
            finishClosing()
        }
    }

    func popoverDidClose(_ notification: Notification) { finishClosing() }

    private func finishClosing() {
        isClosing = false
        let action = pendingAction
        pendingAction = nil
        controller?.workspaceSwitcherIsPresented = false
        popover.contentViewController = nil
        if let action {
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller, controller.isAvailableForWorkspace else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                action()
            }
        } else if management?.isPerforming != true {
            management = nil
        }
    }
}

struct WorkspaceShortcutSettingsView: View {
    @ObservedObject private var store = TerminalWorkspaceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkspaceL10n.text(
                "Switch workspaces without stopping running sessions. Shortcuts apply inside OMG and must include Command.",
                "切换工作区时保持会话运行。快捷键仅在 OMG 内生效，且必须包含 Command。"
            )).font(.caption).foregroundStyle(.secondary)
            ForEach(0...9, id: \.self) { slot in
                LabeledContent(slot == 0 ? WorkspaceL10n.text("Workspace switcher", "工作区切换器") :
                                WorkspaceL10n.text("Workspace \(slot)", "工作区 \(slot)")) {
                    HStack(spacing: 8) {
                        OMGShortcutRecorder(storageValue: Binding(
                            get: { store.shortcut(slot: slot) }, set: { store.setShortcut(slot: slot, value: $0) }
                        )).frame(width: 112, height: 24)
                        NativeActionButton(
                            title: WorkspaceL10n.text("Reset", "重置"),
                            style: .bordered,
                            height: 22,
                            identifier: "workspace.shortcut.reset.\(slot)"
                        ) { _ in
                            store.setShortcut(slot: slot, value: TerminalWorkspaceStore.defaultShortcut(slot: slot))
                        }
                    }
                }
                if let conflict = store.shortcutConflict(slot: slot) {
                    Label(WorkspaceL10n.text("Also used by: ", "同时用于：") + conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
