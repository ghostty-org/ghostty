import SwiftUI

struct SessionModalView: View {
    @Binding var isPresented: Bool
    let taskId: UUID
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    @State private var title = ""
    @State private var isWorkTree = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Spacer()
                Button(action: { isPresented = false }) {
                    Text("×")
                        .font(.system(size: 18))
                        .foregroundColor(colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session Title")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    TextField("Enter session title", text: $title)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(colors.inputBg)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(colors.inputBorder, lineWidth: 1)
                        )
                }

                // Worktree toggle
                HStack {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colors.worktree.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 18))
                                .foregroundColor(colors.worktree)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("WorkTree")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(colors.textPrimary)
                            Text("Use git worktree")
                                .font(.system(size: 11))
                                .foregroundColor(colors.textMuted)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $isWorkTree)
                        .toggleStyle(SwitchToggleStyle(tint: colors.accent))
                        .labelsHidden()
                }
                .padding(12)
                .background(colors.bgTertiary)
                .cornerRadius(8)
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(action: { isPresented = false }) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colors.btnGradientEnd)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(colors.borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: saveSession) {
                    Text("Add")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(colors.accent)
                        .cornerRadius(6)
                        .shadow(color: colors.accent.opacity(0.3), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(colors.modalFooterBg)
        }
        .frame(width: 400)
        .background(colors.modalBg)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 25, y: 10)
    }

    private func saveSession() {
        guard !title.isEmpty else { return }
        let session = Session(title: title, isWorkTree: isWorkTree)
        boardState.addSession(to: taskId, session: session)
        isPresented = false
    }
}
