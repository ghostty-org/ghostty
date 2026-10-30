import AppKit

/// Native replacement for the themed two-button alert wrapper, preserving its accessory and response codes.
@MainActor
final class OMGNativeDialogController: NSViewController {
    private let alert: NSAlert
    private let finish: (NSApplication.ModalResponse) -> Void
    private let surface = OMGNativeSurfaceView()

    init(alert: NSAlert, finish: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.finish = finish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(wrappingLabelWithString: alert.messageText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: alert.informativeText)
        message.font = .systemFont(ofSize: 12)
        let cancel = NativeActionControl()
        cancel.configure(title: alert.buttons[1].title, symbol: nil, help: nil,
                         enabled: true, style: .bordered, identifier: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        cancel.onPress = { [weak self] in self?.finish(.alertSecondButtonReturn) }
        let confirm = NativeActionControl()
        confirm.configure(title: alert.buttons[0].title, symbol: nil, help: nil,
                          enabled: true, style: .prominent, identifier: nil)
        confirm.keyEquivalent = "\r"
        confirm.keyEquivalentModifierMask = []
        confirm.onPress = { [weak self] in self?.finish(.alertFirstButtonReturn) }
        let actions = NSStackView(views: [cancel, NSView(), confirm])
        actions.orientation = .horizontal
        actions.spacing = 8
        var items: [NSView] = [title, message]
        if let accessory = alert.accessoryView { items.append(accessory) }
        items.append(actions)
        let stack = NSStackView(views: items)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        let width = max(392, (alert.accessoryView?.frame.width ?? 0))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: width),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.heightAnchor.constraint(equalToConstant: 28),
        ])
        if let accessory = alert.accessoryView {
            accessory.heightAnchor.constraint(greaterThanOrEqualToConstant: max(26, accessory.frame.height)).isActive = true
        }
        view = surface
    }

    func bindTheme(to window: NSWindow?) { _ = view; surface.bindTheme(to: window) }
}
