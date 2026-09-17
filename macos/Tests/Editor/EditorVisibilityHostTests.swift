import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Regression coverage for issue #14: hiding the editor must really hide its
/// native hierarchy (`NSView.isHidden`), not just fade it out, so WebKit and
/// the scroll-view editors stop all visibility/occlusion activity while the
/// terminal underneath is scrolled.
@MainActor
struct EditorVisibilityHostTests {
    private typealias Host = EditorVisibilityHost<Text>.Host

    private func makeHost(isVisible: Bool) -> Host {
        let host = Host(rootView: Text("editor"))
        EditorVisibilityHost<Text>.apply(isVisible: isVisible, to: host)
        return host
    }

    @Test func hiddenWorkspaceMarksRootViewHidden() {
        #expect(makeHost(isVisible: false).view.isHidden)
    }

    @Test func visibleWorkspaceKeepsRootViewVisible() {
        #expect(!makeHost(isVisible: true).view.isHidden)
    }

    @Test func retogglingVisibilityKeepsSameNativeHierarchy() {
        let host = makeHost(isVisible: true)
        let hostedView = host.view
        #expect(!hostedView.isHidden)

        EditorVisibilityHost<Text>.apply(isVisible: false, to: host)
        #expect(hostedView.isHidden)
        #expect(host.view === hostedView)

        EditorVisibilityHost<Text>.apply(isVisible: true, to: host)
        #expect(!hostedView.isHidden)
        #expect(host.view === hostedView)
    }

    @Test func hostDoesNotSelfSizeFromAppKitConstraints() {
        let host = makeHost(isVisible: true)
        host.view.setFrameSize(CGSize(width: 640, height: 480))
        host.view.layoutSubtreeIfNeeded()
        if #available(macOS 13.0, *) {
            #expect(host.sizingOptions.isEmpty)
        }
    }
}
