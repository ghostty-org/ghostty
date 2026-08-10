import SwiftUI

/// The environment mark at the titlebar's right end.
///
/// In the window's chrome rather than in the sidebar, because that is what it
/// is about: this binary came out of a local `zig build`, whichever panel
/// happens to be showing.
///
/// The colour is the convention, inverted on purpose — green says "go ahead
/// and break it", amber says "look before you touch", red says "full
/// attention". A development build is the one you are *meant* to be careless
/// with, so it gets the calm colour.
struct DevelopmentBadgeView: View {
    var environment: DevelopmentBuild.Environment = DevelopmentBuild.environment

    private var tint: Color {
        switch environment {
        case .development: return .green
        case .staging: return .orange
        case .production: return .red
        }
    }

    var body: some View {
        Text(environment.label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(0.42), lineWidth: 1)
            )
            // Centred against the title rather than sitting on the top edge,
            // and held off the window's corner. The accessory is given the
            // titlebar's full height, so without this the badge lands at the
            // top of that box instead of level with the text beside it.
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 10)
            .help("This is a local development build, not the installed app.")
            .accessibilityLabel("\(environment.label) build")
    }
}
