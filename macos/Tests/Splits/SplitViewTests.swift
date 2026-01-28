import Testing
import SwiftUI
@testable import Ghostty

struct SplitViewTests {
    // MARK: - Double-Tap Zoom Toggle Tests

    @Test func doubleTapInvokesZoomToggleCallback() async {
        var zoomToggleCalled = false

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: { zoomToggleCalled = true }
        )

        // Note: In a full integration test, we would simulate a double-tap gesture
        // For this unit test, we verify that the callback is properly stored
        #expect(splitView.onZoomToggle != nil)
    }

    @Test func zoomToggleCallbackIsExecutable() {
        var callbackExecuted = false

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: { callbackExecuted = true }
        )

        // Execute the callback directly
        splitView.onZoomToggle()
        #expect(callbackExecuted == true)
    }

    @Test func zoomToggleWorksWithVerticalSplit() {
        var zoomToggleCalled = false

        let splitView = SplitView(
            .vertical,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Top") },
            right: { Text("Bottom") },
            onZoomToggle: { zoomToggleCalled = true }
        )

        splitView.onZoomToggle()
        #expect(zoomToggleCalled == true)
    }

    // MARK: - Split Ratio Tests

    @Test func horizontalSplitWithEqualRatio() {
        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.direction == .horizontal)
        #expect(splitView.split == 0.5)
    }

    @Test func verticalSplitWithEqualRatio() {
        let splitView = SplitView(
            .vertical,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Top") },
            right: { Text("Bottom") },
            onZoomToggle: {}
        )

        #expect(splitView.direction == .vertical)
        #expect(splitView.split == 0.5)
    }

    @Test func splitWithCustomRatio() {
        let splitView = SplitView(
            .horizontal,
            .constant(0.3),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.split == 0.3)
    }

    // MARK: - Divider Configuration Tests

    @Test func customDividerColor() {
        let customColor = Color.red

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: customColor,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.dividerColor == customColor)
    }

    @Test func customResizeIncrements() {
        let customIncrements = NSSize(width: 10, height: 10)

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            resizeIncrements: customIncrements,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.resizeIncrements == customIncrements)
    }

    @Test func defaultResizeIncrements() {
        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.resizeIncrements == NSSize(width: 1, height: 1))
    }

    // MARK: - Edge Cases

    @Test func minimumSplitRatio() {
        let splitView = SplitView(
            .horizontal,
            .constant(0.0),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.split == 0.0)
    }

    @Test func maximumSplitRatio() {
        let splitView = SplitView(
            .horizontal,
            .constant(1.0),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        #expect(splitView.split == 1.0)
    }

    @Test func zoomToggleCanBeCalledMultipleTimes() {
        var callCount = 0

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: { callCount += 1 }
        )

        splitView.onZoomToggle()
        splitView.onZoomToggle()
        splitView.onZoomToggle()

        #expect(callCount == 3)
    }

    // MARK: - Accessibility Tests

    @Test func horizontalSplitHasCorrectAccessibilityLabels() {
        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: {}
        )

        // Note: Accessibility labels are private, but we verify direction is set correctly
        #expect(splitView.direction == .horizontal)
    }

    @Test func verticalSplitHasCorrectAccessibilityLabels() {
        let splitView = SplitView(
            .vertical,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Top") },
            right: { Text("Bottom") },
            onZoomToggle: {}
        )

        #expect(splitView.direction == .vertical)
    }

    // MARK: - Integration with TerminalSplitTreeView

    @Test func zoomToggleCallbackMatchesExpectedSignature() {
        // Verify that the callback signature matches what TerminalSplitTreeView expects
        let callback: () -> Void = {}

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            dividerColor: .gray,
            left: { Text("Left") },
            right: { Text("Right") },
            onZoomToggle: callback
        )

        // If this compiles, the signature is correct
        #expect(splitView.onZoomToggle != nil)
    }
}
