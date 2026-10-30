import AppKit
import SwiftUI

struct GitCommitOptionsButton: NSViewRepresentable {
    let enabled: Bool
    let repository: GitRepositoryIdentity?
    let entries: [NativeMenuEntry]
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> GitCommitOptionsControl { GitCommitOptionsControl() }

    func updateNSView(_ button: GitCommitOptionsControl, context: Context) {
        button.update(enabled: enabled && environmentEnabled, repository: repository, entries: entries)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitCommitOptionsControl, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }

    static func dismantleNSView(_ button: GitCommitOptionsControl, coordinator: ()) { button.close() }
}

/// A native popover rather than an NSMenu lets commit options share the OMG palette.
final class GitCommitOptionsControl: NativeActionControl, NSPopoverDelegate {
    private let chevron = CAShapeLayer()
    private let popover = NSPopover()
    private var repository: GitRepositoryIdentity?
    private var entries: [NativeMenuEntry] = []
    private weak var previousResponder: NSResponder?
    private var restoreFocus = false
    var isExpanded: Bool { popover.isShown }
    var optionsController: GitCommitOptionsController? { popover.contentViewController as? GitCommitOptionsController }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(title: "", symbol: nil, help: GitL10n.text("Commit options"), enabled: false,
                  style: .bordered, identifier: "git.commit.options")
        wantsLayer = true
        chevron.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 4))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.addLine(to: CGPoint(x: 10, y: 4))
        chevron.path = path
        chevron.fillColor = nil
        chevron.lineWidth = 1.4
        chevron.lineCap = .round
        chevron.lineJoin = .round
        layer?.addSublayer(chevron)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        onPress = { [weak self] in self?.toggle() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(enabled: Bool, repository: GitRepositoryIdentity?, entries: [NativeMenuEntry]) {
        if self.repository != repository || !enabled { close() }
        self.repository = repository
        self.entries = entries
        isEnabled = enabled
        optionsController?.update(entries)
        if let optionsController { popover.contentSize = optionsController.preferredContentSize }
        applyTheme(theme)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func applyTheme(_ theme: OMGNativeTheme) {
        super.applyTheme(theme)
        chevron.strokeColor = (isEnabled ? theme.foreground : theme.disabled).cgColor
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { close() }
        super.viewWillMove(toWindow: newWindow)
    }

    func toggle() {
        if isExpanded { close(restoringFocus: true); return }
        guard isEnabled, let window, !isHiddenOrHasHiddenAncestor else { return }
        previousResponder = window.firstResponder
        let controller = GitCommitOptionsController(entries: entries)
        controller.onCancel = { [weak self] in self?.close(restoringFocus: true) }
        controller.onSelect = { [weak self] index in self?.select(index) }
        controller.surface.bindTheme(to: window)
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        // The control is flipped: minY is the upper edge.
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        guard popover.isShown else { popover.contentViewController = nil; return }
        setExpanded(true)
        controller.focusFirstOption()
    }

    func close(restoringFocus: Bool = false) {
        restoreFocus = restoringFocus
        popover.close()
    }

    private func select(_ index: Int) {
        guard isExpanded, isEnabled, entries.indices.contains(index),
              case let .action(_, _, enabled, _, handler) = entries[index], enabled else { return }
        // Close before committing; the action is taken from the latest same-repository update.
        close(restoringFocus: true)
        handler()
    }

    func popoverDidClose(_ notification: Notification) {
        setExpanded(false)
        popover.contentViewController = nil
        if restoreFocus, let window, window.isKeyWindow {
            if let view = previousResponder as? NSView, view.window === window {
                window.makeFirstResponder(view)
            } else {
                window.makeFirstResponder(self)
            }
        }
        previousResponder = nil
        restoreFocus = false
    }

    private func setExpanded(_ expanded: Bool) {
        setPresentationActive(expanded)
        setAccessibilityValue(expanded ? "expanded" : "collapsed")
        let angle = expanded ? CGFloat.pi : 0
        let from = chevron.presentation()?.value(forKeyPath: "transform.rotation.z")
            ?? chevron.value(forKeyPath: "transform.rotation.z")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        chevron.removeAnimation(forKey: "disclosure")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = from
            animation.toValue = angle
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(animation, forKey: "disclosure")
        }
    }
}

final class GitCommitOptionsController: NSViewController {
    let surface = OMGNativeSurfaceView()
    private let stack = NSStackView()
    private var buttons: [(index: Int, button: GitCommitOptionControl)] = []
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
        surface.setAccessibilityIdentifier("git.commit.options.popup")
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
                    let button = GitCommitOptionControl()
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
            guard case let .action(title, symbol, enabled, _, _) = entries[index] else { continue }
            button.configure(title: title, symbol: symbol, help: nil, enabled: enabled,
                             style: .plain, identifier: "git.commit.option.\(index)")
            button.applyTheme(surface.theme)
        }
        let width = max(220, (buttons.map { $0.button.intrinsicContentSize.width }.max() ?? 0) + 14)
        preferredContentSize = NSSize(width: width, height: CGFloat(buttons.count) * 29 +
                                     CGFloat(stack.arrangedSubviews.count - buttons.count) +
                                     CGFloat(max(0, stack.arrangedSubviews.count - 1)) * 3 + 14)
        if let focused = view.window?.firstResponder as? GitCommitOptionControl, !focused.isEnabled {
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

private final class GitCommitOptionControl: NativeActionControl {
    var onNavigation: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onNavigation?(event) == true { return }
        if event.keyCode == 36 || event.keyCode == 76 { performClick(nil); return }
        super.keyDown(with: event)
    }
}
