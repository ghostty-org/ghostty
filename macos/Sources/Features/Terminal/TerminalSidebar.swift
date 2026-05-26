import AppKit
import Combine
import SwiftUI

struct TerminalSidebarTheme: Equatable {
    let background: NSColor
    let foreground: NSColor
    let mutedForeground: NSColor
    let separator: NSColor
    let selectedBackground: NSColor
    let selectedForeground: NSColor
    let buttonTint: NSColor
    let status: NSColor
    let error: NSColor
    let colorScheme: ColorScheme

    static let fallback = TerminalSidebarTheme(
        backgroundColor: .windowBackgroundColor,
        foregroundColor: .labelColor)

    init(backgroundColor: NSColor, foregroundColor: NSColor) {
        let background = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let foreground = foregroundColor.usingColorSpace(.sRGB) ?? foregroundColor

        self.background = background
        self.foreground = foreground
        self.mutedForeground = foreground.withAlphaComponent(0.68)
        self.separator = foreground.withAlphaComponent(0.18)
        self.selectedBackground = foreground.withAlphaComponent(
            background.isLightColor ? 0.10 : 0.16)
        self.selectedForeground = foreground
        self.buttonTint = foreground.withAlphaComponent(0.72)
        self.status = NSColor(
            srgbRed: 59.0 / 255.0,
            green: 130.0 / 255.0,
            blue: 246.0 / 255.0,
            alpha: 1.0)
        self.error = .systemRed
        self.colorScheme = background.isLightColor ? .light : .dark
    }

    static func == (lhs: TerminalSidebarTheme, rhs: TerminalSidebarTheme) -> Bool {
        colorsEqual(lhs.background, rhs.background) &&
            colorsEqual(lhs.foreground, rhs.foreground) &&
            colorsEqual(lhs.mutedForeground, rhs.mutedForeground) &&
            colorsEqual(lhs.separator, rhs.separator) &&
            colorsEqual(lhs.selectedBackground, rhs.selectedBackground) &&
            colorsEqual(lhs.selectedForeground, rhs.selectedForeground) &&
            colorsEqual(lhs.buttonTint, rhs.buttonTint) &&
            colorsEqual(lhs.status, rhs.status) &&
            colorsEqual(lhs.error, rhs.error) &&
            lhs.colorScheme == rhs.colorScheme
    }

    private static func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhsRGB = lhs.usingColorSpace(.sRGB)
        let rhsRGB = rhs.usingColorSpace(.sRGB)

        guard let lhsRGB, let rhsRGB else {
            return lhs.isEqual(rhs)
        }

        return abs(lhsRGB.redComponent - rhsRGB.redComponent) < 0.001 &&
            abs(lhsRGB.greenComponent - rhsRGB.greenComponent) < 0.001 &&
            abs(lhsRGB.blueComponent - rhsRGB.blueComponent) < 0.001 &&
            abs(lhsRGB.alphaComponent - rhsRGB.alphaComponent) < 0.001
    }
}

/// Owns the sidebar view for one terminal window.
final class TerminalSidebarController {
    static let width: CGFloat = 176
    static let minWidth: CGFloat = 136
    static let maxWidth: CGFloat = 320
    private(set) static var preferredWidth: CGFloat = width

    private let model: TerminalSidebarModel
    let view: NSView

    init(hostWindow: TerminalWindow) {
        self.model = TerminalSidebarModel(hostWindow: hostWindow)
        let hostingView = NSHostingView(rootView: TerminalSidebarView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.view = hostingView
    }

    func sync() {
        model.syncSoon()
    }

    func updateTheme(_ theme: TerminalSidebarTheme) {
        model.updateTheme(theme)
    }

    static func setPreferredWidth(_ width: CGFloat) {
        preferredWidth = min(max(width, minWidth), maxWidth)
    }

    @discardableResult
    static func newSession(from hostWindow: NSWindow?) -> TerminalController? {
        guard let hostWindow else { return nil }

        let parentWindow = hostWindow.tabGroup?.selectedWindow ?? hostWindow
        guard let controller = parentWindow.windowController as? TerminalController
        else { return nil }

        return TerminalController.newTab(controller.ghostty, from: parentWindow)
    }
}

private final class TerminalSidebarModel: ObservableObject {
    @Published private(set) var sessions: [TerminalSidebarSession] = []
    @Published private(set) var theme: TerminalSidebarTheme = .fallback
    @Published var editingSessionID: ObjectIdentifier?

