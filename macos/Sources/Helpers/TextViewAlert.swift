import AppKit

/// An alert with NSTextView as its accessoryView
class TextViewAlert: NSAlert, NSAlertDelegate {
    var textView: NSTextView {
        guard let accessoryView else {
            preconditionFailure("accessoryView is nil")
        }
        guard
            let scrollView = accessoryView as? NSScrollView,
            let textView = scrollView.documentView as? NSTextView
        else {
            preconditionFailure("accessoryView doesn't contain a NSTextView")
        }
        return textView
    }

    /// When set, the alert will show help button and assign the delegate to itself
    var helpLink: String? {
        didSet {
            showsHelp = helpLink != nil
            delegate = helpLink != nil ? self : nil
        }
    }

    init(accessorySize: CGSize = .init(width: 480, height: 96)) {
        super.init()
        let accessoryView = NSTextView.scrollableTextView()
        accessoryView.frame = .init(origin: .zero, size: accessorySize)
        accessoryView.borderType = .bezelBorder
        // elasticity makes the background flashes on macOS 27
        accessoryView.verticalScrollElasticity = .none
        self.accessoryView = accessoryView

        textView.isEditable = false
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textView.textContainerInset = .init(width: 0, height: 6)
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        guard let url = helpLink.flatMap(URL.init(string:)) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}

extension TextViewAlert {
    func present() async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow {
            await beginSheetModal(for: window)
        } else {
            runModal()
        }
    }
}
