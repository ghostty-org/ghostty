import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// Tests for Unit 2 of the sidebar smart-sections plan:
///   - Four-section bucketing (`.pinned` / `.activeNow` / `.recent` / `.all`)
///   - Per-session grouping (`.active` / `.recent` / `.idle`) inside an expanded project
///   - Grace-period anti-flap tracker
///   - Freeze/release snapshot for the layout
///
/// Intra-section order invariants (documented here so regressions are obvious):
///   - `.pinned`   → alphabetical (case-insensitive) — user-chosen order lands in Unit 6
///   - `.activeNow`→ alphabetical
///   - `.recent`   → chronological by `lastActiveAt` descending
///   - `.all`      → alphabetical
///
/// Boundary decisions:
///   - 24h "Recent" window is **inclusive** — exactly 24h ago still counts as Recent.
///     Strictly older falls to `.all`.
///   - Grace period is **exclusive** (`now - lastActive < gracePeriod`) — at exactly
///     `gracePeriod` seconds since last active, the project has aged out.
struct WorkspaceStoreSectionsTests {
    // MARK: - Fixtures

    private let template = AgentTemplate.shell

    private func makeProject(
        id: UUID = UUID(),
        name: String = "Proj",
        isPinned: Bool = false,
        lastActiveAt: Date? = nil
    ) -> Project {
        Project(
            id: id,
            name: name,
            rootPath: "/tmp/\(name)",
            isPinned: isPinned,
            lastActiveAt: lastActiveAt
        )
    }