    private weak var hostWindow: TerminalWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupWindowsObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    init(hostWindow: TerminalWindow) {
        self.hostWindow = hostWindow

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: TerminalWindow.terminalTitleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.syncIfRelevant(window: notification.object as? NSWindow)
            },
            center.addObserver(
                forName: TerminalWindow.terminalSidebarMetadataDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.syncIfRelevant(window: notification.object as? NSWindow)
            },
            center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let controller = notification.object as? BaseTerminalController
                self?.syncIfRelevant(window: controller?.window)
            },
            center.addObserver(
                forName: TerminalWindow.terminalDidAwake,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.syncIfRelevant(window: notification.object as? NSWindow)
            },
            center.addObserver(
                forName: TerminalWindow.terminalWillCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.syncSoon()
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.syncIfRelevant(window: notification.object as? NSWindow)
            },
            center.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.syncIfRelevant(window: notification.object as? NSWindow)
            },
        ]

        sync()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
    }

    func syncSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
    }

    func sync() {
        guard let hostWindow else {
            sessions = []
            return
        }

        observeTabGroupIfNeeded(hostWindow.tabGroup)
        updateTheme(hostWindow.sidebarTheme)

        let windows = tabWindows()
        let selectedWindow = hostWindow.tabGroup?.selectedWindow ?? hostWindow
        sessions = windows.enumerated().compactMap { index, window in
            guard let controller = window.windowController as? BaseTerminalController else {
                return nil
            }
            let isSelected = window === selectedWindow

            return TerminalSidebarSession(
                id: ObjectIdentifier(window),
                index: index + 1,
                title: sidebarTitle(for: window),
                keyEquivalent: (window as? TerminalWindow)?.keyEquivalent,
                isSelected: isSelected,
                indicatorState: tabIndicatorState(controller, isSelected: isSelected),
                tabColor: (window as? TerminalWindow)?.tabColor.displayColor
            )
        }
    }

    func select(_ session: TerminalSidebarSession) {
        guard let window = window(for: session.id) else { return }
        if let tabGroup = window.tabGroup {
            tabGroup.selectedWindow = window
        }
        acknowledgeIndicatorIfNeeded(session, in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusTerminal(in: window)
        syncSoon()
    }

    func rename(_ session: TerminalSidebarSession) {
        editingSessionID = session.id
    }

    func commitRename(_ session: TerminalSidebarSession, title: String) {
        guard let window = window(for: session.id),
              let controller = window.windowController as? BaseTerminalController
        else {
            editingSessionID = nil
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.titleOverride = trimmedTitle.isEmpty ? nil : trimmedTitle
        editingSessionID = nil
        focusSelectedTerminal()
        syncSoon()
    }

    func cancelRename() {
        editingSessionID = nil
        focusSelectedTerminal()
    }

    func close(_ session: TerminalSidebarSession) {
        guard let controller = window(for: session.id)?.windowController as? TerminalController else {
            return
        }
        controller.closeTab(nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusSelectedTerminal()
        }
    }

    func newSession() {
        guard let hostWindow else { return }

        let newController = TerminalSidebarController.newSession(from: hostWindow)
        DispatchQueue.main.async { [weak self, weak newController] in
            guard let window = newController?.window else { return }
            self?.focusTerminal(in: window)
        }
    }

    func updateTheme(_ newTheme: TerminalSidebarTheme) {
        guard theme != newTheme else { return }
        theme = newTheme
    }

    private func syncIfRelevant(window: NSWindow?) {
        guard let window else {
            syncSoon()
            return
        }
        if tabWindows().contains(where: { $0 === window }) {
            syncSoon()
        }
    }

    private func observeTabGroupIfNeeded(_ tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup else { return }

        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
        tabGroupWindowsObservation = nil
        tabBarVisibleObservation = nil
        observedTabGroup = tabGroup

        guard let tabGroup else { return }

        tabGroupWindowsObservation = tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
            self?.syncSoon()
        }
        tabBarVisibleObservation = tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            self?.hostWindow?.hideNativeTabBarForSidebar()
            self?.syncSoon()
        }
    }

    private func tabWindows() -> [NSWindow] {
        guard let hostWindow else { return [] }
        return hostWindow.tabGroup?.windows ?? [hostWindow]
    }

    private func window(for id: ObjectIdentifier) -> NSWindow? {
        tabWindows().first { ObjectIdentifier($0) == id }
    }

    private func acknowledgeIndicatorIfNeeded(_ session: TerminalSidebarSession, in window: NSWindow) {
        guard session.indicatorState.isAttentionIndicator,
              let controller = window.windowController as? BaseTerminalController
        else {
            return
        }

        acknowledgeAttentionIndicators(in: controller)
    }

    private func acknowledgeAttentionIndicators(in controller: BaseTerminalController) {
        for surfaceView in controller.surfaceTree {
            surfaceView.acknowledgeSidebarIndicator()
        }
    }

    private func focusSelectedTerminal() {
        guard let hostWindow else { return }
        focusTerminal(in: hostWindow.tabGroup?.selectedWindow ?? hostWindow)
    }

    private func focusTerminal(in window: NSWindow) {
        if let tabGroup = window.tabGroup {
            tabGroup.selectedWindow = window
        }

        guard let controller = window.windowController as? BaseTerminalController,
              let focusedSurface = controller.focusedSurface
        else { return }

        controller.focusSurface(focusedSurface)
    }

    private func sidebarTitle(for window: NSWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    private func tabIndicatorState(
        _ controller: BaseTerminalController,
        isSelected: Bool = false
    ) -> TerminalSidebarStatusIndicatorState {
        var agentStates: [TerminalAgentActivityState] = []
        var hasTerminalProgress = false

        for surfaceView in controller.surfaceTree {
            agentStates.append(surfaceView.agentActivityState)

            if let progressReport = surfaceView.progressReport,
               progressReport.state != .remove,
               progressReport.state != .pause {
                hasTerminalProgress = true
            }
        }

        let state = TerminalSidebarStatusIndicatorState.derive(
            from: agentStates,
            hasTerminalProgress: hasTerminalProgress,
            hasTerminalBell: controller.bell
        )
        let visibleState = state.visibleState(isSelected: isSelected)

        if visibleState != state {
            acknowledgeAttentionIndicators(in: controller)
        }

        return visibleState
    }
}

