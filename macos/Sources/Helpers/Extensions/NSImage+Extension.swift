import Cocoa

extension NSImage {
    /// Combine multiple images with the given blend modes. This is useful given a set
    /// of layers to create a final rasterized image.
    static func combine(images: [NSImage], blendingModes: [CGBlendMode]) -> NSImage? {
        guard images.count == blendingModes.count else { return nil }
        guard images.count > 0 else { return nil }

        // The final size will be the same size as our first image.
        let size = images.first!.size

        // Create a bitmap context manually
        guard let bitmapContext = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Clear the context
        bitmapContext.setFillColor(.clear)
        bitmapContext.fill(.init(origin: .zero, size: size))

        // Draw each image with its corresponding blend mode
        for (index, image) in images.enumerated() {
            guard let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ) else { return nil }

            let blendMode = blendingModes[index]
            bitmapContext.setBlendMode(blendMode)
            bitmapContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }

        // Create a CGImage from the context
        guard let combinedCGImage = bitmapContext.makeImage() else { return nil }

        // Wrap the CGImage in an NSImage
        return NSImage(cgImage: combinedCGImage, size: size)
    }

    /// Apply a gradient onto this image, using this image as a mask.
    func gradient(colors: [NSColor]) -> NSImage? {
        let resultImage = NSImage(size: size)
        resultImage.lockFocus()
        defer { resultImage.unlockFocus() }

        // Draw the gradient
        guard let gradient = NSGradient(colors: colors) else { return nil }
        gradient.draw(in: .init(origin: .zero, size: size), angle: 90)

        // Apply the mask
        draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1.0)

        return resultImage
    }

    // Tint an NSImage with the given color by applying a basic fill on top of it.
    func tint(color: NSColor) -> NSImage? {
        // Create a new image with the same size as the base image
        let newImage = NSImage(size: size)

        // Draw into the new image
        newImage.lockFocus()
        defer { newImage.unlockFocus() }

        // Set up the drawing context
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        defer { context.restoreGState() }

        // Draw the base image
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: .init(origin: .zero, size: size))

        // Set the tint color and blend mode
        context.setFillColor(color.cgColor)
        context.setBlendMode(.sourceAtop)

        // Apply the tint color over the entire image
        context.fill(.init(origin: .zero, size: size))

        return newImage
    }
}
