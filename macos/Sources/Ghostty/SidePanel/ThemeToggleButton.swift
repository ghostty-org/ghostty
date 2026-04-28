import SwiftUI

struct ThemeToggleButton: View {
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    var body: some View {
        Button(action: { boardState.toggleTheme() }) {
            HStack(spacing: 6) {
                Image(systemName: boardState.isDarkMode ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 14))
                Text(boardState.isDarkMode ? "Light" : "Dark")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(colors.bgTertiary)
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(colors.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
