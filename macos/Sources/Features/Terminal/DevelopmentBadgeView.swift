import SwiftUI

/// The `DEV` mark in the titlebar's right end.
///
/// In the window's chrome rather than in the sidebar, because that is what it
/// is about: this binary came out of a local `zig build`, whichever panel
/// happens to be showing. The sidebar was also the wrong shape for it — a
/// strip already holding three tabs that wanted the width.
struct DevelopmentBadgeView: View {
    var body: some View {
        Text(DevelopmentBuild.label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
            .padding(.trailing, 8)
            .help("This is a local development build, not the installed app.")
            .accessibilityLabel("Development build")
    }
}
