import SwiftUI

/// Shows current model, version, and working directory
struct StatusPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("STATUS")

            VStack(alignment: .leading, spacing: 8) {
                statusRow(label: "Model", value: state.model ?? "---")
                statusRow(label: "Version", value: state.version ?? "---")
                statusRow(label: "Path", value: shortenedPath(state.cwd))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(panelBackground)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
