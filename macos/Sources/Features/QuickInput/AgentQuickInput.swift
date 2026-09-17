import AppKit
import SwiftUI

struct OMGKeyboardShortcut: Equatable {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control,
    ]

    static let defaultQuickInput = OMGKeyboardShortcut(
        key: "e",
        modifiers: [.command, .shift]
    )

    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init?(storageValue: String) {
        let parts = storageValue
            .lowercased()
            .split(separator: "+")
            .map(String.init)
        guard let key = parts.last, key.count == 1 else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1 else { return nil }
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        guard !modifiers.isEmpty else { return nil }
        self.init(key: characters, modifiers: modifiers)
    }

    var storageValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    var displayValue: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + key.uppercased()
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let shortcut = OMGKeyboardShortcut(event: event) else { return false }
        return shortcut == self
    }

    @MainActor
    func conflictingMenuItemTitle(in menu: NSMenu? = NSApp.mainMenu) -> String? {
        guard let menu else { return nil }
        for item in menu.items {
            let itemModifiers = item.keyEquivalentModifierMask
                .intersection(Self.relevantModifiers)
            if item.keyEquivalent.lowercased() == key,
               itemModifiers == modifiers,
               !item.title.isEmpty {
                return item.title
            }
            if let conflict = conflictingMenuItemTitle(in: item.submenu) {
                return conflict
            }
        }
        return nil
    }
}

enum AgentQuickInputEditingCommand: Equatable {
    case selectAll
    case copy
    case paste
    case cut
    case undo
    case redo

    static func resolve(
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        switch (key.lowercased(), modifiers) {
        case ("a", [.command]): .selectAll
        case ("c", [.command]): .copy
        case ("v", [.command]): .paste
        case ("x", [.command]): .cut
        case ("z", [.command]): .undo
        case ("z", [.command, .shift]): .redo
        default: nil
        }
    }
}

enum AgentQuickInputDispatchPolicy {
    static func shouldDispatch(
        previous: TabActivityState?,
        next: TabActivityState?
    ) -> Bool {
        previous != .done && next == .done
    }
}

enum AgentQuickInputPresentationPolicy {
    static func shouldPresentForAgentStart(
        previous: TabActivity?,
        next: TabActivity?,
        enabled: Bool,
        isAlreadyPresented: Bool,
        isTargetFocused: Bool
    ) -> Bool {
        enabled && previous == nil && next != nil &&
            !isAlreadyPresented && isTargetFocused
    }

    static func shouldPresentForAgentCompletion(
        previous: TabActivityState?,
        next: TabActivityState?,
        enabled: Bool,
        isAlreadyPresented: Bool,
        isTargetFocused: Bool
    ) -> Bool {
        enabled && previous != .done && next == .done &&
            !isAlreadyPresented && isTargetFocused
    }
}

