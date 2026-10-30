import AppKit
import SwiftUI

/// A native menu picker shared by local and SSH-backed settings flows.
struct SSHHostPicker: NSViewRepresentable {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        let status: String?
        let symbol: String

        init(id: String, title: String, detail: String? = nil, status: String? = nil, symbol: String = "network") {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
            self.symbol = symbol
        }

        var displayTitle: String {
            [title, detail, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    let items: [Item]
    @Binding var selection: String
    var enabled = true
    var accessibilityLabel = "SSH Host"
    var placeholderTitle = "Select an SSH host…"
    var height: CGFloat = OMGSettingsControlMetrics.height

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectItem(_:))
        button.menu?.autoenablesItems = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityRole(.popUpButton)
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled && !items.isEmpty
        button.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.update(button)
    }

    final class Coordinator: NSObject {
        var parent: SSHHostPicker
        private var displayedItems: [Item] = []
        private var displayedPlaceholder = ""

        init(_ parent: SSHHostPicker) {
            self.parent = parent
        }

        func update(_ button: NSPopUpButton) {
            button.menu?.autoenablesItems = false
            if displayedItems != parent.items || displayedPlaceholder != parent.placeholderTitle {
                displayedItems = parent.items
                displayedPlaceholder = parent.placeholderTitle
                button.removeAllItems()
                let placeholder = NSMenuItem(title: parent.placeholderTitle, action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                button.menu?.addItem(placeholder)
                for entry in displayedItems {
                    let menuItem = NSMenuItem(title: entry.displayTitle, action: nil, keyEquivalent: "")
                    menuItem.representedObject = entry.id
                    menuItem.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
                    menuItem.toolTip = entry.displayTitle
                    button.menu?.addItem(menuItem)
                }
            }
            if let index = displayedItems.firstIndex(where: { $0.id == parent.selection }) {
                button.selectItem(at: index + 1)
                button.setAccessibilityValue(displayedItems[index].displayTitle)
                button.toolTip = displayedItems[index].displayTitle
            } else {
                button.selectItem(at: 0)
                button.setAccessibilityValue(nil)
                button.toolTip = parent.placeholderTitle
            }
        }

        @objc func selectItem(_ sender: NSPopUpButton) {
            guard parent.enabled,
                  let id = sender.selectedItem?.representedObject as? String,
                  parent.items.contains(where: { $0.id == id }) else { return }
            parent.selection = id
        }
    }
}