    private func makeSession(
        id: UUID = UUID(),
        name: String = "Session",
        projectId: UUID,
        lastActiveAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            name: name,
            templateId: template.id,
            projectId: projectId,
            lastActiveAt: lastActiveAt
        )
    }

    private func ids(in section: SidebarSection, of sectioned: SectionedProjects) -> [UUID] {
        sectioned.first(where: { $0.0 == section })?.1.map(\.id) ?? []
    }

    private func names(in section: SidebarSection, of sectioned: SectionedProjects) -> [String] {
        sectioned.first(where: { $0.0 == section })?.1.map(\.name) ?? []
    }

    private func populatedSections(_ sectioned: SectionedProjects) -> [SidebarSection] {
        sectioned.map(\.0)
    }

    // MARK: - Pinned

    @Test func pinnedProjectLandsInPinnedSection() {
        let p = makeProject(name: "Alpha", isPinned: true)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(populatedSections(result) == [.pinned])
        #expect(ids(in: .pinned, of: result) == [p.id])
    }

    @Test func pinnedProjectWithActiveSessionStaysInPinnedSection() {
        // Pin overrides all other section rules.
        let p = makeProject(name: "Alpha", isPinned: true)
        let s = makeSession(projectId: p.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [s],
            indicatorStates: [s.id: .processing],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(populatedSections(result) == [.pinned])
        #expect(ids(in: .activeNow, of: result).isEmpty)
    }

    @Test func pinnedProjectsAreAlphabetical() {
        let a = makeProject(name: "zebra", isPinned: true)
        let b = makeProject(name: "Apple", isPinned: true)
        let c = makeProject(name: "mango", isPinned: true)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [a, b, c],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(names(in: .pinned, of: result) == ["Apple", "mango", "zebra"])
    }

    // MARK: - Active Now

    @Test func projectWithProcessingSessionIsActiveNow() {
        let p = makeProject(name: "Run")
        let s = makeSession(projectId: p.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [s],
            indicatorStates: [s.id: .processing],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(ids(in: .activeNow, of: result) == [p.id])
    }

    @Test func needsAttentionCountsAsActive() {
        let p = makeProject(name: "Blocked")
        let s = makeSession(projectId: p.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [s],
            indicatorStates: [s.id: .needsAttention],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(ids(in: .activeNow, of: result) == [p.id])
    }

    @Test func waitingAndLongRunningCountAsActive() {
        let pWaiting = makeProject(name: "Waiting")
        let pLong = makeProject(name: "LongRun")
        let sW = makeSession(projectId: pWaiting.id)
        let sL = makeSession(projectId: pLong.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [pWaiting, pLong],
            sessions: [sW, sL],
            indicatorStates: [sW.id: .waiting, sL.id: .longRunning],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(Set(ids(in: .activeNow, of: result)) == Set([pWaiting.id, pLong.id]))
    }

    @Test func idleAndInactiveDoNotCountAsActive() {
        let p1 = makeProject(name: "Idle", lastActiveAt: Date(timeIntervalSince1970: 999_000))
        let p2 = makeProject(name: "Inactive", lastActiveAt: Date(timeIntervalSince1970: 999_000))
        let s1 = makeSession(projectId: p1.id)
        let s2 = makeSession(projectId: p2.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p1, p2],
            sessions: [s1, s2],
            indicatorStates: [s1.id: .idle, s2.id: .inactive],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(ids(in: .activeNow, of: result).isEmpty)
        #expect(Set(ids(in: .recent, of: result)) == Set([p1.id, p2.id]))
    }

    @Test func activeNowProjectsAreAlphabetical() {
        let a = makeProject(name: "zebra")
        let b = makeProject(name: "Apple")
        let sa = makeSession(projectId: a.id)
        let sb = makeSession(projectId: b.id)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [a, b],
            sessions: [sa, sb],
            indicatorStates: [sa.id: .processing, sb.id: .processing],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(names(in: .activeNow, of: result) == ["Apple", "zebra"])
    }

    // MARK: - Grace Period (with injected clock)

    @Test func gracePeriodKeepsProjectInActiveNowAfterSilence() {
        // Project active at t=0, goes silent at t=30 (still within grace).
        // At t=119, still within grace → `.activeNow`.
        // At t=121, grace expired → demotes to `.recent` or `.all`.
        let p = makeProject(name: "Flapping", lastActiveAt: Date(timeIntervalSince1970: 0))
        let s = makeSession(projectId: p.id)

        // Inject clock via the computation helper's `now` parameter.
        let t0 = Date(timeIntervalSince1970: 0)

        // Session goes silent at t=30, no active indicator state now.
        // activeSinceTimestamps records t=30.
        let activeSince: [UUID: Date] = [p.id: t0.addingTimeInterval(30)]

        // At t=119 (89s since last active): still in grace.
        let resultBefore = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [s],
            indicatorStates: [s.id: .idle],
            activeSinceTimestamps: activeSince,
            gracePeriod: 120,
            now: { t0.addingTimeInterval(119) }
        )
        #expect(ids(in: .activeNow, of: resultBefore) == [p.id])

        // At t=150 (120s since last active): boundary — strictly-less-than check
        // means this is no longer in grace. Demoted (to `.recent` since the
        // project's `lastActiveAt` is at epoch 0 which is > 24h ago → `.all`).
        // Use lastActiveAt recent enough to confirm recent-vs-all classification.
        let pWithRecent = makeProject(
            id: p.id,
            name: "Flapping",
            lastActiveAt: t0.addingTimeInterval(30)
        )
        let resultAt120 = WorkspaceStore.computeSectionedProjects(
            projects: [pWithRecent],
            sessions: [s],
            indicatorStates: [s.id: .idle],
            activeSinceTimestamps: activeSince,
            gracePeriod: 120,
            now: { t0.addingTimeInterval(150) }
        )
        #expect(ids(in: .activeNow, of: resultAt120).isEmpty)
        #expect(ids(in: .recent, of: resultAt120) == [p.id])

        // At t=30+121s (still recent): demoted to `.recent` (lastActiveAt within 24h).
        let resultAt121 = WorkspaceStore.computeSectionedProjects(
            projects: [pWithRecent],
            sessions: [s],
            indicatorStates: [s.id: .idle],
            activeSinceTimestamps: activeSince,
            gracePeriod: 120,
            now: { t0.addingTimeInterval(30 + 121) }
        )
        #expect(ids(in: .activeNow, of: resultAt121).isEmpty)
        #expect(ids(in: .recent, of: resultAt121) == [p.id])
    }

    @Test func liveActiveSessionOverridesExpiredGrace() {
        // Even if grace period has expired, a currently-active session keeps
        // the project in `.activeNow`.
        let p = makeProject(name: "Still Running")
        let s = makeSession(projectId: p.id)
        let t0 = Date(timeIntervalSince1970: 0)

        // Grace tracker claims activity ended 10 minutes ago (long past 120s).
        let activeSince: [UUID: Date] = [p.id: t0]

        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [s],
            indicatorStates: [s.id: .processing],
            activeSinceTimestamps: activeSince,
            gracePeriod: 120,
            now: { t0.addingTimeInterval(600) }
        )
        #expect(ids(in: .activeNow, of: result) == [p.id])
    }

    @Test func gracePeriodExcludesProjectsWithNoTrackerEntry() {
        // No entry in activeSinceTimestamps and no live active session → not active.
        let p = makeProject(
            name: "Quiet",
            lastActiveAt: Date(timeIntervalSince1970: 999_000)
        )
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(ids(in: .activeNow, of: result).isEmpty)
        #expect(ids(in: .recent, of: result) == [p.id])
    }

    // MARK: - Recent

    @Test func projectWithLastActiveWithin24hIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Recent", lastActiveAt: now.addingTimeInterval(-3600))  // 1h ago
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(ids(in: .recent, of: result) == [p.id])
    }

    @Test func recentSectionIsChronologicalDescending() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = makeProject(name: "Zeta", lastActiveAt: now.addingTimeInterval(-20 * 3600))
        let newer = makeProject(name: "Alpha", lastActiveAt: now.addingTimeInterval(-1 * 3600))
        let middle = makeProject(name: "Middle", lastActiveAt: now.addingTimeInterval(-5 * 3600))
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [old, newer, middle],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        // Most recent first — alphabetical name order is irrelevant here.
        #expect(names(in: .recent, of: result) == ["Alpha", "Middle", "Zeta"])
    }

    @Test func twentyFourHourBoundaryIsInclusive() {
        // Boundary decision: `<=` 24h → Recent; strictly more → All.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exactly24h = makeProject(name: "Edge", lastActiveAt: now.addingTimeInterval(-24 * 3600))
        let justOver = makeProject(
            name: "Over",
            lastActiveAt: now.addingTimeInterval(-24 * 3600 - 1)
        )
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [exactly24h, justOver],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(ids(in: .recent, of: result) == [exactly24h.id])
        #expect(ids(in: .all, of: result) == [justOver.id])
    }

    // MARK: - All

    @Test func projectWithNilLastActiveFallsToAll() {
        let p = makeProject(name: "Blank", lastActiveAt: nil)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(ids(in: .all, of: result) == [p.id])
    }

    @Test func projectWithStaleLastActiveFallsToAll() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Ancient", lastActiveAt: now.addingTimeInterval(-48 * 3600))
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(ids(in: .all, of: result) == [p.id])
    }

    @Test func allSectionIsAlphabetical() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = makeProject(name: "zebra")
        let b = makeProject(name: "apple")
        let c = makeProject(name: "Mango")
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [a, b, c],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(names(in: .all, of: result) == ["apple", "Mango", "zebra"])
    }

    // MARK: - Multi-Section & Edge Cases

    @Test func projectLivesInExactlyOneSection() {
        // Pin overrides active; active overrides recent; recent overrides all.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pinned = makeProject(name: "Pin", isPinned: true, lastActiveAt: now)
        let active = makeProject(name: "Active", lastActiveAt: now)
        let recent = makeProject(name: "Recent", lastActiveAt: now.addingTimeInterval(-60))
        let stale = makeProject(name: "Stale", lastActiveAt: nil)

        let pinnedSession = makeSession(projectId: pinned.id)
        let activeSession = makeSession(projectId: active.id)
        let recentSession = makeSession(projectId: recent.id)

        let result = WorkspaceStore.computeSectionedProjects(
            projects: [pinned, active, recent, stale],
            sessions: [pinnedSession, activeSession, recentSession],
            // Pinned and active both have processing sessions — pin still wins.
            indicatorStates: [
                pinnedSession.id: .processing,
                activeSession.id: .processing,
                recentSession.id: .idle,
            ],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )

        #expect(ids(in: .pinned, of: result) == [pinned.id])
        #expect(ids(in: .activeNow, of: result) == [active.id])
        #expect(ids(in: .recent, of: result) == [recent.id])
        #expect(ids(in: .all, of: result) == [stale.id])

        // Not duplicated across sections.
        let allIds = result.flatMap { $0.1.map(\.id) }
        #expect(Set(allIds).count == allIds.count)
    }

    @Test func emptyProjectListReturnsEmptyLayout() {
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(result.isEmpty)
    }

    @Test func sectionsInRenderOrderWhenAllPopulated() {
        // Render order is .pinned, .activeNow, .recent, .all.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pinned = makeProject(name: "Pin", isPinned: true)
        let active = makeProject(name: "Active")
        let recent = makeProject(name: "Recent", lastActiveAt: now)
        let stale = makeProject(name: "Stale")
        let s = makeSession(projectId: active.id)

        let result = WorkspaceStore.computeSectionedProjects(
            projects: [stale, recent, active, pinned],  // shuffled input
            sessions: [s],
            indicatorStates: [s.id: .processing],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(populatedSections(result) == [.pinned, .activeNow, .recent, .all])
    }

    @Test func emptySectionsAreOmitted() {
        let p = makeProject(name: "Lonely", isPinned: true)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(populatedSections(result) == [.pinned])
    }

    @Test func manyActiveProjectsAllLandInActiveNow() {
        // Mirrors R10 — opening with 14 running agents shows them all up top.
        let now = Date(timeIntervalSince1970: 1_000_000)
        var projects: [Project] = []
        var sessions: [AgentSession] = []
        var indicators: [UUID: SessionIndicatorState] = [:]
        for i in 0..<14 {
            let p = makeProject(name: String(format: "P%02d", i))
            let s = makeSession(projectId: p.id)
            projects.append(p)
            sessions.append(s)
            indicators[s.id] = .processing
        }
        let result = WorkspaceStore.computeSectionedProjects(
            projects: projects,
            sessions: sessions,
            indicatorStates: indicators,
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )
        #expect(populatedSections(result) == [.activeNow])
        #expect(ids(in: .activeNow, of: result).count == 14)
    }

    @Test func orphanedActiveSinceEntryDoesNotCrash() {
        // Grace tracker has an entry for a project ID that no longer exists.
        // Computation should ignore it silently.
        let orphanId = UUID()
        let p = makeProject(name: "Real")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [orphanId: now],
            gracePeriod: 120,
            now: { now }
        )
        #expect(ids(in: .all, of: result) == [p.id])
        #expect(ids(in: .activeNow, of: result).isEmpty)
    }

    // MARK: - Session Groups (expanded project)

    @Test func sessionGroupsSortSessionsIntoThreeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Host")
        let running = makeSession(name: "Running", projectId: p.id, lastActiveAt: now)
        let recent = makeSession(
            name: "Recent",
            projectId: p.id,
            lastActiveAt: now.addingTimeInterval(-3600)
        )
        let idle = makeSession(
            name: "Idle",
            projectId: p.id,
            lastActiveAt: now.addingTimeInterval(-48 * 3600)
        )
        let nilIdle = makeSession(name: "Blank", projectId: p.id, lastActiveAt: nil)

        let groups = WorkspaceStore.computeSessionGroups(
            projectId: p.id,
            sessions: [idle, recent, running, nilIdle],
            indicatorStates: [running.id: .processing],
            now: { now }
        )

        let active = groups.first(where: { $0.0 == .active })?.1.map(\.name) ?? []
        let recentNames = groups.first(where: { $0.0 == .recent })?.1.map(\.name) ?? []
        let idleNames = groups.first(where: { $0.0 == .idle })?.1.map(\.name) ?? []

        #expect(active == ["Running"])
        #expect(recentNames == ["Recent"])
        // Alphabetical within idle bucket: Blank, Idle.
        #expect(idleNames == ["Blank", "Idle"])
    }

    @Test func sessionGroupsOmitEmptyBuckets() {
        let p = makeProject(name: "Host")
        let s1 = makeSession(name: "One", projectId: p.id)
        let s2 = makeSession(name: "Two", projectId: p.id)

        let groups = WorkspaceStore.computeSessionGroups(
            projectId: p.id,
            sessions: [s1, s2],
            indicatorStates: [s1.id: .processing, s2.id: .processing],
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(groups.map(\.0) == [.active])
    }

    @Test func sessionGroupsIgnoreOtherProjects() {
        let p = makeProject(name: "Host")
        let other = makeProject(name: "Other")
        let s = makeSession(name: "Mine", projectId: p.id)
        let notMine = makeSession(name: "Other", projectId: other.id)

        let groups = WorkspaceStore.computeSessionGroups(
            projectId: p.id,
            sessions: [s, notMine],
            indicatorStates: [s.id: .processing, notMine.id: .processing],
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let active = groups.first(where: { $0.0 == .active })?.1.map(\.name) ?? []
        #expect(active == ["Mine"])
    }

    @Test func sessionGroupsBucketsInRenderOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Host")
        let active = makeSession(name: "Active", projectId: p.id)
        let recent = makeSession(
            name: "Recent",
            projectId: p.id,
            lastActiveAt: now.addingTimeInterval(-3600)
        )
        let idle = makeSession(name: "Idle", projectId: p.id, lastActiveAt: nil)

        let groups = WorkspaceStore.computeSessionGroups(
            projectId: p.id,
            sessions: [idle, recent, active],
            indicatorStates: [active.id: .processing],
            now: { now }
        )
        #expect(groups.map(\.0) == [.active, .recent, .idle])
    }

    // MARK: - Freeze / Release (instance-level integration)

    @MainActor
    @Test func freezeSnapshotReturnsPreFreezeLayoutAfterMutation() {
        let active = makeProject(name: "Active")
        let stale = makeProject(name: "Stale")
        let s = makeSession(projectId: active.id)
        let store = WorkspaceStore(testingProjects: [active, stale], testingSessions: [s])

        // Pre-freeze: nothing is active → both in `.all`.
        #expect(Set(ids(in: .all, of: store.sectionedProjects)) == Set([active.id, stale.id]))
        #expect(ids(in: .activeNow, of: store.sectionedProjects).isEmpty)

        // Freeze this layout.
        store.freezeSnapshot()

        // Mutate — one session goes active. Without a freeze this would promote.
        store.updateIndicatorState(id: s.id, state: .processing)

        // Layout is frozen: no `.activeNow` section.
        let frozen = store.sectionedProjects
        #expect(ids(in: .activeNow, of: frozen).isEmpty)
        #expect(Set(ids(in: .all, of: frozen)) == Set([active.id, stale.id]))

        // But `globalIndicatorStates` is independent and reflects the mutation.
        #expect(store.globalIndicatorStates[s.id] == .processing)
    }

    @MainActor
    @Test func releaseSnapshotRestoresLiveComputation() {
        let active = makeProject(name: "Active")
        let s = makeSession(projectId: active.id)
        let store = WorkspaceStore(testingProjects: [active], testingSessions: [s])

        store.freezeSnapshot()
        store.updateIndicatorState(id: s.id, state: .processing)

        // Frozen: still `.all`.
        #expect(ids(in: .activeNow, of: store.sectionedProjects).isEmpty)

        store.releaseSnapshot()

        // Live: promoted to `.activeNow`.
        #expect(ids(in: .activeNow, of: store.sectionedProjects) == [active.id])
    }

    @MainActor
    @Test func freezeWhileFrozenIsNoOp() {
        // Nested freeze must not clobber the original snapshot.
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        store.freezeSnapshot()
        let firstFreeze = store.sectionedProjects  // empty activeNow

        store.updateIndicatorState(id: s.id, state: .processing)
        store.freezeSnapshot()  // second freeze — should be no-op

        // Still returns the original snapshot, not a fresh one with active.
        let afterSecondFreeze = store.sectionedProjects
        #expect(
            ids(in: .activeNow, of: afterSecondFreeze)
                == ids(in: .activeNow, of: firstFreeze))
        #expect(ids(in: .activeNow, of: afterSecondFreeze).isEmpty)
    }

    @MainActor
    @Test func releaseWithoutFreezeIsNoOp() {
        let store = WorkspaceStore(testingProjects: [], testingSessions: [])
        store.releaseSnapshot()  // must not crash
        #expect(store.sectionedProjects.isEmpty)
    }

    // MARK: - Activity Tracker

    @MainActor
    @Test func updateProjectActivityRecordsTimestampForActiveSessions() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        store.updateIndicatorState(id: s.id, state: .processing)
        let fakeNow = Date(timeIntervalSince1970: 42)
        store.updateProjectActivityFromIndicatorStates(now: { fakeNow })

        #expect(store._activeSinceTimestamp(for: p.id) == fakeNow)
    }

    @MainActor
    @Test func updateProjectActivityDoesNotRecordForIdleSessions() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        store.updateIndicatorState(id: s.id, state: .idle)
        store.updateProjectActivityFromIndicatorStates(now: { Date() })

        #expect(store._activeSinceTimestamp(for: p.id) == nil)
    }

    @MainActor
    @Test func updateProjectActivityCleansOrphanedEntries() {
        let p = makeProject(name: "Proj")
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [])

        let ghostId = UUID()
        store._setActiveSinceTimestamp(projectId: ghostId, date: Date())
        #expect(store._activeSinceTimestamp(for: ghostId) != nil)

        store.updateProjectActivityFromIndicatorStates(now: { Date() })

        #expect(store._activeSinceTimestamp(for: ghostId) == nil)
    }

    // MARK: - Project Activity Color (Unit 3)

    @Test func activityColorIsTerracottaWhenAnySessionIsActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Live", lastActiveAt: now)
        let s = makeSession(projectId: p.id)
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [s],
            indicatorStates: [s.id: .processing],
            now: { now }
        )
        #expect(color == WorkspaceLayout.waitingTerracotta)
    }

    @Test func activityColorTerracottaWinsOverRecentTimestamp() {
        // Even if `lastActiveAt` is way in the past, a live active session
        // overrides — the project is currently working.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Live", lastActiveAt: now.addingTimeInterval(-48 * 3600))
        let s = makeSession(projectId: p.id)
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [s],
            indicatorStates: [s.id: .waiting],
            now: { now }
        )
        #expect(color == WorkspaceLayout.waitingTerracotta)
    }

    @Test func activityColorIsNormalWhenRecentButNotActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Recent", lastActiveAt: now.addingTimeInterval(-3600))
        let s = makeSession(projectId: p.id)
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [s],
            indicatorStates: [s.id: .idle],
            now: { now }
        )
        #expect(color == WorkspaceLayout.activityNormalForeground)
    }

    @Test func activityColorIsMutedWhenStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Stale", lastActiveAt: now.addingTimeInterval(-48 * 3600))
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [],
            indicatorStates: [:],
            now: { now }
        )
        #expect(color == WorkspaceLayout.activityMutedForeground)
    }

    @Test func activityColorIsMutedWhenLastActiveIsNil() {
        // Brand-new project, no timestamp yet → muted.
        let p = makeProject(name: "Brand New", lastActiveAt: nil)
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [],
            indicatorStates: [:],
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(color == WorkspaceLayout.activityMutedForeground)
    }

    @Test func activityColorIgnoresSessionsBelongingToOtherProjects() {
        // A processing session in *another* project must not turn this
        // project's ghost terracotta.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = makeProject(name: "Quiet", lastActiveAt: now.addingTimeInterval(-3600))
        let other = makeProject(name: "Other")
        let foreignSession = makeSession(projectId: other.id)
        let color = WorkspaceStore.projectActivityColor(
            project: p,
            sessions: [foreignSession],
            indicatorStates: [foreignSession.id: .processing],
            now: { now }
        )
        #expect(color == WorkspaceLayout.activityNormalForeground)
    }

    @Test func activityColorTwentyFourHourBoundaryIsInclusive() {
        // Mirrors the section-bucketing rule — a project active exactly 24h
        // ago still reads as "recent" (normal color, not muted).
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exactly24h = makeProject(
            name: "Edge",
            lastActiveAt: now.addingTimeInterval(-24 * 3600)
        )
        let justOver = makeProject(
            name: "Over",
            lastActiveAt: now.addingTimeInterval(-24 * 3600 - 1)
        )
        #expect(
            WorkspaceStore.projectActivityColor(
                project: exactly24h,
                sessions: [],
                indicatorStates: [:],
                now: { now }
            ) == WorkspaceLayout.activityNormalForeground
        )
        #expect(
            WorkspaceStore.projectActivityColor(
                project: justOver,
                sessions: [],
                indicatorStates: [:],
                now: { now }
            ) == WorkspaceLayout.activityMutedForeground
        )
    }

    // MARK: - Flat Visual Order (Unit 3)

    @MainActor
    @Test func flatProjectsInVisualOrderConcatenatesSections() {
        // pinned A, activeNow B, recent C, all D — flat order should mirror
        // the section render order, with intra-section ordering preserved.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pinned = makeProject(name: "Pinned", isPinned: true)
        let active = makeProject(name: "Active")
        let recent = makeProject(name: "Recent", lastActiveAt: now.addingTimeInterval(-3600))
        let stale = makeProject(name: "Stale")
        let activeSession = makeSession(projectId: active.id)

        let store = WorkspaceStore(
            testingProjects: [stale, recent, active, pinned],
            testingSessions: [activeSession]
        )
        store.updateIndicatorState(id: activeSession.id, state: .processing)

        let visual = store.flatProjectsInVisualOrder.map(\.name)
        #expect(visual == ["Pinned", "Active", "Recent", "Stale"])
    }

    @MainActor
    @Test func sectionSignatureChangesWhenLayoutChanges() {
        // Set up so the initial alphabetical order has Zeta last; pinning Zeta
        // should hoist it to the front of the flat visual order.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = makeProject(name: "Alpha", lastActiveAt: now)
        let zeta = makeProject(name: "Zeta", lastActiveAt: now)
        let store = WorkspaceStore(
            testingProjects: [alpha, zeta],
            testingSessions: []
        )

        let initial = store.sectionSignature
        #expect(initial == [alpha.id, zeta.id])

        // Promote `zeta` into pinned — pinned section sorts above recent, so
        // the flat order flips and the signature must change.
        store.togglePin(id: zeta.id)
        let afterPin = store.sectionSignature

        #expect(initial != afterPin)
        #expect(afterPin == [zeta.id, alpha.id])
    }

    // MARK: - Record Activity (Unit 5)

    @MainActor
    @Test func recordActivityUpdatesBothProjectAndSessionTimestamps() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        let now = Date(timeIntervalSince1970: 5_000)
        store.recordActivity(sessionId: s.id, projectId: p.id, now: { now })

        #expect(store.projects.first(where: { $0.id == p.id })?.lastActiveAt == now)
        #expect(store.sessions.first(where: { $0.id == s.id })?.lastActiveAt == now)
    }

    @MainActor
    @Test func recordActivityOnActiveSessionUpdatesGraceTracker() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        // Mark the session as actively processing — write-through must extend
        // the grace tracker.
        store.updateIndicatorState(id: s.id, state: .processing)

        let now = Date(timeIntervalSince1970: 5_000)
        store.recordActivity(sessionId: s.id, projectId: p.id, now: { now })

        #expect(store._activeSinceTimestamp(for: p.id) == now)
    }

    @MainActor
    @Test func recordActivityOnIdleSessionDoesNotTouchGraceTracker() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        // Idle activity (focus, prompt-time output) is a recency signal — it
        // must update lastActiveAt but must NOT extend `.activeNow` grace.
        store.updateIndicatorState(id: s.id, state: .idle)

        let now = Date(timeIntervalSince1970: 5_000)
        store.recordActivity(sessionId: s.id, projectId: p.id, now: { now })

        #expect(store.projects.first(where: { $0.id == p.id })?.lastActiveAt == now)
        #expect(store._activeSinceTimestamp(for: p.id) == nil)
    }

    @MainActor
    @Test func recordActivityWithNoIndicatorStateDoesNotTouchGraceTracker() {
        // A brand-new session has no entry in globalIndicatorStates.
        // Write-through must still update timestamps, but not grace.
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        let now = Date(timeIntervalSince1970: 5_000)
        store.recordActivity(sessionId: s.id, projectId: p.id, now: { now })

        #expect(store.sessions.first(where: { $0.id == s.id })?.lastActiveAt == now)
        #expect(store._activeSinceTimestamp(for: p.id) == nil)
    }

    @MainActor
    @Test func recordActivityWithStaleSessionIdIsNoOp() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        let originalProjectTimestamp = store.projects.first?.lastActiveAt
        let originalSessionTimestamp = store.sessions.first?.lastActiveAt

        // Bogus session id — must not crash and must not write.
        store.recordActivity(
            sessionId: UUID(),
            projectId: p.id,
            now: { Date(timeIntervalSince1970: 5_000) }
        )

        #expect(store.projects.first?.lastActiveAt == originalProjectTimestamp)
        #expect(store.sessions.first?.lastActiveAt == originalSessionTimestamp)
        #expect(store._activeSinceTimestamp(for: p.id) == nil)
    }

    @MainActor
    @Test func recordActivityWithStaleProjectIdIsNoOp() {
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        let originalProjectTimestamp = store.projects.first?.lastActiveAt
        let originalSessionTimestamp = store.sessions.first?.lastActiveAt

        // Real session id, bogus project id — must not crash and must not write.
        store.recordActivity(
            sessionId: s.id,
            projectId: UUID(),
            now: { Date(timeIntervalSince1970: 5_000) }
        )

        #expect(store.projects.first?.lastActiveAt == originalProjectTimestamp)
        #expect(store.sessions.first?.lastActiveAt == originalSessionTimestamp)
    }

    @MainActor
    @Test func recordActivityIsMonotonic() {
        // Rapid repeat calls must never roll lastActiveAt backward, even if
        // the injected clock somehow reports a non-increasing time.
        let p = makeProject(name: "Proj")
        let s = makeSession(projectId: p.id)
        let store = WorkspaceStore(testingProjects: [p], testingSessions: [s])

        let later = Date(timeIntervalSince1970: 5_000)
        let earlier = Date(timeIntervalSince1970: 4_000)

        store.recordActivity(sessionId: s.id, projectId: p.id, now: { later })
        store.recordActivity(sessionId: s.id, projectId: p.id, now: { earlier })

        // Later timestamp wins — clock skew or test-clock weirdness must not
        // demote a project that just touched.
        #expect(store.projects.first?.lastActiveAt == later)
        #expect(store.sessions.first?.lastActiveAt == later)
    }

    @MainActor
    @Test func recordActivityWritesThroughFreezeButLayoutStaysSnapshotted() {
        // Freeze guarantees layout stability while the user is in the sidebar.
        // Activity write-through must still flow into the underlying state so
        // the next release reflects all accumulated mutations.
        let active = makeProject(name: "Active")
        let stale = makeProject(name: "Stale")
        let s = makeSession(projectId: active.id)
        let store = WorkspaceStore(testingProjects: [active, stale], testingSessions: [s])

        // Pre-freeze: nothing active → both in `.all`.
        #expect(Set(ids(in: .all, of: store.sectionedProjects)) == Set([active.id, stale.id]))

        store.freezeSnapshot()
        let snapshotIds = store.sectionedProjects.flatMap { $0.1.map(\.id) }

        // While frozen: an active session emits output. Mark the session active
        // first so the grace tracker engages.
        store.updateIndicatorState(id: s.id, state: .processing)
        let now = Date(timeIntervalSince1970: 9_999)
        store.recordActivity(sessionId: s.id, projectId: active.id, now: { now })

        // Underlying state is mutated…
        #expect(store.projects.first(where: { $0.id == active.id })?.lastActiveAt == now)
        #expect(store._activeSinceTimestamp(for: active.id) == now)

        // …but `sectionedProjects` still returns the snapshot.
        #expect(store.sectionedProjects.flatMap { $0.1.map(\.id) } == snapshotIds)
        #expect(ids(in: .activeNow, of: store.sectionedProjects).isEmpty)

        // After release, layout reflects the mutation.
        store.releaseSnapshot()
        #expect(ids(in: .activeNow, of: store.sectionedProjects) == [active.id])
    }

    // MARK: - Perf Sanity

    @Test func computationIsFastFor50ProjectsWith200Sessions() {
        // Perf budget: median < 16ms for 50 projects × 200 total sessions.
        // Use a simple wall-clock measurement across multiple iterations and
        // assert on the median. This is a sanity check, not a benchmark.
        let now = Date(timeIntervalSince1970: 1_000_000)
        var projects: [Project] = []
        var sessions: [AgentSession] = []
        var indicators: [UUID: SessionIndicatorState] = [:]
        var timestamps: [UUID: Date] = [:]

        for i in 0..<50 {
            let p = makeProject(
                name: "Project \(i)",
                isPinned: i < 3,
                lastActiveAt: now.addingTimeInterval(-Double(i * 60))
            )
            projects.append(p)
            if i % 5 == 0 {
                timestamps[p.id] = now.addingTimeInterval(-30)
            }
        }
        // 200 sessions total, 4 per project.
        for p in projects {
            for j in 0..<4 {
                let s = makeSession(
                    name: "Session \(j)",
                    projectId: p.id,
                    lastActiveAt: now.addingTimeInterval(-Double(j * 300))
                )
                sessions.append(s)
                if j == 0 {
                    indicators[s.id] = .processing
                }
            }
        }

        var measurements: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            _ = WorkspaceStore.computeSectionedProjects(
                projects: projects,
                sessions: sessions,
                indicatorStates: indicators,
                activeSinceTimestamps: timestamps,
                gracePeriod: 120,
                now: { now }
            )
            measurements.append(Date().timeIntervalSince(start))
        }
        measurements.sort()
        let median = measurements[measurements.count / 2]
        // 16ms = 0.016s. Comment on measured result lives in test report.
        #expect(median < 0.016, "median computation time \(median)s exceeded 16ms budget")
    }

    // MARK: - Empty-Section QA (Unit 6)

    @Test func sectionedProjectsReturnsOnlyNonEmptyAllSection() async {
        // Seed with three projects that all fall into `.all` (not pinned, no
        // recent activity, no live sessions). The returned section list must
        // contain exactly one entry — no phantom Pinned/Active/Recent buckets.
        let now = Date(timeIntervalSince1970: 2_000_000)
        let p1 = makeProject(name: "Alpha", isPinned: false, lastActiveAt: nil)
        let p2 = makeProject(name: "Beta", isPinned: false, lastActiveAt: nil)
        let p3 = makeProject(
            name: "Gamma",
            isPinned: false,
            // Strictly older than 24h — falls to `.all`, not `.recent`.
            lastActiveAt: now.addingTimeInterval(-25 * 60 * 60)
        )

        let result = WorkspaceStore.computeSectionedProjects(
            projects: [p1, p2, p3],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { now }
        )

        #expect(result.count == 1, "Expected exactly one non-empty section, got \(result.count)")
        #expect(populatedSections(result) == [.all])
        #expect(names(in: .all, of: result) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func sectionedProjectsHasNoEntriesForCompletelyEmptyStore() async {
        let result = WorkspaceStore.computeSectionedProjects(
            projects: [],
            sessions: [],
            indicatorStates: [:],
            activeSinceTimestamps: [:],
            gracePeriod: 120,
            now: { Date() }
        )
        #expect(result.isEmpty)
    }

    // MARK: - Pin Migration Notice State (Unit 6)

    @Test @MainActor func dismissPinMigrationNoticeFlipsFlag() {
        let store = WorkspaceStore(
            hasShownPinMigrationNotice: true,
            hasDismissedPinMigrationNotice: false
        )
        #expect(store.hasShownPinMigrationNotice == true)
        #expect(store.hasDismissedPinMigrationNotice == false)
        store.dismissPinMigrationNotice()
        #expect(store.hasDismissedPinMigrationNotice == true)
    }

    @Test @MainActor func dismissPinMigrationNoticeIsIdempotent() {
        let store = WorkspaceStore(
            hasShownPinMigrationNotice: true,
            hasDismissedPinMigrationNotice: true
        )
        store.dismissPinMigrationNotice()
        store.dismissPinMigrationNotice()
        #expect(store.hasDismissedPinMigrationNotice == true)
    }
}