enum AgentQuickInputFocusDirection: Equatable {
    case up
    case down
    case left
    case right

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        let relevant = modifiers.intersection([
            .command, .shift, .option, .control,
        ])
        guard relevant == [.command, .option] else { return nil }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: return nil
        }
    }

    var splitDirection: Ghostty.SplitFocusDirection {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

enum AgentQuickInputMetrics {
    static let minimumHeight: CGFloat = 140
    static let defaultHeight: CGFloat = 252
    static let maximumHeight: CGFloat = 480
    static let minimumTerminalHeight: CGFloat = 160
    static let queueLaneHeight: CGFloat = 60
    static let queueCardHeight: CGFloat = 44
    static let queueButtonHitSize: CGFloat = 30
    static let queueHoverDelayMilliseconds = 300
    static let queueMinimumWidth: CGFloat = 150
    static let queueMaximumWidth: CGFloat = 420
    static let queueHorizontalInset: CGFloat = 12
    static let editorLineSpacing: CGFloat = 3

    static func queueCardWidth(
        previewCount: Int,
        availableWidth: CGFloat
    ) -> CGFloat {
        let estimated = CGFloat(previewCount) * 7.5 + 110
        let available = max(1, availableWidth - queueHorizontalInset * 2)
        return min(
            max(estimated, queueMinimumWidth),
            min(queueMaximumWidth, available)
        )
    }

    static func reservedAccessoryHeight(
        dockHeight: CGFloat,
        isDockPresented: Bool,
        hasQueue: Bool
    ) -> CGFloat {
        let dock = isDockPresented
            ? dockHeight + TerminalShellStyle.dividerWidth
            : 0
        let queue = hasQueue
            ? queueLaneHeight + TerminalShellStyle.dividerWidth
            : 0
        return dock + queue
    }

}

enum AgentQuickInputMotion {
    static let terminalResizeDeferralDuration = 0.34
    static let dock = Animation.spring(
        response: terminalResizeDeferralDuration,
        dampingFraction: 0.92,
        blendDuration: 0.1
    )
    static let queue = Animation.spring(
        response: 0.42,
        dampingFraction: 0.72,
        blendDuration: 0.12
    )
}

struct AgentQuickInputQueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    var preview: String {
        let line = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}

struct AgentQuickInputPaneState: Equatable, Sendable {
    var draft = ""
    var queue: [AgentQuickInputQueueItem] = []
}

@MainActor
final class AgentQuickInputModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var targetSurfaceID: UUID?
    @Published var draft = "" {
        didSet {
            guard !isApplyingState, let targetSurfaceID else { return }
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = draft
            paneStates[targetSurfaceID] = state
        }
    }
    @Published private(set) var paneStates: [UUID: AgentQuickInputPaneState] = [:]
    @Published private(set) var statusMessage: String?
    @Published private(set) var dockHeight: CGFloat
    @Published private(set) var editingQueueItemID: UUID?
    @Published private(set) var focusRequestID = 0

    private var draftBeforeEditing: String?
    private var isApplyingState = false
    private var pendingDockHeight: CGFloat?
    private var dockResizeWorkItem: DispatchWorkItem?

    init(dockHeight: CGFloat? = nil) {
        self.dockHeight = dockHeight ?? CGFloat(
            OhMyGhosttySettings.shared.quickInputHeight
        )
    }

    var targetQueue: [AgentQuickInputQueueItem] {
        guard let targetSurfaceID else { return [] }
        return paneStates[targetSurfaceID]?.queue ?? []
    }

    var isEditingQueuedItem: Bool { editingQueueItemID != nil }

    func present(for surfaceID: UUID, requestFocus: Bool = true) {
        targetSurfaceID = surfaceID
        applyDraft(paneStates[surfaceID]?.draft ?? "")
        statusMessage = nil
        isPresented = true
        if requestFocus { self.requestFocus() }
    }

    func requestFocus() {
        guard isPresented else { return }
        focusRequestID &+= 1
    }

    func dismiss(preservingDraft: Bool = true) {
        if isEditingQueuedItem {
            cancelQueuedItemEdit()
            return
        }
        if !preservingDraft, let targetSurfaceID {
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = ""
            paneStates[targetSurfaceID] = state
            applyDraft("")
        }
        statusMessage = nil
        isPresented = false
    }

    @discardableResult
    func enqueueDraft() -> AgentQuickInputQueueItem? {
        guard let targetSurfaceID,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Enter a message first."
            return nil
        }
        let item = AgentQuickInputQueueItem(text: draft)
        var state = paneStates[targetSurfaceID] ?? .init()
        state.queue.append(item)
        state.draft = ""
        paneStates[targetSurfaceID] = state
        applyDraft("")
        statusMessage = "Queued message \(state.queue.count)."
        return item
    }

    func dequeue(for surfaceID: UUID) -> AgentQuickInputQueueItem? {
        guard var state = paneStates[surfaceID], !state.queue.isEmpty else { return nil }
        let item = state.queue.removeFirst()
        paneStates[surfaceID] = state
        return item
    }

    func removeQueuedItem(_ itemID: UUID, for surfaceID: UUID) {
        guard var state = paneStates[surfaceID] else { return }
        if editingQueueItemID == itemID, targetSurfaceID == surfaceID {
            cancelQueuedItemEdit()
        }
        state.queue.removeAll { $0.id == itemID }
        paneStates[surfaceID] = state
    }

    func editQueuedItem(_ itemID: UUID, for surfaceID: UUID) {
        guard let state = paneStates[surfaceID],
              let item = state.queue.first(where: { $0.id == itemID }) else {
            return
        }
        editingQueueItemID = itemID
        draftBeforeEditing = state.draft
        targetSurfaceID = surfaceID
        applyDraft(item.text)
        statusMessage = nil
        isPresented = true
    }

    @discardableResult
    func confirmQueuedItemEdit(moveToEnd: Bool) -> Bool {
        guard let surfaceID = targetSurfaceID,
              let itemID = editingQueueItemID,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var state = paneStates[surfaceID],
              let index = state.queue.firstIndex(where: { $0.id == itemID }) else {
            statusMessage = "Enter a message first."
            return false
        }
        let original = state.queue[index]
        let updated = AgentQuickInputQueueItem(
            id: original.id,
            text: draft,
            createdAt: original.createdAt
        )
        if moveToEnd {
            state.queue.remove(at: index)
            state.queue.append(updated)
        } else {
            state.queue[index] = updated
        }
        state.draft = draftBeforeEditing ?? ""
        paneStates[surfaceID] = state
        finishQueuedItemEdit(restoredDraft: state.draft)
        return true
    }

    func cancelQueuedItemEdit() {
        guard isEditingQueuedItem else { return }
        let restoredDraft = draftBeforeEditing ?? ""
        if let targetSurfaceID {
            var state = paneStates[targetSurfaceID] ?? .init()
            state.draft = restoredDraft
            paneStates[targetSurfaceID] = state
        }
        finishQueuedItemEdit(restoredDraft: restoredDraft)
    }

    func updateDockHeight(
        _ proposedHeight: CGFloat,
        availableHeight: CGFloat,
        persist: Bool
    ) {
        let maximum = min(
            AgentQuickInputMetrics.maximumHeight,
            max(
                AgentQuickInputMetrics.minimumHeight,
                availableHeight - AgentQuickInputMetrics.minimumTerminalHeight
            )
        )
        let height = min(
            max(proposedHeight, AgentQuickInputMetrics.minimumHeight),
            maximum
        )
        pendingDockHeight = height
        if persist {
            dockResizeWorkItem?.cancel()
            dockResizeWorkItem = nil
            applyPendingDockHeight()
            OhMyGhosttySettings.shared.quickInputHeight = Double(height)
            return
        }
        guard dockResizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.dockResizeWorkItem = nil
            self?.applyPendingDockHeight()
        }
        dockResizeWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func applyConfiguredDockHeight(_ height: CGFloat, availableHeight: CGFloat) {
        updateDockHeight(height, availableHeight: availableHeight, persist: false)
    }

    func state(for surfaceID: UUID) -> AgentQuickInputPaneState? {
        paneStates[surfaceID]
    }

    func restore(_ state: AgentQuickInputPaneState?, for surfaceID: UUID) {
        if let state, state != AgentQuickInputPaneState() {
            paneStates[surfaceID] = state
        } else {
            paneStates.removeValue(forKey: surfaceID)
        }
        if targetSurfaceID == surfaceID {
            applyDraft(state?.draft ?? "")
        }
    }

    func removeState(for surfaceID: UUID) {
        paneStates.removeValue(forKey: surfaceID)
        if targetSurfaceID == surfaceID {
            isPresented = false
            targetSurfaceID = nil
            editingQueueItemID = nil
            draftBeforeEditing = nil
            applyDraft("")
        }
    }

    func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    private func applyDraft(_ value: String) {
        isApplyingState = true
        draft = value
        isApplyingState = false
    }

    private func finishQueuedItemEdit(restoredDraft: String) {
        editingQueueItemID = nil
        draftBeforeEditing = nil
        applyDraft(restoredDraft)
        statusMessage = nil
        isPresented = false
    }

    private func applyPendingDockHeight() {
        guard let pendingDockHeight else { return }
        self.pendingDockHeight = nil
        guard dockHeight != pendingDockHeight else { return }
        dockHeight = pendingDockHeight
    }
}

