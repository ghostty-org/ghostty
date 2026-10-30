import AppKit
import QuartzCore
import SwiftUI

/// Shared footprint keeps single and multi-pane titles aligned within a 28pt row.
enum TabIconMetrics {
    static let footprint: CGFloat = 26
    static let composition: CGFloat = 22
    static let pane: CGFloat = composition / 2
    static func singleLogo(_ preferred: CGFloat) -> CGFloat { min(18, max(17, preferred)) }
}

enum AgentLogoStyle {
    static func color(_ activity: TabActivity) -> Color {
        switch activity.state {
        case .idle: return .clear
        case .working: return activity.phase == .background ? .purple : .accentColor
        case .done: return Color(nsColor: NSColor.systemGreen.blended(withFraction: 0.15, of: .black) ?? .systemGreen)
        case .needsAttention: return .orange
        case .error: return .red
        }
    }

    static func tintStrength(state: TabActivityState?, focused: Bool) -> Double {
        switch state {
        case .done, .working, .needsAttention, .error: return 1
        case .idle, nil: return focused ? 1 : 0
        }
    }

    /// Starts at full brightness, avoiding a random phase jump on entering work.
    static func breath(at time: TimeInterval, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : (1 + cos(max(0, time) * 2 * .pi / 1.8)) / 2
    }

    static func logoOpacity(breath: Double) -> Double { 0.30 + 0.70 * breath }

    static func animates(state: TabActivityState?, visible: Bool, reduceMotion: Bool) -> Bool {
        state == .working && visible && !reduceMotion
    }
}

/// Idempotent state changes do not restart the breath. The model opacity stays
/// fully bright so removing an animation never leaves a dim idle/done logo.
@MainActor
enum AgentLogoLayerBreath {
    static let key = "omg.agentLogo.breath"

    static func setRunning(_ running: Bool, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        if running {
            if layer.animation(forKey: key) == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1.0
                animation.toValue = AgentLogoStyle.logoOpacity(breath: 0)
                animation.duration = 0.9
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: key)
            }
        } else {
            layer.removeAnimation(forKey: key)
        }
        CATransaction.commit()
    }
}

/// Controller-owned recency survives sidebar reconstruction and focus moving to another slot.
struct TabPaneFocusHistory {
    private(set) var recent: [UUID] = []

    mutating func record(_ id: UUID?, liveIDs: Set<UUID>) {
        recent.removeAll { !liveIDs.contains($0) || $0 == id }
        if let id, liveIDs.contains(id) { recent.insert(id, at: 0) }
    }

    func representative(in ids: [UUID], focused: UUID?) -> UUID? {
        if let focused, ids.contains(focused) { return focused }
        return recent.first(where: { ids.contains($0) }) ?? ids.first
    }
}
