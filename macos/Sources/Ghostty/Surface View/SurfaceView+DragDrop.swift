import AppKit

extension Ghostty.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content = pb.getOpinionatedStringContents()

        if let content {
            DispatchQueue.main.async {
                self.surfaceModel?.sendText(content)
            }
            return true
        }

        return false
    }
}
