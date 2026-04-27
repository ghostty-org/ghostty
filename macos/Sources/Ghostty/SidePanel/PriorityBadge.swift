import SwiftUI

struct PriorityBadge: View {
    let priority: Priority
    @Environment(\.themeColors) var colors

    var body: some View {
        Text(priority.displayName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundColor(textColor)
            .cornerRadius(4)
    }

    private var backgroundColor: Color {
        switch priority {
        case .p0: return colors.danger.opacity(0.2)
        case .p1: return colors.warning.opacity(0.2)
        case .p2: return Color.yellow.opacity(0.2)
        case .p3: return colors.bgTertiary
        }
    }

    private var textColor: Color {
        switch priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return Color(hex: "b38600")
        case .p3: return colors.textMuted
        }
    }
}