private struct TerminalSidebarSession: Identifiable, Equatable {
    let id: ObjectIdentifier
    let index: Int
    let title: String
    let keyEquivalent: String?
    let isSelected: Bool
    let indicatorState: TerminalSidebarStatusIndicatorState
    let tabColor: NSColor?

    static func == (lhs: TerminalSidebarSession, rhs: TerminalSidebarSession) -> Bool {
        lhs.id == rhs.id &&
            lhs.index == rhs.index &&
            lhs.title == rhs.title &&
            lhs.keyEquivalent == rhs.keyEquivalent &&
            lhs.isSelected == rhs.isSelected &&
            lhs.indicatorState == rhs.indicatorState &&
            colorsEqual(lhs.tabColor, rhs.tabColor)
    }

    private static func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}

private struct TerminalSidebarView: View {
    @ObservedObject var model: TerminalSidebarModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.sessions) { session in
                        TerminalSidebarRow(
                            session: session,
                            theme: model.theme,
                            isEditing: model.editingSessionID == session.id,
                            onSelect: {
                                model.select(session)
                            },
                            onRename: {
                                model.rename(session)
                            },
                            onClose: {
                                model.close(session)
                            },
                            onCommitRename: { title in
                                model.commitRename(session, title: title)
                            },
                            onCancelRename: {
                                model.cancelRename()
                            }
                        )
                    }
                }
                .padding(.horizontal, 7)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(
            minWidth: TerminalSidebarController.minWidth,
            maxWidth: .infinity)
        .background(Color(nsColor: model.theme.background))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: model.theme.separator))
                .frame(width: 0.5)
        }
        .environment(\.colorScheme, model.theme.colorScheme)
        .accessibilityIdentifier("TerminalSidebar")
    }
}