struct OMGShortcutRecorder: NSViewRepresentable {
    @Binding var storageValue: String

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCapture = { shortcut in
            storageValue = shortcut.storageValue
        }
        button.updateShortcut(storageValue)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onCapture = { shortcut in
            storageValue = shortcut.storageValue
        }
        button.updateShortcut(storageValue)
    }
}

final class ShortcutRecorderButton: NSButton {
    var onCapture: ((OMGKeyboardShortcut) -> Void)?
    private var isRecording = false
    private var currentStorageValue = OMGKeyboardShortcut.defaultQuickInput.storageValue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func updateShortcut(_ storageValue: String) {
        currentStorageValue = storageValue
        guard !isRecording else { return }
        title = OMGKeyboardShortcut(storageValue: storageValue)?.displayValue
            ?? OMGKeyboardShortcut.defaultQuickInput.displayValue
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            updateShortcut(currentStorageValue)
            return
        }
        guard let shortcut = OMGKeyboardShortcut(event: event) else {
            NSSound.beep()
            return
        }
        isRecording = false
        title = shortcut.displayValue
        onCapture?(shortcut)
        window?.makeFirstResponder(nil)
    }
}

struct AgentQuickInputDock<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    let backgroundColor: Color
    let backgroundOpacity: Double
    let content: Content

    init(
        controller: TerminalController,
        model: AgentQuickInputModel,
        backgroundColor: Color,
        backgroundOpacity: Double,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.model = model
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content

            // Reserve the final accessory height immediately. Animating this
            // layout value resizes the PTY and terminal grid on every spring
            // frame, which becomes visibly expensive with deep scrollback.
            Color.clear
                .frame(height: reservedAccessoryHeight)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            // Animate only presentation properties in the overlay. The costly
            // terminal resize above happens once, while the dock and queue can
            // still move and fade smoothly on the compositor.
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    AgentQuickInputResizeHandle(
                        controller: controller,
                        model: model,
                        color: controller.sidebarDividerColor
                    )
                    AgentQuickInputComposer(
                        controller: controller,
                        model: model,
                        backgroundColor: backgroundColor,
                        backgroundOpacity: backgroundOpacity
                    )
                    .frame(height: model.dockHeight)
                }
                .frame(
                    height: model.dockHeight + TerminalShellStyle.dividerWidth,
                    alignment: .top
                )
                .offset(y: model.isPresented ? 0 : 18)
                .opacity(model.isPresented ? 1 : 0)
                .allowsHitTesting(model.isPresented)
                .accessibilityHidden(!model.isPresented)
                .animation(AgentQuickInputMotion.dock, value: model.isPresented)

                if let surfaceID = presentedQueueSurfaceID,
                   let queue = model.state(for: surfaceID)?.queue,
                   !queue.isEmpty {
                    AgentQuickInputQueueLane(
                        items: queue,
                        surfaceID: surfaceID,
                        model: model,
                        send: {
                            controller.sendQueuedQuickInput($0, from: surfaceID)
                        },
                        edit: {
                            controller.editQueuedQuickInput($0, from: surfaceID)
                        },
                        remove: {
                            controller.removeQueuedQuickInput($0, from: surfaceID)
                        },
                        dividerColor: controller.sidebarDividerColor,
                        backgroundColor: backgroundColor,
                        backgroundOpacity: backgroundOpacity,
                        chromeBackground: controller.terminalChromeBackground
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(AgentQuickInputMotion.queue, value: presentedQueueIDs)
        }
        .clipped()
    }

    private var presentedQueueSurfaceID: UUID? {
        if model.isPresented { return model.targetSurfaceID }
        return (controller.focusedSurface ?? controller.surfaceTree.first)?.id
    }

    private var presentedQueueIDs: [UUID] {
        guard let surfaceID = presentedQueueSurfaceID else { return [] }
        return model.state(for: surfaceID)?.queue.map(\.id) ?? []
    }

    private var reservedAccessoryHeight: CGFloat {
        AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: model.dockHeight,
            isDockPresented: model.isPresented,
            hasQueue: !presentedQueueIDs.isEmpty
        )
    }

}

