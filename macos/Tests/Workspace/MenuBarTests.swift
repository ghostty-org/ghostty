import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuBarTests {
    // MARK: - MenuBarIconRenderer

    @Test func renderIconReturnsNonNilForAllStates() {
        let states: [SessionIndicatorState?] = [
            nil, .inactive, .idle, .processing, .longRunning, .waiting, .needsAttention, .error,
        ]
        for state in states {
            let image = MenuBarIconRenderer.renderIcon(state: state)
            #expect(image.size.width > 0, "Icon should have non-zero width for state: \(String(describing: state))")
            #expect(image.size.height > 0, "Icon should have non-zero height for state: \(String(describing: state))")
        }
    }

    @Test func renderIconSizeIs18x18() {
        let image = MenuBarIconRenderer.renderIcon(state: .processing)
        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
    }

    @Test func renderIconNilStateMatchesInactiveSize() {
        let nilImage = MenuBarIconRenderer.renderIcon(state: nil)
        let inactiveImage = MenuBarIconRenderer.renderIcon(state: .inactive)
        #expect(nilImage.size == inactiveImage.size)
    }

    // MARK: - Aggregate State

    @Test func aggregateStateReturnsNilForEmptyDictionary() {
        let result = MenuBarIconRenderer.aggregateState(from: [:])
        #expect(result == nil)
    }

    @Test func aggregateStateReturnsNilForAllInactive() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .inactive,
            UUID(): .inactive,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == nil)
    }

    @Test func aggregateStateReturnsHighestPriority() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .idle,
            UUID(): .processing,
            UUID(): .error,
            UUID(): .waiting,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == .error)
    }

    @Test func aggregateStateIgnoresInactiveEntries() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .inactive,
            UUID(): .processing,
            UUID(): .inactive,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == .processing)
    }

    @Test func aggregateStateSingleActiveSession() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .needsAttention,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == .needsAttention)
    }

    @Test func aggregateStateNeedsAttentionBeatsWaiting() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .waiting,
            UUID(): .needsAttention,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == .needsAttention)
    }

    @Test func aggregateStateLongRunningBeatsProcessing() {
        let states: [UUID: SessionIndicatorState] = [
            UUID(): .processing,
            UUID(): .longRunning,
        ]
        let result = MenuBarIconRenderer.aggregateState(from: states)
        #expect(result == .longRunning)
    }

    // MARK: - Notification Name

    @Test func menuBarFocusSessionNotificationNameExists() {
        let name = Notification.Name.menuBarFocusSession
        #expect(name.rawValue == "com.seansmithdesign.ghostties.menuBar.focusSession")
    }
}
