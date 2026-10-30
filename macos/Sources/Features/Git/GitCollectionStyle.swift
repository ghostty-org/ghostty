import AppKit
import SwiftUI

extension NSColor {
    /// Keep system semantic colors dynamic when applying opacity. Resolving
    /// labelColor while building a dark view must not freeze it for light mode.
    func gitOpacity(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = self
            appearance.performAsCurrentDrawingAppearance {
                result = (self.usingColorSpace(.deviceRGB) ?? self).withAlphaComponent(alpha)
            }
            return result
        }
    }
}

struct GitCollectionColors: Equatable {
    var text = NSColor.labelColor
    var accent = NSColor.controlAccentColor
    var selection = NSColor.selectedContentBackgroundColor
    var background = NSColor.windowBackgroundColor
    var added = GitDiffChangeKind.added.color
    var modified = GitDiffChangeKind.modified.color
    var deleted = GitDiffChangeKind.deleted.color
    var renamed = GitDiffChangeKind.renamed.color
    var secondary: NSColor { text.gitOpacity(0.62) }
    var separator: NSColor { text.gitOpacity(0.13) }
    var hover: NSColor { text.gitOpacity(0.055) }

    init() {}
    init(nativeTheme: OMGNativeTheme) {
        text = nativeTheme.foreground
        background = nativeTheme.background
        accent = nativeTheme.accent
        selection = nativeTheme.selectedFill
    }
    init(config: Ghostty.Config, background: NSColor) {
        let theme = config.editorTheme(background: background)
        text = theme.text.color
        accent = theme.commands.color
        selection = theme.selection
        self.background = background
        added = theme.strings.color
        modified = theme.numbers.color
        deleted = theme.variables.color
        renamed = theme.commands.color
    }

    func status(_ file: GitDiffFile) -> NSColor {
        guard !file.isUntracked else { return secondary }
        let color: NSColor = switch file.kind {
        case .added, .copied: added
        case .modified, .typeChanged: modified
        case .deleted, .unmerged: deleted
        case .renamed: renamed
        case .unknown: secondary
        }
        return color.withAlphaComponent(0.75)
    }
}

private struct GitCollectionColorsKey: EnvironmentKey {
    static let defaultValue = GitCollectionColors()
}
extension EnvironmentValues {
    var gitCollectionColors: GitCollectionColors {
        get { self[GitCollectionColorsKey.self] }
        set { self[GitCollectionColorsKey.self] = newValue }
    }
}

/// One compact mode control is used in Changes, Branches and the History picker.
struct GitCollectionModePicker: NSViewRepresentable {
    @Binding var mode: GitCollectionMode
    func makeNSView(context: Context) -> GitPopoverSegments { GitPopoverSegments() }
    func updateNSView(_ control: GitPopoverSegments, context: Context) {
        control.setAccessibilityIdentifier("git.collection.mode")
        control.configure(segments: GitCollectionMode.allCases.map {
            GitPopoverSegment(id: $0.rawValue, title: "", symbol: $0.symbol, accessibilityLabel: $0.title)
        }, selectedID: mode.rawValue, colors: .init(nativeTheme: .resolve(for: control)), widths: [26, 26])
        control.onSelect = { if let next = GitCollectionMode(rawValue: $0) { mode = next } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitPopoverSegments, context: Context) -> CGSize? {
        CGSize(width: 54, height: 26)
    }
}

/// Shared by editor diff modes and every Git collection mode picker.
struct GitToolbarSegmentedStyle: ViewModifier {
    let colors: GitCollectionColors

    func body(content: Content) -> some View {
        content
            .padding(1)
            .background(Color(colors.text).opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color(colors.text).opacity(0.18), lineWidth: 0.75))
    }
}

struct GitToolbarButtonStyle: ButtonStyle {
    let colors: GitCollectionColors
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        GitModeButtonBody(configuration: configuration, colors: colors, selected: selected)
    }
    private struct GitModeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let colors: GitCollectionColors
        let selected: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 0.75))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
        private var background: Color {
            if selected {
                return Color(colors.accent).opacity(configuration.isPressed ? 0.26 : hover ? 0.22 : 0.13)
            }
            return Color(colors.text).opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0)
        }
        private var border: Color {
            if selected {
                return Color(colors.accent).opacity(configuration.isPressed ? 0.62 : hover ? 0.55 : 0.3)
            }
            return Color(colors.text).opacity(configuration.isPressed ? 0.52 : hover ? 0.4 : 0)
        }
    }
}

final class GitStageCheckbox: NSButton {
    private var hovered = false
    private var colors = GitCollectionColors()
    private var tracking: NSTrackingArea?
    var activate: () -> Void = {}
    var actionSymbol: String? { didSet { updateImage() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        allowsMixedState = true
        setAccessibilityRole(.checkBox)
        target = self
        action = #selector(clicked)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(checked: Bool, enabled: Bool, colors: GitCollectionColors) {
        configure(state: checked ? .on : .off, enabled: enabled, colors: colors)
    }
    func configure(state: NSControl.StateValue, enabled: Bool, colors: GitCollectionColors) {
        self.colors = colors
        self.state = state
        hovered = false
        isEnabled = enabled
        setAccessibilityValue(NSNumber(value: state.rawValue))
        updateImage()
    }
    private func updateImage() {
        image = NSImage(systemSymbolName: actionSymbol ?? (state == .mixed ? "minus.square.fill" : state == .on ? "checkmark.square.fill" : "square"), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = state != .off || (hovered && isEnabled) ? colors.accent : colors.secondary
        alphaValue = isEnabled ? 1 : 0.4
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateImage() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateImage() }
    @objc private func clicked() { if isEnabled { activate() } }
}

final class GitCollectionRowView: NSTableRowView {
    var colors = GitCollectionColors() { didSet { needsDisplay = true } }
    var showsHighlight = true
    var isPointerHovered = false { didSet { if oldValue != isPointerHovered { needsDisplay = true } } }
    var isMultipleSelection = false { didSet { if oldValue != isMultipleSelection { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard showsHighlight, isPointerHovered, !isSelected else { return }
        colors.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 3, yRadius: 3).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard showsHighlight else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
        colors.accent.withAlphaComponent(isMultipleSelection ? 0.22 : 0.15).setFill()
        shape.fill()
        if isMultipleSelection {
            colors.accent.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
    }
}
