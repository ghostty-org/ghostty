import AppKit

extension Ghostty.SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteSelection):
            let pb = NSPasteboard.ghosttySelection
            guard let str = pb.getOpinionatedStringContents() else { return false }
            return !str.isEmpty

        case #selector(findHide):
            return searchState != nil

        case #selector(toggleReadonly):
            item.state = readonly ? .on : .off
            return true

        case #selector(copy(_:)):
            // We only enable copy menu item when there're actual selected text
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                return true
            } else {
                return false
            }

        default:
            return true
        }
    }
}
