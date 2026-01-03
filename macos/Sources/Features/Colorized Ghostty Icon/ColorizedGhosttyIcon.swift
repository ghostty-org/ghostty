import Cocoa

struct ColorizedGhosttyIcon {
    /// The colors that make up the gradient of the screen.
    let screenColors: [NSColor]

    /// The color of the ghost.
    let ghostColor: NSColor

    /// The frame type to use
    let frame: Ghostty.MacOSIconFrame

    /// Make a custom colorized ghostty icon.
    func makeImage(in bundle: Bundle) -> NSImage? {
        // All of our layers (not in order)
        guard let screen = bundle.image(forResource: "CustomIconScreen") else { return nil }
        guard let screenMask = bundle.image(forResource: "CustomIconScreenMask") else { return nil }
        guard let ghost = bundle.image(forResource: "CustomIconGhost") else { return nil }
        guard let crt = bundle.image(forResource: "CustomIconCRT") else { return nil }
        guard let gloss = bundle.image(forResource: "CustomIconGloss") else { return nil }

        let baseName = switch (frame) {
        case .aluminum: "CustomIconBaseAluminum"
        case .beige: "CustomIconBaseBeige"
        case .chrome: "CustomIconBaseChrome"
        case .plastic: "CustomIconBasePlastic"
        }
        guard let base = bundle.image(forResource: baseName) else { return nil }

        // Apply our color in various ways to our layers.
        // NOTE: These functions are not built-in, they're implemented as an extension
        // to NSImage in NSImage+Extension.swift.
        guard let screenGradient = screenMask.gradient(colors: screenColors) else { return nil }
        guard let tintedGhost = ghost.tint(color: ghostColor) else { return nil }

        // Combine our layers using the proper blending modes
        return.combine(images: [
            base,
            screen,
            screenGradient,
            ghost,
            tintedGhost,
            crt,
            gloss,
        ], blendingModes: [
            .normal,
            .normal,
            .color,
            .normal,
            .color,
            .overlay,
            .normal,
        ])
    }
}
