import AppKit
import GhosttyKit

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension Ghostty.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // This function confused me a bit so I'm going to add my own commentary on
        // how this works. macOS sends this callback with the given send/return types and
        // we must return the responder capable of handling the COMBINATION of those send
        // and return types (or super up if we can't handle it).
        //
        // The "COMBINATION" bit is key: we might get sent a string (we can handle that)
        // but get requested an image (we can't handle that at the time of writing this),
        // so we must bubble up.

        // Types we can receive
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]

        // Types that we can send. Currently the same as receivable but I'm separating
        // this out so we can modify this in the future.
        let sendable: [NSPasteboard.PasteboardType] = receivable

        // The sendable types that require a selection (currently all)
        let sendableRequiresSelection = sendable

        // If we expect no data to be sent/received we can obviously handle it (that's
        // the nil check), otherwise it must conform to the types we support on both sides.
        if (returnType == nil || receivable.contains(returnType!)) &&
            (sendType == nil || sendable.contains(sendType!)) {
            // If we're expected to send back a type that requires selection, then
            // verify that we have a selection. We do this within this block because
            // validateRequestor is called a LOT and we want to prevent unnecessary
            // performance hits because `ghostty_surface_has_selection` isn't free.
            if let sendType, sendableRequiresSelection.contains(sendType) {
                if surface == nil || !ghostty_surface_has_selection(surface) {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }

            return self
        }

        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surface else { return false }

        // Read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }

        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.getOpinionatedStringContents() else { return false }

        let len = str.utf8CString.count
        if len == 0 { return true }
        str.withCString { ptr in
            // len includes the null terminator so we do len - 1
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }

        return true
    }
}
