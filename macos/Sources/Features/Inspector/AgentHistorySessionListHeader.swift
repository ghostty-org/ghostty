import AppKit
import SwiftUI

struct AgentHistorySessionListHeader: NSViewControllerRepresentable {
    let title: String
    let isRemote: Bool
    let isLoading: Bool
    let strings: AgentHistoryStrings
    let refresh: () -> Void

    func makeNSViewController(context: Context) -> AgentHistorySessionListHeaderController {
        AgentHistorySessionListHeaderController()
    }

    func updateNSViewController(_ controller: AgentHistorySessionListHeaderController, context: Context) {
        controller.update(self)
    }
}

@MainActor
final class AgentHistorySessionListHeaderController: NSViewController {
    private let row = NSStackView()
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let refreshButton = NativeActionControl()
    private let progress = NSProgressIndicator()
    private var snapshot: AgentHistorySessionListHeader?
    var refreshButtonForTesting: NSButton { refreshButton }
    var titleFieldForTesting: NSTextField { titleField }

    override func loadView() {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        icon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.bezelStyle = .rounded
        refreshButton.setButtonType(.momentaryPushIn)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        row.addArrangedSubview(icon)
        row.addArrangedSubview(titleField)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(progress)
        row.addArrangedSubview(refreshButton)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),
            refreshButton.widthAnchor.constraint(equalToConstant: 28),
            refreshButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        let surface = OMGNativeSurfaceView()
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            row.topAnchor.constraint(equalTo: surface.topAnchor),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        surface.onThemeChange = { [weak self] theme in
            self?.titleField.textColor = theme.foreground
            self?.icon.contentTintColor = theme.secondary
        }
        view = surface
    }

    func update(_ next: AgentHistorySessionListHeader) {
        _ = view
        snapshot = next
        icon.image = NSImage(
            systemSymbolName: next.isRemote ? "cloud" : "clock.arrow.circlepath",
            accessibilityDescription: nil
        )
        titleField.stringValue = next.title
        progress.isHidden = !next.isLoading
        if next.isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        refreshButton.configure(title: "", symbol: "arrow.clockwise", help: next.strings.refresh,
                                enabled: !next.isLoading, style: .plain, identifier: "history.refresh")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: next.strings.refresh)
        refreshButton.toolTip = next.strings.refresh
        refreshButton.setAccessibilityLabel(next.strings.refresh)
        refreshButton.setAccessibilityValue(next.isLoading ? next.strings.loading : "")
    }

    @objc private func refresh() { snapshot?.refresh() }
}