private struct AgentQuickInputResizeHandle: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    let color: Color

    var body: some View {
        TerminalResizeBoundary(
            edge: .top,
            color: color,
            currentExtent: { model.dockHeight },
            resize: controller.updateQuickInputHeight,
            accessibilityLabel: "Resize Agent Quick Input"
        )
    }
}

private struct AgentQuickInputQueueLane: View {
    let items: [AgentQuickInputQueueItem]
    let surfaceID: UUID
    @ObservedObject var model: AgentQuickInputModel
    let send: (UUID) -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void
    let dividerColor: Color
    let backgroundColor: Color
    let backgroundOpacity: Double
    /// Effective chrome background (see `TerminalController.terminalChromeBackground`).
    let chromeBackground: Color

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(dividerColor)
                .frame(height: TerminalShellStyle.dividerWidth)
                .frame(maxWidth: .infinity)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(items) { item in
                                AgentQuickInputQueueCard(
                                    item: item,
                                    isEditing: model.editingQueueItemID == item.id,
                                    send: { send(item.id) },
                                    edit: { edit(item.id) },
                                    remove: { remove(item.id) }
                                )
                                .frame(width: AgentQuickInputMetrics.queueCardWidth(
                                    previewCount: item.preview.count,
                                    availableWidth: geometry.size.width
                                ))
                                .id(item.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing)
                                        .combined(with: .scale(
                                            scale: 0.9,
                                            anchor: .trailing
                                        ))
                                        .combined(with: .opacity),
                                    removal: .offset(y: 18)
                                        .combined(with: .scale(scale: 0.86))
                                        .combined(with: .opacity)
                                ))
                            }
                        }
                        .padding(.horizontal, AgentQuickInputMetrics.queueHorizontalInset)
                        .frame(minHeight: geometry.size.height)
                        .animation(
                            AgentQuickInputMotion.queue,
                            value: items.map(\.id)
                        )
                    }
                    .onAppear { scrollToNewest(using: proxy) }
                    .onChange(of: items.map(\.id)) { _ in
                        scrollToNewest(using: proxy)
                    }
                }
            }
            .frame(height: AgentQuickInputMetrics.queueLaneHeight)
        }
        .background(chromeBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued Agent Messages")
    }

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        guard let newest = items.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(AgentQuickInputMotion.queue) {
                proxy.scrollTo(newest, anchor: .trailing)
            }
        }
    }
}

