import SwiftUI

/// First-launch welcome sheet. Presented once, on fresh install, over the
/// project-first sidebar. Dismissed via the "Get started" button, after which
/// `ghostties.hasSeenOnboarding` is set so it never appears again.
@MainActor
struct OnboardingSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use the sidebar to manage multiple repos, agent threads, and terminals — all in one window.")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)

                    Text("Built on top of Ghostty.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 380, height: 240)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Ghostties")
                .font(.system(size: 14, weight: .semibold))

            Text("Ghostty + Ghostty + Ghostty")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get started") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
