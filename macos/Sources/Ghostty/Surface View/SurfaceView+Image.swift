import AppKit

extension Ghostty.SurfaceView {
    /// A snapshot image of the current surface view.
    var asImage: NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
