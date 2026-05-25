import SwiftUI

#if canImport(AppKit)

struct SurfaceTitleBar: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isCancelling = false
    @FocusState private var fieldFocused: Bool

    private var displayTitle: String {
        if surfaceView.isUserSetTitle {
            return surfaceView.title
        }
        if let pwd = surfaceView.pwd, !pwd.isEmpty, pwd != "/" {
            return URL(fileURLWithPath: pwd).lastPathComponent
        }
        return surfaceView.title.isEmpty ? "terminal" : surfaceView.title
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
                    .onSubmit { fieldFocused = false }
                    .onExitCommand { isCancelling = true; fieldFocused = false }
                    .onChange(of: fieldFocused) { focused in
                        guard !focused else { return }
                        if isCancelling {
                            isCancelling = false
                            cancel()
                        } else {
                            commit()
                        }
                    }
                    .onAppear { fieldFocused = true }
                    .padding(.horizontal, 8)
                    .font(.system(size: 11))
            } else {
                Text(displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityLabel("Pane title: \(displayTitle)")
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isEditing ? "Title editor" : "Pane title: \(displayTitle)")
    }

    private func startEditing() {
        editText = surfaceView.isUserSetTitle ? surfaceView.title : ""
        isCancelling = false
        isEditing = true
        // Focus is set via .onAppear on the TextField
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
