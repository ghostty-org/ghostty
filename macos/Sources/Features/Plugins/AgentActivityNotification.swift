import Foundation
import UserNotifications

enum AgentActivityNotification {
    enum Kind: Equatable {
        case completed
        case attention
    }

    static func kind(previous: TabActivity?, next: TabActivity?,
                     completionEnabled: Bool, attentionEnabled: Bool) -> Kind? {
        guard let previous, let next, previous.source != next.source || previous.state != next.state else { return nil }
        switch next.state {
        case .done: return completionEnabled ? .completed : nil
        case .needsAttention: return attentionEnabled ? .attention : nil
        default: return nil
        }
    }

    @MainActor
    static func deliver(previous: TabActivity?, next: TabActivity?, surface: Ghostty.SurfaceView) {
        guard !OMGApplicationEnvironment.isRunningTests else { return }
        let settings = OhMyGhosttySettings.shared
        guard let kind = kind(previous: previous, next: next, completionEnabled: settings.notifyTaskComplete,
                              attentionEnabled: settings.notifyAttention), let next else { return }
        let strings = SettingsStrings(language: settings.language)
        let action = kind == .completed ? strings.notifyTaskCompleteLabel : strings.notifyAttentionLabel
        let title = "\(next.label ?? next.source) · \(action)"
        let body = next.message ?? ""
        let sound = settings.notificationSound
        Task { @MainActor [weak surface] in
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard granted, let surface else { return }
                surface.showUserNotification(title: title, body: body, playSound: sound)
            } catch {
                Ghostty.logger.error("Agent notification authorization failed")
            }
        }
    }
}
