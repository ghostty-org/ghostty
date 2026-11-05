import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct OMGThemeBackgroundTests {
    /// The translucent chrome must stay a translucent fill (preserving blur),
    /// not an opaque pre-blended color. Settings/dialogs use the opaque variant.

    private func components(_ color: Color) -> (Int, Int, Int) {
        let c = NSColor(color).usingColorSpace(.deviceRGB)!
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    @Test func translucentChromeMatchesThePremultipliedRendererTarget() throws {
        let bg = Color(.sRGB, red: 33 / 255, green: 37 / 255, blue: 43 / 255, opacity: 1)
        let chrome = OMGThemeBackground.matchingChrome(
            color: bg, opacity: 0.85, windowIsOpaque: false, colorspaceIsDisplayP3: true)
        let color = try #require(NSColor(chrome).usingColorSpace(.displayP3))
        #expect(color.alphaComponent < 1)
        #expect(Int((color.alphaComponent * 255).rounded()) == 217)
        #expect(Int((color.redComponent * color.alphaComponent * 255).rounded()) == 28)
        #expect(Int((color.greenComponent * color.alphaComponent * 255).rounded()) == 31)
        #expect(Int((color.blueComponent * color.alphaComponent * 255).rounded()) == 37)
    }

    @Test func auxiliaryPaletteRetainsThemeHueAndAppearance() {
        let dark = OMGThemePalette(
            background: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1), foreground: .white)
        #expect(dark.colorScheme == .dark)
        #expect(dark.background.alphaComponent == 1)
        let sidebar = dark.sidebar.usingColorSpace(.sRGB)!
        #expect(sidebar.redComponent > 0.16)
        #expect(sidebar.redComponent < 0.25)
        #expect(sidebar.blueComponent > sidebar.redComponent)
        let light = OMGThemePalette(background: .white, foreground: .black)
        #expect(light.colorScheme == .light)
    }

    @MainActor
    @Test func themedDialogCancellationKeepsAccessoryAndReturnsOnce() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let alert = NSAlert()
        alert.messageText = "Create Branch"
        alert.informativeText = "Enter the new local branch name."
        let field = NSTextField(string: "feature/theme")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let result = Task { await OMGThemeDialog.present(alert, for: parent) }
        try await Task.sleep(for: .milliseconds(150))
        let sheet = try #require(parent.attachedSheet)
        // AppKit marks attached sheets non-opaque for their rounded edges;
        // the content and window backing must still paint an opaque theme.
        #expect(sheet.backgroundColor.alphaComponent == 1)
        #expect(sheet.titlebarAppearsTransparent)
        #expect(field.window === sheet)
        #expect(field.stringValue == "feature/theme")
        parent.endSheet(sheet)
        let response = await result.value
        #expect(response == .alertSecondButtonReturn)
        #expect(sheet.contentViewController == nil)
    }

    @Test func opaqueChromeIsQuantizedBackground() {
        let bg = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1) // Catppuccin Mocha
        let expected = TerminalRenderColorQuantizer.matchingRenderedNSColor(bg, colorspaceIsDisplayP3: false)
        let chrome = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 1, windowIsOpaque: true, colorspaceIsDisplayP3: false)
        #expect(components(chrome) == components(Color(expected)))
    }

    @Test func opaqueFullOpacityTranslucentWindowAlsoQuantizes() {
        // opacity >= 1 on a translucent (blur) window still matches the opaque path.
        let bg = NSColor(red: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)
        let opaque = OMGThemeBackground.matchingChrome(
            color: Color(bg), opacity: 1, windowIsOpaque: false, colorspaceIsDisplayP3: false)
        let expected = TerminalRenderColorQuantizer.matchingRenderedNSColor(bg, colorspaceIsDisplayP3: false)
        #expect(components(opaque) == components(Color(expected)))
    }
}
