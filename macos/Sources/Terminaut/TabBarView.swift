import SwiftUI

/// Tab bar for switching between active Claude Code sessions
struct TabBarView: View {
    let sessions: [TerminautCoordinator.Session]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    TabItemView(
                        project: session.project,
                        isSelected: index == selectedIndex,
                        hasActivity: session.hasActivity,
                        onSelect: { onSelect(index) },
                        onClose: { onClose(index) }
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 36)
        .background(Color.black.opacity(0.95))
    }
}

/// Individual tab item
struct TabItemView: View {
    let project: Project
    let isSelected: Bool
    let hasActivity: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false

    // Fixed width for consistent tab sizing
    private let tabWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 8) {
            // Activity indicator (green dot) - always reserve space
            Circle()
                .fill(hasActivity ? Color.green : Color.clear)
                .frame(width: 6, height: 6)

            // Project name - truncate to fit fixed width
            Text(project.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isSelected ? .white : .gray)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Close button - always present but visibility controlled by opacity
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
            .background(Color.white.opacity(0.1))
            .cornerRadius(4)
            .opacity(isSelected || isHovered ? 1 : 0)
        }
        .frame(width: tabWidth)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.cyan.opacity(0.2) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    VStack {
        TabBarView(
            sessions: [
                TerminautCoordinator.Session(project: Project(name: "terminaut-ghostty", path: "/Users/pete/Projects/terminaut-ghostty")),
                TerminautCoordinator.Session(project: Project(name: "captain32-api", path: "/Users/pete/Projects/captain32-api")),
                TerminautCoordinator.Session(project: Project(name: "mr-tools", path: "/Users/pete/Projects/mr-tools"))
            ],
            selectedIndex: 0,
            onSelect: { index in print("Selected tab \(index)") },
            onClose: { index in print("Close tab \(index)") }
        )

        Spacer()
    }
    .frame(width: 800, height: 200)
    .background(Color.black)
}
