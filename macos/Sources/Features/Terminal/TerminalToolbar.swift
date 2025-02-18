import Cocoa

// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.
class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    private let titleTextField = CenteredDynamicLabel(labelWithString: "👻 Ghostty")

    var titleText: String {
        get {
            titleTextField.stringValue
        }

        set {
            titleTextField.stringValue = newValue
        }
    }

    var titleFont: NSFont? {
        get {
            titleTextField.font
        }

        set {
            titleTextField.font = newValue
        }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)

        delegate = self
        centeredItemIdentifiers.insert(.titleText)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem

        switch itemIdentifier {
        case .titleText:
            item = NSToolbarItem(itemIdentifier: .titleText)
            item.view = self.titleTextField
            item.visibilityPriority = .user

            // This ensures the title text field doesn't disappear when shrinking the view
            self.titleTextField.translatesAutoresizingMaskIntoConstraints = false
            self.titleTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.titleTextField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            
            // Add constraints to the toolbar item's view
            NSLayoutConstraint.activate([
                // Set the height constraint to match the toolbar's height
                self.titleTextField.heightAnchor.constraint(equalToConstant: 22), // Adjust as needed
            ])
            
            item.isEnabled = true
        case .resetZoom:
            item = NSToolbarItem(itemIdentifier: .resetZoom)
        default:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.titleText, .flexibleSpace, .space, .resetZoom]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, two of the
        // built-in spacers plus the un-zoom button item seems to exactly match the space
        // on the left that's reserved for the window buttons.
        return [.flexibleSpace, .titleText, .flexibleSpace]
    }
}

/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
fileprivate class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Configure the text field
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
                
        // Use Auto Layout
        translatesAutoresizingMaskIntoConstraints = false
        
        // Set content hugging and compression resistance priorities
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    // Vertically center the text
    override func draw(_ dirtyRect: NSRect) {
        guard let attributedString = self.attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            super.draw(dirtyRect)
            return
        }
        
        let textSize = attributedString.size()
        
        let yOffset = (self.bounds.height - textSize.height) / 2 - 1 // -1 to center it better
        
        let centeredRect = NSRect(x: self.bounds.origin.x, y: self.bounds.origin.y + yOffset,
                                  width: self.bounds.width, height: textSize.height)
        
        attributedString.draw(in: centeredRect)
    }
}

extension NSToolbarItem.Identifier {
    static let resetZoom = NSToolbarItem.Identifier("ResetZoom")
    static let titleText = NSToolbarItem.Identifier("TitleText")
}
