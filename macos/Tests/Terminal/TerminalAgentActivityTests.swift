@testable import Ghostty
import Testing

struct TerminalAgentActivityTests {
    @Test func parsesJSONEvent() throws {
        let event = try #require(TerminalAgentActivityEvent.parse(jsonLine: """
        {"version":1,"surface_id":"surface-1","agent":"claude","event":"prompt-submit","state":"running","session_id":"s1"}
        """))

        #expect(event.surfaceID == "surface-1")
        #expect(event.agent == "claude")
        #expect(event.event == "prompt-submit")
        #expect(event.state == "running")
        #expect(event.sessionID == "s1")
    }

    @Test func malformedJSONIsIgnored() {
        #expect(TerminalAgentActivityEvent.parse(jsonLine: "{") == nil)
    }

    @Test func reducerMapsLifecycleStates() throws {
        var reducer = TerminalAgentActivityReducer()
        let surfaceID = "surface-1"

        #expect(reducer.apply(event("prompt-submit", state: "running"), expectedSurfaceID: surfaceID) == .running(agent: "claude"))
        #expect(reducer.apply(event("notification", state: "needsInput"), expectedSurfaceID: surfaceID) == .needsInput(agent: "claude"))
        #expect(reducer.apply(event("stop", state: "idle"), expectedSurfaceID: surfaceID) == .needsInput(agent: "claude"))
        #expect(reducer.apply(event("session-end", state: "idle"), expectedSurfaceID: surfaceID) == .idle)
    }

    @Test func reducerIgnoresStaleStop() throws {
        var reducer = TerminalAgentActivityReducer()
        let surfaceID = "surface-1"

        #expect(reducer.apply(event("prompt-submit", state: "running", sessionID: "old"), expectedSurfaceID: surfaceID) == .running(agent: "claude"))
        #expect(reducer.apply(event("prompt-submit", state: "running", sessionID: "new"), expectedSurfaceID: surfaceID) == .running(agent: "claude"))
        #expect(reducer.apply(event("stop", state: "idle", sessionID: "old"), expectedSurfaceID: surfaceID) == nil)
        #expect(reducer.state == .running(agent: "claude"))
    }

    @Test func reducerIgnoresWrongSurface() throws {
        var reducer = TerminalAgentActivityReducer()
        #expect(reducer.apply(event("prompt-submit", state: "running"), expectedSurfaceID: "other") == nil)
        #expect(reducer.state == .idle)
    }

    @Test func reducerAcknowledgesAttentionStates() throws {
        var reducer = TerminalAgentActivityReducer()

        #expect(reducer.apply(event("notification", state: "needsInput")) == .needsInput(agent: "claude"))
        #expect(reducer.acknowledgeAttention() == .idle)
        #expect(reducer.state == .idle)
        #expect(reducer.acknowledgeAttention() == nil)

        #expect(reducer.apply(event("hook-error", state: nil)) == .error(agent: "claude"))
        #expect(reducer.acknowledgeAttention() == .idle)
        #expect(reducer.state == .idle)
    }

    @Test func runningStateExpiresAfterTTL() throws {
        var reducer = TerminalAgentActivityReducer()
        let start = Date()

        #expect(reducer.apply(event("prompt-submit", state: "running"), now: start) == .running(agent: "claude"))
        #expect(reducer.expireRunningState(now: start.addingTimeInterval(TerminalAgentActivityReducer.runningTTL - 1)) == nil)
        #expect(reducer.expireRunningState(now: start.addingTimeInterval(TerminalAgentActivityReducer.runningTTL)) == .idle)
    }

    @Test func sidebarIndicatorPrecedence() {
        #expect(TerminalSidebarStatusIndicatorState.derive(
            from: [.needsInput(agent: "codex"), .running(agent: "claude")],
            hasTerminalProgress: false,
            hasTerminalBell: true
        ) == .spinner(agent: "claude"))

        #expect(TerminalSidebarStatusIndicatorState.derive(
            from: [.needsInput(agent: "codex"), .error(agent: "claude")],
            hasTerminalProgress: false,
            hasTerminalBell: true
        ) == .error(agent: "claude"))

        #expect(TerminalSidebarStatusIndicatorState.derive(
            from: [.idle, .needsInput(agent: "codex")],
            hasTerminalProgress: true,
            hasTerminalBell: true
        ) == .bell(agent: "codex"))

        #expect(TerminalSidebarStatusIndicatorState.derive(
            from: [.idle],
            hasTerminalProgress: true,
            hasTerminalBell: true
        ) == .spinner(agent: "terminal"))

        #expect(TerminalSidebarStatusIndicatorState.derive(
            from: [.idle],
            hasTerminalProgress: false,
            hasTerminalBell: true
        ) == .bell(agent: "terminal"))
    }

    @Test func sidebarAttentionIndicatorsCanBeAcknowledged() {
        #expect(TerminalSidebarStatusIndicatorState.bell(agent: "codex").isAttentionIndicator)
        #expect(TerminalSidebarStatusIndicatorState.error(agent: "codex").isAttentionIndicator)
        #expect(!TerminalSidebarStatusIndicatorState.spinner(agent: "codex").isAttentionIndicator)
        #expect(!TerminalSidebarStatusIndicatorState.none.isAttentionIndicator)
    }

    @Test func selectedTabsHideAttentionIndicators() {
        #expect(TerminalSidebarStatusIndicatorState.bell(agent: "codex").visibleState(isSelected: true) == .none)
        #expect(TerminalSidebarStatusIndicatorState.error(agent: "codex").visibleState(isSelected: true) == .none)
        #expect(TerminalSidebarStatusIndicatorState.bell(agent: "codex").visibleState(isSelected: false) == .bell(agent: "codex"))
        #expect(TerminalSidebarStatusIndicatorState.error(agent: "codex").visibleState(isSelected: false) == .error(agent: "codex"))
        #expect(TerminalSidebarStatusIndicatorState.spinner(agent: "codex").visibleState(isSelected: true) == .spinner(agent: "codex"))
    }

    private func event(
        _ event: String,
        state: String?,
        sessionID: String? = nil
    ) -> TerminalAgentActivityEvent {
        TerminalAgentActivityEvent(
            surfaceID: "surface-1",
            agent: "claude",
            event: event,
            state: state,
            sessionID: sessionID
        )
    }
}
