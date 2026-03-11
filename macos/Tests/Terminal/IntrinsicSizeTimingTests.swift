import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty

// MARK: - Test helpers

/// Mimics TerminalView's .frame(idealWidth:idealHeight:) pattern where
/// values come from lastFocusedSurface?.value?.initialSize, which may
/// be nil before @FocusedValue propagates.
private struct OptionalIdealSizeView: View {
    let idealWidth: CGFloat?
    let idealHeight: CGFloat?
    let titlebarStyle: Ghostty.Config.MacOSTitlebarStyle

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(idealWidth: idealWidth, idealHeight: idealHeight)
        }
        // Matches TerminalView line 108: hidden style extends into titlebar
        .ignoresSafeArea(.container, edges: titlebarStyle == .hidden ? .top : [])
    }
}

private let minReasonableWidth: CGFloat = 100
private let minReasonableHeight: CGFloat = 50

/// All macos-titlebar-style values that map to different window nibs.
private let allTitlebarStyles: [Ghostty.Config.MacOSTitlebarStyle] = [.native, .hidden, .transparent, .tabs]

/// Window style masks that roughly correspond to each titlebar style.
/// In real Ghostty these come from different nib files; in tests we
/// approximate with NSWindow style masks.
private func styleMask(for titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) -> NSWindow.StyleMask {
    switch titlebarStyle {
    case .hidden:
        return [.titled, .resizable, .fullSizeContentView]
    case .transparent, .tabs:
        return [.titled, .resizable, .fullSizeContentView]
    case .native:
        return [.titled, .resizable]
    }
}

// MARK: - Tests

/// Regression tests for Issue #11256: incorrect intrinsicContentSize
/// race condition in TerminalController.windowDidLoad().
///
/// The contentIntrinsicSize branch of DefaultSize reads
/// intrinsicContentSize after a 40ms delay. But intrinsicContentSize
/// depends on @FocusedValue propagating lastFocusedSurface, which is
/// async and may not complete in time — producing a tiny window.
///
/// These tests cover the matrix of:
/// - With/without window-width/window-height (initialSize set vs nil)
/// - All macos-titlebar-style values (native, hidden, transparent, tabs)
@Suite(.bug("https://github.com/ghostty-org/ghostty/issues/11256", "Incorrect intrinsicContentSize with native titlebar"))
struct IntrinsicSizeTimingTests {

    // MARK: - Bug: nil ideal sizes → tiny window

