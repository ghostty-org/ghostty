import SwiftUI

/// A single session row: name + ghost character status indicator.
///
/// Used by ProjectDisclosureRow to render sessions under each project.
/// Ghost character appears on the right, colored by session indicator state.
/// Supports bounce animation (processing), pulse animation (waiting), and reduce-motion.
struct SessionRow: View {
    let session: AgentSession
    let indicatorState: SessionIndicatorState
    var ghostCharacter: GhostCharacter?
    var isActive: Bool = false
    var isEditing: Bool = false
    /// Template name shown as a subtle badge when the session was launched with agent config.
    var agentTemplateName: String?
    @Binding var editingName: String
    var isRenameFocused: FocusState<Bool>.Binding
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isBouncing = false
    @State private var isPulsing = false
    @State private var isAttentionPulsing = false

    /// Whether animations should be suppressed (Reduce Motion preference).
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                TextField("Session name", text: $editingName)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .focused(isRenameFocused)
                    .onSubmit { onCommitRename() }
                    .onExitCommand { onCancelRename() }
                    .onChange(of: isRenameFocused.wrappedValue) { focused in
                        if !focused, isEditing { onCommitRename() }
                    }
            } else {
                Text(session.name)
                    .font(.system(size: 12, weight: indicatorState == .needsAttention ? .semibold : indicatorState == .waiting ? .medium : .regular))
                    .foregroundColor(sessionTextColor)
                    .lineLimit(1)

                // Agent template badge — hidden for now, revisit when more agent types exist.
                // if let agentTemplateName {
                //     HStack(spacing: 2) {
                //         Image(systemName: "cpu")
                //             .font(.system(size: 8))
                //         Text(agentTemplateName)
                //             .font(.system(size: 9, weight: .medium))
                //     }
                //     .foregroundColor(Color(.tertiaryLabelColor))
                //     .lineLimit(1)
                // }
            }

            Spacer()

            ghostIndicator
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .shadow(
            color: isActive ? Color.black.opacity(0.1) : .clear,
            radius: 2, x: 0, y: 1
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: indicatorState) { newState in
            updateAnimations(for: newState)
        }
        .onAppear {
            updateAnimations(for: indicatorState)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name)\(agentTemplateName.map { ", \($0) agent" } ?? ""), \(statusLabel)\(isActive ? ", active" : "")")
    }

    // MARK: - Ghost Indicator

    @ViewBuilder
    private var ghostIndicator: some View {
        let indicator = indicatorContent
            .offset(y: isBouncing && !reduceMotion ? -2 : 0)
            .animation(
                isBouncing && !reduceMotion
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                value: isBouncing
            )
            .opacity(pulseOpacity)
            .animation(pulseAnimation, value: isPulsing)
            .animation(pulseAnimation, value: isAttentionPulsing)

        indicator
    }

    /// The target opacity for pulse animations.
    /// Only one pulse type is active at a time (waiting or needsAttention).
    private var pulseOpacity: Double {
        if !reduceMotion && (isPulsing || isAttentionPulsing) {
            return 0.6
        }
        return 1.0
    }

    /// The animation to use for the active pulse, or nil when no pulse is active.
    private var pulseAnimation: Animation? {
        guard !reduceMotion else { return .default }
        if isAttentionPulsing {
            return .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        }
        if isPulsing {
            return .easeInOut(duration: 2.0).repeatForever(autoreverses: true)
        }
        return .default
    }

    @ViewBuilder
    private var indicatorContent: some View {
        if let ghost = ghostCharacter {
            GhostCharacterView(
                character: ghost,
                color: statusColor,
                style: indicatorState == .inactive ? .outline : .filled
            )
                .frame(width: 12, height: 12)
                .frame(width: 16, height: 16)
        } else {
            Text(String(session.name.prefix(1)).uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Colors

    private var statusColor: Color {
        switch indicatorState {
        case .processing:     return Color(nsColor: .systemGreen)
        case .waiting:        return WorkspaceLayout.waitingTerracotta
        case .needsAttention: return WorkspaceLayout.needsAttentionPurple
        case .longRunning:    return Color(nsColor: .systemYellow)
        case .idle:           return Color(.secondaryLabelColor)
        case .error:          return Color(nsColor: .systemRed)
        case .inactive:       return Color(.tertiaryLabelColor)
        }
    }

    private var sessionTextColor: Color {
        if isActive { return .primary }
        switch indicatorState {
        case .waiting, .needsAttention, .processing, .longRunning: return .primary
        case .idle:     return Color(.secondaryLabelColor)
        case .inactive: return Color(.tertiaryLabelColor)
        case .error:    return .primary
        }
    }

    private var rowBackground: Color {
        if isActive {
            return colorScheme == .dark
                ? WorkspaceLayout.activeRowDark
                : WorkspaceLayout.activeRowLight
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return .clear
    }

    private var statusLabel: String {
        switch indicatorState {
        case .processing:     return "processing"
        case .waiting:        return "waiting for input"
        case .needsAttention: return "needs your attention"
        case .longRunning:    return "running for a long time"
        case .idle:           return "idle"
        case .error:          return "error"
        case .inactive:       return "inactive"
        }
    }

    // MARK: - Animation Control

    private func updateAnimations(for state: SessionIndicatorState) {
        isBouncing = (state == .processing)
        isPulsing = (state == .waiting)
        isAttentionPulsing = (state == .needsAttention)
    }
}
