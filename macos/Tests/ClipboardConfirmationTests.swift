import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct ClipboardConfirmationTests {
    @Test(arguments: [false, true]) @MainActor
    func passwordPasteDoesNotCreateTextPreview(darkMode: Bool) throws {
        let contents = "ghostty-test-only\n"
        let otherContents = "different-test-value\n"
        let appearance = darkMode ? "dark" : "light"
        func confirmation(_ contents: String, passwordInput: Bool = false) -> some View {
            ClipboardConfirmationView(contents: contents, request: .paste, passwordInput: passwordInput)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, darkMode ? .dark : .light)
        }
        let host = NSHostingView(rootView: confirmation(contents))
        host.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()

        // Check the ordinary preview first so this test cannot pass merely
        // because the hosting view did not create its content.
        #expect(textViews(in: host).contains { $0.string == contents })
        let ordinary = try snapshot(host)
        Attachment.record(ordinary, named: "paste-ordinary-\(appearance).png")

        host.rootView = confirmation(otherContents)
        host.layoutSubtreeIfNeeded()
        #expect(try snapshot(host) != ordinary)

        host.rootView = confirmation(contents, passwordInput: true)
        host.layoutSubtreeIfNeeded()
        #expect(textViews(in: host).isEmpty)
        let hidden = try snapshot(host)
        Attachment.record(hidden, named: "paste-password-\(appearance).png")
        #expect(hidden != ordinary)

        // Hidden pixels must not depend on clipboard contents.
        host.rootView = confirmation(otherContents, passwordInput: true)
        host.layoutSubtreeIfNeeded()
        #expect(try snapshot(host) == hidden)

        // A later ordinary request must regain its preview.
        host.rootView = confirmation(contents)
        host.layoutSubtreeIfNeeded()
        #expect(textViews(in: host).contains { $0.string == contents })
        Attachment.record(try snapshot(host), named: "paste-restored-\(appearance).png")
    }

    @MainActor
    private func snapshot(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func textViews(in view: NSView) -> [NSTextView] {
        let current = (view as? NSTextView).map { [$0] } ?? []
        return current + view.subviews.flatMap { textViews(in: $0) }
    }
}
