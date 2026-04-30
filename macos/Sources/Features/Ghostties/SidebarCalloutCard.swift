import SwiftUI

/// A dismissible inline callout card for the sidebar.
///
/// Visual treatment matches `PinMigrationNoticeBanner` — terracotta-tinted
/// rounded rect, icon column left-aligned with sidebar row icons, body text,
/// trailing X dismiss button with hover feedback.
///
/// Use for one-off contextual notices that the user can dismiss permanently.
struct SidebarCalloutCard: View {
    let iconName: String
    let message: String
    let onDismiss: () -> Void

    @State private var isCloseHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceLayout.waitingTerracotta)
                .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseHovered ? Color.primary.opacity(0.10) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { isCloseHovered = $0 }
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WorkspaceLayout.waitingTerracotta.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WorkspaceLayout.waitingTerracotta.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}
