import SwiftUI

#if canImport(AppKit)

struct SurfaceTitleBar: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    private var displayTitle: String {
        if surfaceView.isUserSetTitle {
            return surfaceView.title
        }
        return URL(fileURLWithPath: surfaceView.pwd ?? "/").lastPathComponent
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused { commit() }
                    }
                    .padding(.horizontal, 8)
            } else {
                Text(displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) { startEditing() }
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
    }

    private func startEditing() {
        editText = surfaceView.isUserSetTitle ? surfaceView.title : ""
        isEditing = true
        fieldFocused = true
    }

    private func commit() {
        surfaceView.setPinnedTitle(editText.isEmpty ? nil : editText)
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }
}

#endif
