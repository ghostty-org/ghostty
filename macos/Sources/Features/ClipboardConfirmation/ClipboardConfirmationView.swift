import SwiftUI

/// This delegate is notified of the completion result of the clipboard confirmation dialog.
protocol ClipboardConfirmationViewDelegate: AnyObject {
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest)
}

/// The SwiftUI view for showing a clipboard confirmation dialog.
struct ClipboardConfirmationView: View {
    enum Action : String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardRequest) -> String {
            switch (action, reason) {
            case (.cancel, .paste):
                return "Cancel"
            case (.cancel, .osc_52_read), (.cancel, .osc_52_write):
                return "Deny"
            case (.confirm, .paste):
                return "Paste"
            case (.confirm, .osc_52_read), (.confirm, .osc_52_write):
                return "Allow"
            }
        }
    }

    /// The contents of the paste.
    let contents: String

    /// The type of the clipboard request
    let request: Ghostty.ClipboardRequest

    /// Optional delegate to get results. If this is nil, then this view will never close on its own.
    weak var delegate: ClipboardConfirmationViewDelegate? = nil

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 42))
                    .padding()
                    .frame(alignment: .center)

                Text(request.text())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            TextEditor(text: .constant(contents))
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
                .padding(.all, 4)

            HStack {
                Spacer()
                Button(Action.text(.cancel, request)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(Action.text(.confirm, request)) { onPaste() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom)
        }
    }

    private func onCancel() {
        delegate?.clipboardConfirmationComplete(.cancel, request)
    }

    private func onPaste() {
        delegate?.clipboardConfirmationComplete(.confirm, request)
    }
}
