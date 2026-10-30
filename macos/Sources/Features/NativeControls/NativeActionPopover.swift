import AppKit
import SwiftUI

struct NativeOptionsButton: NSViewRepresentable {
    let title: String
    let symbol: String?
    let help: String
    let entries: [NativeMenuEntry]
    func makeNSView(context: Context) -> NativeOptionsControl { NativeOptionsControl() }
    func updateNSView(_ button: NativeOptionsControl, context: Context) {
        button.configure(title: title, symbol: symbol, help: help, enabled: true, style: .plain, identifier: nil)
        button.entries = entries
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeOptionsControl, context: Context) -> CGSize? {
        CGSize(width: 24, height: 24)
    }
    static func dismantleNSView(_ view: NativeOptionsControl, coordinator: ()) { view.dismiss() }
}

final class NativeOptionsControl: NativeActionControl, NSPopoverDelegate {
    var entries: [NativeMenuEntry] = [] {
        didSet { (popover.contentViewController as? NativeActionPopoverController)?.update(entries) }
    }
    private let popover = NSPopover()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        onPress = { [weak self] in self?.present() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func dismiss() { popover.close() }
    func present() {
        guard isEnabled, let window else { return }
        if popover.isShown { dismiss(); return }
        let controller = NativeActionPopoverController(entries: entries)
        controller.surface.bindTheme(to: window)
        controller.onCancel = { [weak self] in self?.dismiss() }
        controller.onSelect = { [weak self] index in
            guard let self, self.entries.indices.contains(index),
                  case let .action(_, _, enabled, _, handler) = self.entries[index], enabled else { return }
            self.dismiss()
            handler()
        }
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        setPresentationActive(popover.isShown)
        controller.focusFirstOption()
    }
    func popoverDidClose(_ notification: Notification) {
        setPresentationActive(false)
        popover.contentViewController = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismiss() }
        super.viewWillMove(toWindow: newWindow)
    }
}

final class NativeActionPopoverController: NSViewController {
    let surface = OMGNativeSurfaceView()
    private let stack = NSStackView()
    private var buttons: [(index: Int, button: NativePopoverOptionControl)] = []
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    init(entries: [NativeMenuEntry]) {
        super.init(nibName: nil, bundle: nil)
        _ = view
        update(entries)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = surface
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -7),
        ])
        surface.setAccessibilityIdentifier("native.action.options.popup")
    }

    func update(_ entries: [NativeMenuEntry]) {
        // Keep existing controls and keyboard focus alive while status/draft updates arrive.
        let indices = entries.indices.filter { if case .action = entries[$0] { return true }; return false }
        if buttons.map(\.index) != indices {
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            buttons = []
            for (index, entry) in entries.enumerated() {
                if case .separator = entry {
                    let line = NSBox()
                    line.boxType = .separator
                    stack.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                } else if case .action = entry {
                    let button = NativePopoverOptionControl()
                    button.alignment = .left
                    button.onPress = { [weak self] in self?.onSelect?(index) }
                    button.onNavigation = { [weak self] event in self?.navigate(event) ?? false }
                    stack.addArrangedSubview(button)
                    NSLayoutConstraint.activate([
                        button.widthAnchor.constraint(equalTo: stack.widthAnchor),
                        button.heightAnchor.constraint(equalToConstant: 29),
                    ])
                    buttons.append((index, button))
                }
            }
        }
        for (index, button) in buttons {
            guard case let .action(title, symbol, enabled, checked, _) = entries[index] else { continue }
            button.configure(title: title, symbol: checked ? "checkmark" : symbol, help: nil, enabled: enabled,
                             style: .plain, identifier: "native.action.option.\(index)")
            button.setAccessibilityValue(checked ? "selected" : "")
            button.applyTheme(surface.theme)
        }
        let width = max(220, (buttons.map { $0.button.intrinsicContentSize.width }.max() ?? 0) + 14)
        preferredContentSize = NSSize(width: width, height: CGFloat(buttons.count) * 29 +
                                     CGFloat(stack.arrangedSubviews.count - buttons.count) +
                                     CGFloat(max(0, stack.arrangedSubviews.count - 1)) * 3 + 14)
        if let focused = view.window?.firstResponder as? NativePopoverOptionControl, !focused.isEnabled {
            focusFirstOption()
        }
    }

    func focusFirstOption() {
        if let button = buttons.first(where: { $0.button.isEnabled })?.button {
            view.window?.makeFirstResponder(button)
        }
    }

    private func navigate(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { onCancel?(); return true }
        guard event.keyCode == 125 || event.keyCode == 126 else { return false }
        let enabled = buttons.map(\.button).filter(\.isEnabled)
        guard !enabled.isEmpty else { return true }
        let current = enabled.firstIndex { $0 === view.window?.firstResponder } ?? 0
        let next = (current + (event.keyCode == 125 ? 1 : enabled.count - 1)) % enabled.count
        view.window?.makeFirstResponder(enabled[next])
        return true
    }
}

private final class NativePopoverOptionControl: NativeActionControl {
    var onNavigation: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onNavigation?(event) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 { performClick(nil); return }
        super.keyDown(with: event)
    }
}