private struct AgentQuickInputQueueCard: View {
    let item: AgentQuickInputQueueItem
    let isEditing: Bool
    let send: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    @State private var showFullMessage = false
    @State private var hoverPreviewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            Button(action: send) {
                Image(systemName: "arrow.turn.down.right")
                    .frame(
                        width: AgentQuickInputMetrics.queueButtonHitSize,
                        height: AgentQuickInputMetrics.queueButtonHitSize
                    )
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .help("Send now")
            .pointingHandCursor()

            Text(item.preview)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover(perform: updateHover)
                .popover(isPresented: $showFullMessage, arrowEdge: .bottom) {
                    ScrollView {
                        Text(hoverMessage)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(
                        minWidth: 240,
                        idealWidth: 360,
                        maxWidth: 440,
                        maxHeight: 260
                    )
                }

            Button(action: edit) {
                Image(systemName: "pencil")
                    .frame(
                        width: AgentQuickInputMetrics.queueButtonHitSize,
                        height: AgentQuickInputMetrics.queueButtonHitSize
                    )
                    .contentShape(Rectangle())
            }
            .help("Edit queued message")
            .pointingHandCursor()

            Button(action: remove) {
                Image(systemName: "trash")
                    .frame(
                        width: AgentQuickInputMetrics.queueButtonHitSize,
                        height: AgentQuickInputMetrics.queueButtonHitSize
                    )
                    .contentShape(Rectangle())
            }
            .help("Remove queued message")
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: AgentQuickInputMetrics.queueCardHeight)
        .background(.primary.opacity(hovered ? 0.12 : 0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isEditing ? Color.accentColor : .primary.opacity(0.24),
                    lineWidth: isEditing ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onDisappear { hoverPreviewTask?.cancel() }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var hoverMessage: String {
        guard item.text.count > 4_000 else { return item.text }
        return String(item.text.prefix(4_000)) + "\n…"
    }

    private func updateHover(_ inside: Bool) {
        hovered = inside
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        guard inside else {
            showFullMessage = false
            return
        }
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(
                AgentQuickInputMetrics.queueHoverDelayMilliseconds
            ))
            guard !Task.isCancelled else { return }
            showFullMessage = true
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private struct AgentQuickInputQueueDepthIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.full")
            Text("\(count)")
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) queued messages")
    }
}

private struct AgentQuickInputComposer: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var model: AgentQuickInputModel
    let backgroundColor: Color
    let backgroundOpacity: Double

