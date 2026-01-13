import SwiftUI

/// Shows current model, version, and working directory
struct StatusPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("STATUS")

            VStack(alignment: .leading, spacing: 6) {
                statusRow(label: "Model", value: state.model ?? "---")
                statusRow(label: "Version", value: state.version ?? "---")
                statusRow(label: "Path", value: shortenedPath(state.cwd))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(panelBackground)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 50, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func shortenedPath(_ path: String?) -> String {
        guard let path = path else { return "---" }
        // Replace home dir with ~
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
