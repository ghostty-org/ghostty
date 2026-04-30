import SwiftUI

/// Small "PREVIEW" pill used in Tasks zone headers to signal early-access status.
struct PreviewBadge: View {
    var body: some View {
        Text("Preview".uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkspaceLayout.waitingTerracotta, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