    /// Effective chrome background (see `TerminalController.terminalChromeBackground`).
    private var chromeBackground: Color { controller.terminalChromeBackground }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentQuickInputTextEditor(
                text: $model.draft,
                placeholder: model.isEditingQueuedItem
                    ? "Edit queued message…"
                    : "Type here…",
                isPresented: model.isPresented,
                focusRequestID: model.focusRequestID,
                font: editorFont,
                onPasteImage: { file, completion in
                    guard let surfaceID = model.targetSurfaceID else {
                        completion(Ghostty.Shell.escape(file.path))
                        return
                    }
                    controller.resolveImagePastePath(
                        for: file,
                        surfaceID: surfaceID,
                        reportFailure: true,
                        completion: completion
                    )
                },
                onSend: controller.sendQuickInputDraft,
                onQueue: controller.queueQuickInputDraft,
                onCancel: controller.dismissQuickInput
            )
            .background(.clear)

            HStack(spacing: 12) {
                if model.isEditingQueuedItem {
                    Text("⌘↩ Save Edit")
                    Text("·")
                    Text("⌥⌘↩ Move to Queue End")
                    Text("·")
                    Text("Esc Cancel")
                } else {
                    Text("⌘↩ Send")
                    Text("·")
                    Text("⌥⌘↩ Queue")
                    Text("·")
                    Text("Esc Cancel")
                }
                if let statusMessage = model.statusMessage {
                    Text("·")
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !model.targetQueue.isEmpty {
                    AgentQuickInputQueueDepthIndicator(
                        count: model.targetQueue.count
                    )
                    .help("Queued messages")
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(chromeBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Quick Input")
    }

    private var editorFont: NSFont {
        let size = CGFloat(controller.ghostty.config.fontSize)
        if let family = controller.ghostty.config.fontFamily,
           let font = NSFontManager.shared.font(
               withFamily: family,
               traits: [],
               weight: 5,
               size: size
           ) ?? NSFont(name: family, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