    /// When window-width/height is set, defaultSize returns .contentIntrinsicSize.
    /// Before @FocusedValue propagates, idealWidth/idealHeight are nil and
    /// intrinsicContentSize returns a tiny value.
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11256", "intrinsicContentSize too small before @FocusedValue propagates"),
          arguments: allTitlebarStyles)
    func intrinsicSizeTooSmallWithNilIdealSize(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedSize = NSSize(width: 600, height: 400)

        // nil ideal sizes = @FocusedValue hasn't propagated lastFocusedSurface
        let container = await TerminalViewContainer {
            OptionalIdealSizeView(idealWidth: nil, idealHeight: nil, titlebarStyle: titlebarStyle)
        }

        // Set initialContentSize so intrinsicContentSize returns the
        // correct value immediately, without waiting for @FocusedValue.
        await MainActor.run {
            container.initialContentSize = expectedSize
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        await MainActor.run {
            window.contentView = container
        }

        let size = await container.intrinsicContentSize

        #expect(
            size.width >= minReasonableWidth && size.height >= minReasonableHeight,
            "[\(titlebarStyle)] intrinsicContentSize is too small: \(size). Expected at least \(minReasonableWidth)x\(minReasonableHeight)"
        )

        await MainActor.run { window.close() }
    }

    /// Verifies that DefaultSize.contentIntrinsicSize.apply() produces a
    /// too-small window when intrinsicContentSize is based on nil ideal sizes.
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11256", "apply() sets wrong window size due to racy intrinsicContentSize"),
          arguments: allTitlebarStyles)
    func applyProducesWrongSizeWithNilIdealSize(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let container = await TerminalViewContainer {
            OptionalIdealSizeView(idealWidth: nil, idealHeight: nil, titlebarStyle: titlebarStyle)
        }

        await MainActor.run {
            container.initialContentSize = NSSize(width: 600, height: 400)
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        let contentLayoutSize = await MainActor.run {
            window.contentView = container

            let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize
            defaultSize.apply(to: window)

            // Use contentLayoutRect — the usable area excluding titlebar
            return window.contentLayoutRect.size
        }

        #expect(
            contentLayoutSize.width >= minReasonableWidth && contentLayoutSize.height >= minReasonableHeight,
            "[\(titlebarStyle)] Window content layout size is too small after apply: \(contentLayoutSize)"
        )

        await MainActor.run { window.close() }
    }

    /// Replicates the exact pattern from TerminalController.windowDidLoad():
    /// 1. Set window.contentView = container (with nil ideal sizes, simulating
    ///    @FocusedValue not yet propagated)
    /// 2. DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40))
    /// 3. Inside the callback: defaultSize.apply(to: window)
    ///
    /// This is the core race condition: 40ms is not enough for @FocusedValue
    /// to propagate, so intrinsicContentSize is still tiny when apply() runs.
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11256", "40ms async delay reads intrinsicContentSize before @FocusedValue propagates"),
          arguments: allTitlebarStyles)
    func asyncAfterDelayProducesWrongSizeWithNilIdealSize(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let container = await TerminalViewContainer {
            OptionalIdealSizeView(idealWidth: nil, idealHeight: nil, titlebarStyle: titlebarStyle)
        }

        await MainActor.run {
            container.initialContentSize = NSSize(width: 600, height: 400)
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        // Replicate TerminalController.windowDidLoad() exactly:
        // 1. Set contentView
        // 2. DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40))
        // 3. apply() inside the callback
        let contentLayoutSize: NSSize = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                window.contentView = container

                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
                    let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize
                    defaultSize.apply(to: window)
                    continuation.resume(returning: window.contentLayoutRect.size)
                }
            }
        }

        #expect(
            contentLayoutSize.width >= minReasonableWidth && contentLayoutSize.height >= minReasonableHeight,
            "[\(titlebarStyle)] After 40ms async delay, content layout size is too small: \(contentLayoutSize)"
        )

        await MainActor.run { window.close() }
    }

    /// Verifies that applying synchronously (without the async delay) also
    /// fails when ideal sizes are nil. This proves the fix must provide a
    /// fallback value, not just adjust timing.
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11256", "Synchronous apply also fails without fallback"),
          arguments: allTitlebarStyles)
    func synchronousApplyAlsoFailsWithNilIdealSize(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let container = await TerminalViewContainer {
            OptionalIdealSizeView(idealWidth: nil, idealHeight: nil, titlebarStyle: titlebarStyle)
        }

        await MainActor.run {
            container.initialContentSize = NSSize(width: 600, height: 400)
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        let contentLayoutSize = await MainActor.run {
            window.contentView = container
            // Apply immediately — no async delay at all
            let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize
            defaultSize.apply(to: window)
            return window.contentLayoutRect.size
        }

        #expect(
            contentLayoutSize.width >= minReasonableWidth && contentLayoutSize.height >= minReasonableHeight,
            "[\(titlebarStyle)] Synchronous apply with nil ideal sizes: content layout size too small: \(contentLayoutSize)"
        )

        await MainActor.run { window.close() }
    }

    // MARK: - Happy path: ideal sizes available (contentIntrinsicSize path)

    /// When @FocusedValue HAS propagated (ideal sizes are set), intrinsicContentSize
    /// should be correct for every titlebar style. This is the "happy path" that
    /// works today when the 40ms delay is sufficient.
    @Test(arguments: allTitlebarStyles)
    func intrinsicSizeCorrectWhenIdealSizesAvailable(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedSize = NSSize(width: 600, height: 400)

        let container = await TerminalViewContainer {
            OptionalIdealSizeView(
                idealWidth: expectedSize.width,
                idealHeight: expectedSize.height,
                titlebarStyle: titlebarStyle
            )
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        await MainActor.run {
            window.contentView = container
        }

        // Wait for SwiftUI layout
        try await Task.sleep(nanoseconds: 100_000_000)

        let size = await container.intrinsicContentSize

        // intrinsicContentSize should be at least the ideal size.
        // With fullSizeContentView styles it may be slightly larger
        // due to safe area, but should never be smaller.
        #expect(
            size.width >= expectedSize.width && size.height >= expectedSize.height,
            "[\(titlebarStyle)] intrinsicContentSize (\(size)) should be >= expected \(expectedSize)"
        )

        await MainActor.run { window.close() }
    }

    /// Verifies that apply() sets a correctly sized window when ideal sizes
    /// are available, for each titlebar style.
    @Test(arguments: allTitlebarStyles)
    func applyProducesCorrectSizeWhenIdealSizesAvailable(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedSize = NSSize(width: 600, height: 400)

        let container = await TerminalViewContainer {
            OptionalIdealSizeView(
                idealWidth: expectedSize.width,
                idealHeight: expectedSize.height,
                titlebarStyle: titlebarStyle
            )
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        await MainActor.run {
            window.contentView = container
        }

        // Wait for SwiftUI layout before apply
        try await Task.sleep(nanoseconds: 100_000_000)

        let contentLayoutSize = await MainActor.run {
            let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize
            defaultSize.apply(to: window)
            // contentLayoutRect gives the usable area, excluding titlebar
            return window.contentLayoutRect.size
        }

        // The usable content area should be at least the expected size.
        #expect(
            contentLayoutSize.width >= expectedSize.width && contentLayoutSize.height >= expectedSize.height,
            "[\(titlebarStyle)] Content layout size (\(contentLayoutSize)) should be >= expected \(expectedSize) after apply"
        )

        await MainActor.run { window.close() }
    }

    /// Same async delay pattern but with ideal sizes available (happy path).
    /// This should always pass — it validates the delay works when @FocusedValue
    /// has already propagated.
    @Test(arguments: allTitlebarStyles)
    func asyncAfterDelayProducesCorrectSizeWhenIdealSizesAvailable(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedSize = NSSize(width: 600, height: 400)

        let container = await TerminalViewContainer {
            OptionalIdealSizeView(
                idealWidth: expectedSize.width,
                idealHeight: expectedSize.height,
                titlebarStyle: titlebarStyle
            )
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        // Replicate the exact TerminalController.windowDidLoad() pattern
        let contentLayoutSize: NSSize = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                window.contentView = container

                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
                    let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize
                    defaultSize.apply(to: window)
                    continuation.resume(returning: window.contentLayoutRect.size)
                }
            }
        }

        #expect(
            contentLayoutSize.width >= expectedSize.width && contentLayoutSize.height >= expectedSize.height,
            "[\(titlebarStyle)] Content layout size (\(contentLayoutSize)) should be >= expected \(expectedSize) after 40ms delay"
        )

        await MainActor.run { window.close() }
    }

    // MARK: - Without window-width/window-height (frame path)

    /// Without window-width/height config, defaultSize returns .frame or nil
    /// (never .contentIntrinsicSize). The window uses its initial frame.
    /// This should work for all titlebar styles regardless of the bug.
    @Test(arguments: allTitlebarStyles)
    func framePathWorksWithoutWindowSize(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedFrame = NSRect(x: 100, y: 100, width: 800, height: 600)

        let container = await TerminalViewContainer {
            Color.clear
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        await MainActor.run {
            window.contentView = container
            let defaultSize = TerminalController.DefaultSize.frame(expectedFrame)
            defaultSize.apply(to: window)
        }

        let frame = await MainActor.run { window.frame }

        #expect(
            frame == expectedFrame,
            "[\(titlebarStyle)] Window frame (\(frame)) should match expected \(expectedFrame)"
        )

        await MainActor.run { window.close() }
    }

    // MARK: - isChanged

    /// Verifies isChanged correctly detects mismatch for contentIntrinsicSize
    /// across titlebar styles when ideal sizes are available.
    @Test(arguments: allTitlebarStyles)
    func isChangedDetectsMismatch(titlebarStyle: Ghostty.Config.MacOSTitlebarStyle) async throws {
        let expectedSize = NSSize(width: 600, height: 400)

        let container = await TerminalViewContainer {
            OptionalIdealSizeView(
                idealWidth: expectedSize.width,
                idealHeight: expectedSize.height,
                titlebarStyle: titlebarStyle
            )
        }

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: styleMask(for: titlebarStyle),
            backing: .buffered,
            defer: false
        )

        await MainActor.run {
            window.contentView = container
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let defaultSize = TerminalController.DefaultSize.contentIntrinsicSize

        let changedBefore = await MainActor.run { defaultSize.isChanged(for: window) }
        #expect(changedBefore, "[\(titlebarStyle)] isChanged should return true before apply")

        await MainActor.run { defaultSize.apply(to: window) }

        let changedAfter = await MainActor.run { defaultSize.isChanged(for: window) }
        #expect(!changedAfter, "[\(titlebarStyle)] isChanged should return false after apply")

        await MainActor.run { window.close() }
    }

    /// Verifies isChanged for the .frame path.
    @Test func isChangedForFramePath() async throws {
        let expectedFrame = NSRect(x: 100, y: 100, width: 800, height: 600)

        let window = await NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        let defaultSize = TerminalController.DefaultSize.frame(expectedFrame)

        let changedBefore = await MainActor.run { defaultSize.isChanged(for: window) }
        #expect(changedBefore, "isChanged should return true before apply")

        await MainActor.run { defaultSize.apply(to: window) }

        let changedAfter = await MainActor.run { defaultSize.isChanged(for: window) }
        #expect(!changedAfter, "isChanged should return false after apply")

        await MainActor.run { window.close() }
    }
}
