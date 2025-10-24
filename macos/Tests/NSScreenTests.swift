//
//  WindowPositionTests.swift
//  GhosttyTests
//
//  Tests for window positioning coordinate conversion functionality.
//

import Testing
import AppKit
@testable import Ghostty

struct NSScreenExtensionTests {
    /// Test positive coordinate conversion from top-left to bottom-left
    @Test func testPositiveCoordinateConversion() async throws {
        // Mock screen with 1000x800 visible frame starting at (0, 100)
        let mockScreenFrame = NSRect(x: 0, y: 100, width: 1000, height: 800)
        let mockScreen = MockNSScreen(visibleFrame: mockScreenFrame)
        
        // Mock window size
        let windowSize = CGSize(width: 400, height: 300)
        
        // Test top-left positioning: x=15, y=15
        let origin = mockScreen.origin(
            fromTopLeftOffsetX: 15,
            offsetY: 15,
            windowSize: windowSize)
        
        // Expected: x = 0 + 15 = 15, y = (100 + 800) - 15 - 300 = 585
        #expect(origin.x == 15)
        #expect(origin.y == 585)
    }
    
    /// Test zero coordinates (exact top-left corner)
    @Test func testZeroCoordinates() async throws {
        let mockScreenFrame = NSRect(x: 0, y: 100, width: 1000, height: 800)
        let mockScreen = MockNSScreen(visibleFrame: mockScreenFrame)
        let windowSize = CGSize(width: 400, height: 300)
        
        let origin = mockScreen.origin(
            fromTopLeftOffsetX: 0,
            offsetY: 0,
            windowSize: windowSize)
        
        // Expected: x = 0, y = (100 + 800) - 0 - 300 = 600
        #expect(origin.x == 0)
        #expect(origin.y == 600)
    }
    
    /// Test with offset screen (not starting at origin)
    @Test func testOffsetScreen() async throws {
        // Secondary monitor at position (1440, 0) with 1920x1080 resolution
        let mockScreenFrame = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let mockScreen = MockNSScreen(visibleFrame: mockScreenFrame)
        let windowSize = CGSize(width: 600, height: 400)
        
        let origin = mockScreen.origin(
            fromTopLeftOffsetX: 100,
            offsetY: 50,
            windowSize: windowSize)
        
        // Expected: x = 1440 + 100 = 1540, y = (0 + 1080) - 50 - 400 = 630
        #expect(origin.x == 1540)
        #expect(origin.y == 630)
    }
    
    /// Test large coordinates
    @Test func testLargeCoordinates() async throws {
        let mockScreenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let mockScreen = MockNSScreen(visibleFrame: mockScreenFrame)
        let windowSize = CGSize(width: 400, height: 300)
        
        let origin = mockScreen.origin(
            fromTopLeftOffsetX: 500,
            offsetY: 200,
            windowSize: windowSize)
        
        // Expected: x = 0 + 500 = 500, y = (0 + 1080) - 200 - 300 = 580
        #expect(origin.x == 500)
        #expect(origin.y == 580)
    }
}

/// Mock NSScreen class for testing coordinate conversion
private class MockNSScreen: NSScreen {
    private let mockVisibleFrame: NSRect
    
    init(visibleFrame: NSRect) {
        self.mockVisibleFrame = visibleFrame
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var visibleFrame: NSRect {
        return mockVisibleFrame
    }
}