private struct TerminalSidebarRow: View {
    let session: TerminalSidebarSession
    let theme: TerminalSidebarTheme
    let isEditing: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @FocusState private var isRenameFieldFocused: Bool
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            if let tabColor = session.tabColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: tabColor))
                    .frame(width: 3)
            } else {
                Color.clear
                    .frame(width: 3)
            }

            if isEditing {
                TextField("Session Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: theme.foreground))
                    .tint(Color(nsColor: theme.foreground))
                    .focused($isRenameFieldFocused)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: onCancelRename)
                    .accessibilityIdentifier("TerminalSidebarRenameField")
            } else {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color(nsColor: titleForeground))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 6)

                TerminalSidebarStatusIndicator(
                    state: session.indicatorState,
                    spinnerColor: theme.mutedForeground,
                    statusColor: theme.status,
                    errorColor: theme.error
                )
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if !isEditing {
                TerminalSidebarClickTarget(
                    onSelect: onSelect,
                    onRename: onRename,
                    onClose: onClose
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("TerminalSidebarSession-\(session.index)")
        .accessibilityAction {
            onSelect()
        }
        .onAppear {
            guard isEditing else { return }
            draftTitle = session.title
            DispatchQueue.main.async {
                isRenameFieldFocused = true
            }
        }
        .onChange(of: isEditing) { newValue in
            if newValue {
                draftTitle = session.title
                DispatchQueue.main.async {
                    isRenameFieldFocused = true
                }
            } else {
                isRenameFieldFocused = false
            }
        }
        .onChange(of: isRenameFieldFocused) { focused in
            guard isEditing, !focused else { return }
            commitRename()
        }
    }

    private var titleForeground: NSColor {
        session.isSelected ? theme.selectedForeground : theme.mutedForeground
    }

    private var accessibilityLabel: String {
        let base = "Session \(session.index): \(session.title)"
        guard let status = session.indicatorState.accessibilityDescription else { return base }
        return "\(base), \(status)"
    }

    @ViewBuilder
    private var rowBackground: some View {
        if session.isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: theme.selectedBackground))
        } else {
            Color.clear
        }
    }

    private func commitRename() {
        onCommitRename(draftTitle)
    }
}

private struct TerminalSidebarStatusIndicator: View {
    let state: TerminalSidebarStatusIndicatorState
    let spinnerColor: NSColor
    let statusColor: NSColor
    let errorColor: NSColor

    var body: some View {
        ZStack {
            switch state {
            case .spinner:
                TerminalSidebarRingSpinner(color: spinnerColor)
            case .bell:
                Circle()
                    .fill(Color(nsColor: statusColor))
                    .frame(width: 7, height: 7)
            case .error:
                Circle()
                    .fill(Color(nsColor: errorColor))
                    .frame(width: 7, height: 7)
            case .none:
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct TerminalSidebarRingSpinner: View {
    let color: NSColor

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color(nsColor: color).opacity(0.24),
                    style: StrokeStyle(lineWidth: 1.45)
                )

            Circle()
                .trim(from: 0.10, to: 0.82)
                .stroke(
                    Color(nsColor: color).opacity(0.68),
                    style: StrokeStyle(
                        lineWidth: 1.45,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(rotation))
                .animation(
                    .linear(duration: 0.95).repeatForever(autoreverses: false),
                    value: rotation
                )
        }
        .frame(width: 10, height: 10)
        .onAppear {
            rotation = 360
        }
    }
}

/// AppKit-backed hit target so single-click selection fires on mouseDown
/// while double-click rename remains available.
private struct TerminalSidebarClickTarget: NSViewRepresentable {
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> TerminalSidebarClickView {
        let view = TerminalSidebarClickView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TerminalSidebarClickView, context: Context) {
        view.onSelect = onSelect
        view.onRename = onRename
        view.onClose = onClose
    }
}

private final class TerminalSidebarClickView: NSView {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onClose: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()

        if event.clickCount >= 2 {
            onRename?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: "Rename Tab",
            action: #selector(renameSession),
            keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let close = NSMenuItem(
            title: "Close",
            action: #selector(closeSession),
            keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        return menu
    }

    @objc private func renameSession() {
        onRename?()
    }

    @objc private func closeSession() {
        onClose?()
    }
}
