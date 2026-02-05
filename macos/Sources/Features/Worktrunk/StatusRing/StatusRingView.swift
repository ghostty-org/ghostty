import SwiftUI

/// Combined status indicator: inner dot (agent), outer ring (CI)
struct StatusRingView: View {
    let agentStatus: WorktreeAgentStatus?
    let ciState: CIState
    let prStatus: PRStatus?
    let onTap: () -> Void

    @Environment(\.statusRingTooltipState) private var tooltipState
    @State private var isHovering = false

    private let size: CGFloat = 14
    private let dotSize: CGFloat = 6
    private let ringWidth: CGFloat = 2

    var body: some View {
        ZStack {
            // Outer ring (CI status)
            if ciState != .none {
                ciRing
            }

            // Inner dot (agent status)
            agentDot
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: isHovering) { hovering in
                        if hovering {
                            let globalFrame = geo.frame(in: .global)
                            tooltipState?.scheduleShow(
                                anchor: globalFrame,
                                content: StatusRingTooltipContent(
                                    agentStatus: agentStatus,
                                    prStatus: prStatus,
                                    ciState: ciState
                                )
                            )
                        } else {
                            tooltipState?.hide()
                        }
                    }
            }
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onTap()
        }
    }

    // MARK: - CI Ring

    @ViewBuilder
    private var ciRing: some View {
        Circle()
            .stroke(ciColor, lineWidth: ringWidth)
            .frame(width: size, height: size)
            .overlay {
                if ciState == .pending {
                    PendingRingAnimation(color: ciColor, size: size, ringWidth: ringWidth)
                }
            }
    }

    private var ciColor: Color {
        switch ciState {
        case .passed: return .green
        case .failed: return .red
        case .pending: return .orange
        case .skipped, .cancelled: return .gray
        case .none: return .clear
        }
    }

    // MARK: - Agent Dot

    @ViewBuilder
    private var agentDot: some View {
        if let status = agentStatus {
            AgentDotView(status: status, size: dotSize)
        } else {
            // Empty/no agent - show faint dot
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: dotSize, height: dotSize)
        }
    }
}

// MARK: - Animated Agent Dot

private struct AgentDotView: View {
    let status: WorktreeAgentStatus
    let size: CGFloat

    @State private var isPulsing = false

    private var shouldPulse: Bool {
        status == .working || status == .permission
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(isPulsing ? 1.25 : 1.0)
            .animation(
                shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                if shouldPulse {
                    isPulsing = true
                }
            }
            .onChange(of: status) { newStatus in
                isPulsing = newStatus == .working || newStatus == .permission
            }
    }

    private var color: Color {
        switch status {
        case .working: return .orange
        case .permission: return .red
        case .review: return .green
        }
    }
}

// MARK: - Animated Pending Ring

private struct PendingRingAnimation: View {
    let color: Color
    let size: CGFloat
    let ringWidth: CGFloat

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(color.opacity(0.5), lineWidth: ringWidth)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
struct StatusRingView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                StatusRingView(
                    agentStatus: .working,
                    ciState: .pending,
                    prStatus: nil,
                    onTap: {}
                )

                StatusRingView(
                    agentStatus: .permission,
                    ciState: .failed,
                    prStatus: nil,
                    onTap: {}
                )

                StatusRingView(
                    agentStatus: .review,
                    ciState: .passed,
                    prStatus: nil,
                    onTap: {}
                )

                StatusRingView(
                    agentStatus: nil,
                    ciState: .passed,
                    prStatus: nil,
                    onTap: {}
                )

                StatusRingView(
                    agentStatus: nil,
                    ciState: .none,
                    prStatus: nil,
                    onTap: {}
                )
            }
        }
        .padding()
    }
}
#endif
