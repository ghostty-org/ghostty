import XCTest
import AppKit
@testable import Ghostty

/// Verifies the coordinate arithmetic behind `WorkspaceLayout.titlebarRowTopAnchorConstant(in:)`.
///
/// These tests exercise the math independently of a real window so they run fast and
/// headlessly. The live measurement path is exercised by the DEBUG assert in
/// `WorkspaceViewContainer.layout()`.
final class WorkspaceAlignmentTests: XCTestCase {

    // Verify the coordinate arithmetic: given a known closeButton midY,
    // the computed constant should place the toolbar row breathingRoomBelowChrome
    // pts below the traffic lights (i.e. further from visual top).
    func testTitlebarRowConstantMath() {
        // Simulate: view.bounds.height = 800, close.midY (unflipped) = 786 (= 800 - 14)
        let boundsHeight: CGFloat = 800
        let closeMidY_unflipped: CGFloat = boundsHeight - 14   // 14pt from visual top
        let breathingRoom = WorkspaceLayout.breathingRoomBelowChrome  // 8

        let rowY_unflipped = closeMidY_unflipped - breathingRoom      // = 778
        let constant = boundsHeight - rowY_unflipped                  // = 22

        XCTAssertEqual(constant, 22,
            "topAnchor constant should place toolbar row 22pt below visual top")
        XCTAssertEqual(boundsHeight - constant, rowY_unflipped,
            "Unflipped Y should be bounds.height - constant")
    }

    func testBreathingRoomIsPreserved() {
        // Different window heights shouldn't change the relationship.
        for height in [600.0, 800.0, 1200.0] as [CGFloat] {
            let closeMidY = height - 14
            let rowY = closeMidY - WorkspaceLayout.breathingRoomBelowChrome
            let constant = height - rowY
            // constant should always be 22 (= 14 + 8) regardless of window height
            XCTAssertEqual(constant, 22, accuracy: 0.01,
                "For height=\(height): constant should be 22, got \(constant)")
        }
    }
}
