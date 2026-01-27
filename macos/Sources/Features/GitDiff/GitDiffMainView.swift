import AppKit
import SwiftUI

struct GitDiffMainView: View {
    @ObservedObject var state: GitDiffSidebarState

    var body: some View {
        content
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }

    @ViewBuilder
    private var content: some View {
        if state.isDiffLoading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
        } else if let diffError = state.diffError, !diffError.isEmpty {
            Text(diffError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.diffText.isEmpty {
            Text("No diff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DiffTextViewRepresentable(
                text: state.diffText,
                filePath: state.selectedPath
            )
        }
    }
}

private struct DiffTextViewRepresentable: NSViewRepresentable {
    let text: String
    let filePath: String?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DiffTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? DiffTextView else { return }
        let key = DiffTextView.RenderKey(text: text, filePath: filePath)
        if textView.lastRenderKey == key { return }
        textView.lastRenderKey = key

        DispatchQueue.global(qos: .userInitiated).async {
            let highlighted = DiffSyntaxHighlighter.highlightedDiff(text: text, filePath: filePath)
            DispatchQueue.main.async {
                textView.textStorage?.setAttributedString(highlighted)
            }
        }
    }
}

private final class DiffTextView: NSTextView {
    struct RenderKey: Equatable {
        let textHash: Int
        let filePath: String?

        init(text: String, filePath: String?) {
            self.textHash = text.hashValue
            self.filePath = filePath
        }
    }

    var lastRenderKey: RenderKey?
}
