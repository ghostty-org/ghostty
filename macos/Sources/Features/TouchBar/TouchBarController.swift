import Cocoa
import GhosttyKit

extension NSTouchBarItem.Identifier {
    static let touchBarNewTab = NSTouchBarItem.Identifier("com.mitchellh.ghostty.touchbar.newTab")
    static let touchBarSplitRight = NSTouchBarItem.Identifier("com.mitchellh.ghostty.touchbar.splitRight")
    static let touchBarSplitDown = NSTouchBarItem.Identifier("com.mitchellh.ghostty.touchbar.splitDown")
    static let touchBarCloseTab = NSTouchBarItem.Identifier("com.mitchellh.ghostty.touchbar.closeTab")
}

extension NSTouchBar.CustomizationIdentifier {
    static let ghostty = NSTouchBar.CustomizationIdentifier("com.mitchellh.ghostty.touchbar")
}

class TouchBarController: NSObject, NSTouchBarDelegate {
    private weak var target: TerminalController?

    init(target: TerminalController) {
        self.target = target
        super.init()
    }

    @objc func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = .ghostty
        touchBar.defaultItemIdentifiers = [
            .touchBarNewTab,
            .touchBarSplitRight,
            .touchBarSplitDown,
            .touchBarCloseTab
        ]
        touchBar.customizationAllowedItemIdentifiers = [
            .touchBarNewTab,
            .touchBarSplitRight,
            .touchBarSplitDown,
            .touchBarCloseTab
        ]
        return touchBar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard let target = target else { return nil }

        switch identifier {
        case .touchBarNewTab:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "", image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!, target: target, action: #selector(TerminalController.newTab(_:)))
            button.bezelColor = NSColor.controlColor
            item.view = button
            item.customizationLabel = "New Tab"
            return item

        case .touchBarSplitRight:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "", image: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split Right")!, target: target, action: #selector(BaseTerminalController.splitRight(_:)))
            button.bezelColor = NSColor.controlColor
            item.view = button
            item.customizationLabel = "Split Right"
            return item

        case .touchBarSplitDown:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "", image: NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Split Down")!, target: target, action: #selector(BaseTerminalController.splitDown(_:)))
            button.bezelColor = NSColor.controlColor
            item.view = button
            item.customizationLabel = "Split Down"
            return item

        case .touchBarCloseTab:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!, target: target, action: #selector(TerminalController.closeTab(_:)))
            button.bezelColor = NSColor.systemRed
            item.view = button
            item.customizationLabel = "Close Tab"
            return item

        default:
            return nil
        }
    }
}