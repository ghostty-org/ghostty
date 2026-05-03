import AppKit
import Foundation
import SwiftUI

/// Central state manager for workspace projects, sessions, and templates.
///
/// Manages the global project list and session metadata shared across all windows.
/// Per-window state (like which project is selected) lives in the view layer.
/// Runtime session state (SurfaceView references) lives in SessionCoordinator.
@MainActor
final class WorkspaceStore: ObservableObject {
    /// Shared instance used by all windows. Created once on first access.
    static let shared = WorkspaceStore()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var templates: [AgentTemplate] = []

    /// Global session status — shared across all windows so that a session
    /// running in Window A shows a green dot in Window B's sidebar too.
    /// Coordinators write via `updateSessionStatus`; views read directly.
    @Published private(set) var globalStatuses: [UUID: SessionStatus] = [:]

    /// Global indicator states — the view-layer state for each running session.
    /// Updated by SessionCoordinator's activity timer; consumed by MenuBarController
    /// to render the aggregate status dot in the menu bar.
    @Published private(set) var globalIndicatorStates: [UUID: SessionIndicatorState] = [:]

    /// Current sidebar mode. Persisted across launches.
    /// `.overlay` is transient — always saved as `.closed`.
    /// Only `WorkspaceViewContainer.transitionTo(_:)` should mutate this
    /// (via `updateSidebarMode`) to keep the UI and store in sync.
    private(set) var sidebarMode: SidebarMode = .pinned {
        didSet { if oldValue != sidebarMode { persist() } }
    }

    /// Called by `WorkspaceViewContainer` after state transitions.
    func updateSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
    }

    /// The last selected project ID, used to restore selection on launch.
    var lastSelectedProjectId: UUID? {
        didSet { if oldValue != lastSelectedProjectId { persist() } }
    }

    /// The Auto Layout `topAnchor + constant` for the unified toolbar row.
    /// Derived from the live close-button frame by `WorkspaceViewContainer.layout()`
    /// and published here so the SwiftUI sidebar's `+` button stays in sync.
    /// Initial value of 22 (= 14pt traffic lights + 8pt breathing room) is updated
    /// at the first layout pass after the window appears.
    @Published var toolbarRowTopAnchorConstant: CGFloat = 22

    /// True once the one-time pin-semantics migration has run. Set by
    /// `WorkspacePersistence.load()` (or its in-memory equivalent for brand-new
    /// installs). Read by `WorkspaceSidebarView` to gate the explanatory toast.
    @Published private(set) var hasShownPinMigrationNotice: Bool = false

    /// True once the user has dismissed the post-migration toast. The toast is
    /// visible when `hasShownPinMigrationNotice && !hasDismissedPinMigrationNotice`.
    @Published private(set) var hasDismissedPinMigrationNotice: Bool = false

    /// Mark the post-migration toast as dismissed and persist. No-op if already
    /// dismissed so repeat calls don't churn the persistence task.
    func dismissPinMigrationNotice() {
        guard !hasDismissedPinMigrationNotice else { return }
        hasDismissedPinMigrationNotice = true
        persist()
    }

    /// Test-only initializer. Bypasses disk persistence and preset loading so
    /// tests can exercise section computation, grace-period logic, and the
    /// freeze snapshot without touching the real shared instance.
    #if DEBUG
    init(
        testingProjects: [Project] = [],
        testingSessions: [AgentSession] = [],
        hasShownPinMigrationNotice: Bool = true,
        hasDismissedPinMigrationNotice: Bool = true
    ) {
        self.projects = testingProjects
        self.sessions = testingSessions
        self.sidebarMode = .pinned
        self.lastSelectedProjectId = nil
        self.templates = AgentTemplate.defaults
        self.hasShownPinMigrationNotice = hasShownPinMigrationNotice
        self.hasDismissedPinMigrationNotice = hasDismissedPinMigrationNotice
        self.persistenceDisabled = true
    }

    /// When `true`, `persist()` is a no-op. Set by the test-only init so that
    /// mutating helpers like `recordActivity` don't pollute the real
    /// `~/Library/Application Support/Ghostties/workspace.json`.
    private let persistenceDisabled: Bool
    #else
    private let persistenceDisabled: Bool = false
    #endif

    private init() {
        let state = WorkspacePersistence.load()
        self.projects = state.projects
        self.sessions = state.sessions
        self.sidebarMode = state.sidebarMode
        self.lastSelectedProjectId = state.lastSelectedProjectId
        self.hasShownPinMigrationNotice = state.hasShownPinMigrationNotice
        self.hasDismissedPinMigrationNotice = state.hasDismissedPinMigrationNotice
        #if DEBUG
        self.persistenceDisabled = false
        #endif

        // Pin migration is a layout-changing event but `frozenSnapshot` defaults
        // to nil, so there's nothing to release here — see Unit 4 for the
        // freeze/release contract.

        // Seed bundled presets to ~/.ghostties/presets/ on first launch.
        PresetLoader.seedIfNeeded()

        // Load file-based presets from ~/.ghostties/presets/ and sanitize them.
        let presets = PresetLoader.loadPresets().map {
            WorkspacePersistence.sanitizeTemplate($0)
        }

        // Merge persisted custom templates with built-in defaults and presets.
        // Order: presets first, then built-in defaults, then custom templates.
        let customTemplates = state.templates.filter { !$0.isDefault }
        self.templates = presets + AgentTemplate.defaults + customTemplates
    }

    // MARK: - Smart Sections

    /// Grace period (seconds) during which a project remains in `.activeNow`
    /// after its last active session quiets. Prevents the list from thrashing
    /// on bursty agent output or mid-thought pauses.
    nonisolated static let activeGracePeriod: TimeInterval = 120

    /// Per-project timestamp: the last moment *any* session in this project was
    /// in an active indicator state (`.processing`, `.waiting`, `.longRunning`,
    /// `.needsAttention`). Drives the grace-period tail of `.activeNow`.
    ///
    /// Ephemeral — not persisted. Populated by `updateProjectActivityFromIndicatorStates()`.
    private var activeSinceTimestamps: [UUID: Date] = [:]

    /// When non-nil, `sectionedProjects` returns this snapshot verbatim instead
    /// of recomputing. Views freeze/release to prevent the list from reordering
    /// while the user is working in the sidebar.
    private var frozenSnapshot: SectionedProjects?

    /// Four-section sidebar layout: `.pinned`, `.activeNow`, `.recent`, `.all`.
    /// Empty sections are dropped. While a freeze snapshot is held, returns the
    /// snapshot verbatim (mutations update internal state but not layout).
    var sectionedProjects: SectionedProjects {
        if let frozen = frozenSnapshot { return frozen }
        return Self.computeSectionedProjects(
            projects: projects,
            sessions: sessions,
            indicatorStates: globalIndicatorStates,
            activeSinceTimestamps: activeSinceTimestamps,
            gracePeriod: Self.activeGracePeriod
        )
    }

    /// Flat list of projects in the visual (sectioned) order users see in the
    /// sidebar — `.pinned` → `.activeNow` → `.recent` → `.all`. Use this for
    /// keyboard-nav adjacency and any other "what comes next/previous on screen"
    /// computations.
    var flatProjectsInVisualOrder: [Project] {
        sectionedProjects.flatMap { $0.1 }
    }

    /// Deterministic signature of the current section layout — an ordered list
    /// of project IDs. Views can attach `.animation(.default, value:)` to this
    /// so SwiftUI animates only when the actual ordering changes, not on every
    /// `@Published` mutation.
    var sectionSignature: [UUID] {
        flatProjectsInVisualOrder.map(\.id)
    }

    /// Session grouping for an expanded project. Returns `(bucket, sessions)`
    /// pairs for the non-empty buckets, in order `.active` → `.recent` → `.idle`.
    /// Sessions are alphabetical within each bucket.
    func sessionGroups(forProject projectId: UUID) -> [(SessionBucket, [AgentSession])] {
        Self.computeSessionGroups(
            projectId: projectId,
            sessions: sessions,
            indicatorStates: globalIndicatorStates
        )
    }

    #if DEBUG
    /// Test hook — seed the grace-period tracker directly. Production code must
    /// use `updateProjectActivityFromIndicatorStates()` instead.
    func _setActiveSinceTimestamp(projectId: UUID, date: Date?) {
        if let date {
            activeSinceTimestamps[projectId] = date
        } else {
            activeSinceTimestamps.removeValue(forKey: projectId)
        }
    }

    /// Test hook — read the raw tracker value for a project.
    func _activeSinceTimestamp(for projectId: UUID) -> Date? {
        activeSinceTimestamps[projectId]
    }
    #endif

    /// Record activity for a session and its parent project — the unified
    /// write-through called by `SessionCoordinator` from output, focus, and
    /// session-creation triggers.
    ///
    /// Updates:
    ///   - `session.lastActiveAt = now()` (project drives `.recent` bucket)
    ///   - `project.lastActiveAt = now()`
    ///   - `activeSinceTimestamps[projectId] = now()` **only if** the session's
    ///     current indicator state is one of the active states. Idle activity
    ///     (focus, output while at prompt) is a recency signal — it must update
    ///     `lastActiveAt` for `.recent` bucketing but must NOT extend the
    ///     `.activeNow` grace window.
    ///
    /// Monotonic guard: `lastActiveAt` only advances forward. Rapid repeat calls
    /// within the same wall-clock millisecond keep the existing value if `now()`
    /// reports a non-increasing time.
    ///
    /// Silent no-op when the session or project id is stale (e.g. a Combine
    /// sink fires after the session was removed) — no crash, no write.
    ///
    /// Does NOT call `releaseSnapshot()`. Writes happen even while a freeze is
    /// held — the freeze is about layout, not data. On `releaseSnapshot()`, the
    /// next `sectionedProjects` read reflects all accumulated mutations. This
    /// is the core anti-jump rule: activity feeds the tracker but does not
    /// trigger an immediate reorder while the user is working in the sidebar.
    ///
    /// Persists through the existing 100ms debounced `persist()`. Bursty output
    /// coalesces into a single disk write.
    func recordActivity(
        sessionId: UUID,
        projectId: UUID,
        now: () -> Date = Date.init
    ) {
        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let projectIdx = projects.firstIndex(where: { $0.id == projectId })
        else { return }

        let timestamp = now()

        // Monotonic guard — never roll lastActiveAt backward.
        if let existing = sessions[sessionIdx].lastActiveAt, existing > timestamp {
            // No-op for the session timestamp; still consider the project / tracker.
        } else {
            sessions[sessionIdx].lastActiveAt = timestamp
        }
        if let existing = projects[projectIdx].lastActiveAt, existing > timestamp {
            // No-op for the project timestamp.
        } else {
            projects[projectIdx].lastActiveAt = timestamp
        }

        // Only refresh the grace tracker if this session is currently in an
        // active indicator state. Idle activity (focus, prompt-time output) is
        // a recency signal, not an active-state signal.
        if Self.isActiveIndicatorState(globalIndicatorStates[sessionId]) {
            activeSinceTimestamps[projectId] = timestamp
        }

        persist()
    }

    /// Refresh the per-project "active since" tracker from the current indicator
    /// state map. Call on indicator pushes or activity-timer ticks. Orphaned
    /// entries (project ids that no longer exist) are cleaned up here.
    ///
    /// Unit 2 exposes this method; Unit 5 wires it to the real triggers.
    func updateProjectActivityFromIndicatorStates(now: () -> Date = Date.init) {
        let validProjectIds = Set(projects.map(\.id))
        // Drop orphaned entries — their project was removed.
        activeSinceTimestamps = activeSinceTimestamps.filter { validProjectIds.contains($0.key) }

        // For every project that currently has any active session, stamp "now".
        let timestamp = now()
        for project in projects {
            let hasActiveSession = sessions.contains { session in
                session.projectId == project.id
                    && Self.isActiveIndicatorState(globalIndicatorStates[session.id])
            }
            if hasActiveSession {
                activeSinceTimestamps[project.id] = timestamp
            }
        }
    }

    /// Capture the current section layout into the freeze snapshot. Subsequent
    /// reads of `sectionedProjects` return the snapshot until `releaseSnapshot()`
    /// is called. No-op if already frozen (nested freezes don't clobber).
    func freezeSnapshot() {
        guard frozenSnapshot == nil else { return }
        frozenSnapshot = Self.computeSectionedProjects(
            projects: projects,
            sessions: sessions,
            indicatorStates: globalIndicatorStates,
            activeSinceTimestamps: activeSinceTimestamps,
            gracePeriod: Self.activeGracePeriod
        )
    }

    /// Release any held freeze snapshot. Next `sectionedProjects` read recomputes.
    /// No-op if nothing is frozen.
    func releaseSnapshot() {
        frozenSnapshot = nil
    }

    // MARK: - Computed (Sessions)

    /// Sessions for a specific project, ordered by sortOrder (then name for ties/nils).
    ///
    /// Sessions with an explicit `sortOrder` come first (ascending), followed by
    /// sessions without one (alphabetical). This preserves backward compatibility —
    /// old sessions that predate drag-and-drop sort alphabetically until reordered.
    func sessions(for projectId: UUID) -> [AgentSession] {
        sessions.filter { $0.projectId == projectId }
            .sorted { a, b in
                switch (a.sortOrder, b.sortOrder) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    // MARK: - Project Actions

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        // Don't add duplicates (same path).
        if let index = projects.firstIndex(where: { $0.rootPath == path }) {
            projects[index].isPinned = true
            // Re-pinning is a structural change — release any held freeze snapshot
            // so the sidebar re-buckets immediately.
            releaseSnapshot()
            persist()
            return
        }

        let usedGhosts = Set(projects.compactMap(\.ghostCharacter))
        let project = Project(
            name: url.lastPathComponent,
            rootPath: path,
            isPinned: true,
            ghostCharacter: GhostCharacter.randomUnused(excluding: usedGhosts)
        )
        projects.append(project)
        // Adding a project is a fresh layout commit point — drop the freeze snapshot
        // so the new project shows up in its correct section immediately.
        releaseSnapshot()
        persist()
    }

    func removeProject(id: UUID) {
        // Notify coordinators so they can close running sessions before we delete records.
        NotificationCenter.default.post(
            name: .workspaceProjectWillBeRemoved,
            object: nil,
            userInfo: ["projectId": id]
        )

        // Remove sessions belonging to this project, then the project itself.
        sessions.removeAll { $0.projectId == id }
        projects.removeAll { $0.id == id }
        if lastSelectedProjectId == id { lastSelectedProjectId = nil }
        // Project removal is a structural change — release any held freeze snapshot
        // so the deleted project disappears immediately and remaining projects re-bucket.
        releaseSnapshot()
        persist()
    }

    func togglePin(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isPinned.toggle()
        persist()
    }

    // MARK: - Session Actions

    @discardableResult
    func addSession(name: String, templateId: UUID, projectId: UUID) -> AgentSession {
        let maxOrder = sessions.filter { $0.projectId == projectId }
            .compactMap(\.sortOrder).max() ?? -1
        let session = AgentSession(
            name: name,
            templateId: templateId,
            projectId: projectId,
            sortOrder: maxOrder + 1
        )
        sessions.append(session)
        // Session creation is a user action and a fresh layout commit point —
        // release any held freeze snapshot so the parent project re-buckets
        // immediately on the next sidebar read.
        releaseSnapshot()
        persist()
        return session
    }

    func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    /// Rename a session in place.
    func renameSession(id: UUID, name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = name
        persist()
    }

    /// Move a session to a new position within its project.
    func moveSession(id: UUID, toIndex newIndex: Int, inProject projectId: UUID) {
        var projectSessions = sessions(for: projectId)
        guard let fromIndex = projectSessions.firstIndex(where: { $0.id == id }),
              newIndex >= 0, newIndex < projectSessions.count else { return }

        let moved = projectSessions.remove(at: fromIndex)
        projectSessions.insert(moved, at: newIndex)

        // Reassign sortOrder values for all sessions in this project.
        for (order, session) in projectSessions.enumerated() {
            if let globalIndex = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[globalIndex].sortOrder = order
            }
        }
        persist()
    }

    // MARK: - Project Mutation

    /// Update a project's display name, ghost character, and/or default template.
    func updateProject(id: UUID, name: String? = nil, ghostCharacter: GhostCharacter? = nil, defaultTemplateId: UUID? = nil) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        if let name { projects[index].name = name }
        if let ghost = ghostCharacter { projects[index].ghostCharacter = ghost }
        if let templateId = defaultTemplateId { projects[index].defaultTemplateId = templateId }
        persist()
    }

    /// Clear a project's default template (user picked "None" / "Always ask").
    func clearDefaultTemplate(for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[index].defaultTemplateId = nil
        persist()
    }

    // MARK: - Session Status

    /// Update a single session's global status (called by coordinators).
    func updateSessionStatus(id: UUID, status: SessionStatus) {
        globalStatuses[id] = status
    }

    /// Remove a session's global status entry (called on cleanup).
    func removeSessionStatus(id: UUID) {
        globalStatuses.removeValue(forKey: id)
    }

    // MARK: - Indicator State (Menu Bar)

    /// Update a session's view-layer indicator state for menu bar consumption.
    func updateIndicatorState(id: UUID, state: SessionIndicatorState) {
        globalIndicatorStates[id] = state
    }

    /// Remove a session's indicator state entry (called on cleanup).
    func removeIndicatorState(id: UUID) {
        globalIndicatorStates.removeValue(forKey: id)
    }

    // MARK: - Template Actions

    @discardableResult
    func addTemplate(_ template: AgentTemplate) -> AgentTemplate {
        let sanitized = WorkspacePersistence.sanitizeTemplate(template)
        templates.append(sanitized)
        persist()
        return sanitized
    }

    func updateTemplate(
        id: UUID,
        name: String? = nil,
        kind: AgentTemplate.Kind? = nil,
        command: String? = nil,
        environmentVariables: [String: String]? = nil,
        workingDirectory: String? = nil,
        isGlobal: Bool? = nil,
        projectId: UUID?? = nil,
        agent: AgentTemplate.AgentConfig?? = nil
    ) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        guard !templates[index].isDefault else { return }
        if let name { templates[index].name = name }
        if let kind { templates[index].kind = kind }
        if let command { templates[index].command = command }
        if let environmentVariables { templates[index].environmentVariables = environmentVariables }
        if let workingDirectory { templates[index].workingDirectory = workingDirectory }
        if let isGlobal { templates[index].isGlobal = isGlobal }
        if let projectId { templates[index].projectId = projectId }
        if let agent { templates[index].agent = agent }
        templates[index] = WorkspacePersistence.sanitizeTemplate(templates[index])
        persist()
    }

    @discardableResult
    func duplicateTemplate(id: UUID) -> AgentTemplate? {
        guard let original = templates.first(where: { $0.id == id }) else { return nil }
        // NOTE: Update this if AgentTemplate gains new stored properties.
        // id is `let`, so encode/decode can't assign a fresh UUID — memberwise init is required.
        let copy = AgentTemplate(
            name: "Copy of \(original.name)",
            kind: original.kind,
            command: original.command,
            environmentVariables: original.environmentVariables,
            workingDirectory: original.workingDirectory,
            isGlobal: original.isGlobal,
            projectId: original.projectId,
            agent: original.agent,
            templateDescription: original.templateDescription,
            icon: original.icon,
            accessLabel: original.accessLabel
        )
        let sanitized = WorkspacePersistence.sanitizeTemplate(copy)
        templates.append(sanitized)
        persist()
        return sanitized
    }

    func removeTemplate(id: UUID) {
        guard let template = templates.first(where: { $0.id == id }),
              !template.isDefault else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Whether any session references a given template.
    func templateInUse(id: UUID) -> Bool {
        sessions.contains { $0.templateId == id }
    }

    /// Returns templates available for a given project context.
    /// Global templates are always included, plus any scoped to the specific project.
    func templates(for projectId: UUID?) -> [AgentTemplate] {
        templates.filter { template in
            template.isGlobal || template.projectId == projectId
        }
    }

    // MARK: - Folder Picker

    /// Presents an NSOpenPanel and adds the selected directory as a project.
    /// Returns the new or existing project's ID, or nil if the user cancelled.
    @discardableResult
    func addProjectViaFolderPicker() -> UUID? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        addProject(at: url)
        return projects.first(where: {
            $0.rootPath == url.standardizedFileURL.path
        })?.id
    }

    // MARK: - Project Activity Color

    /// Three-state activity color for a project's ghost icon in the sidebar:
    ///
    /// - **Terracotta** (`WorkspaceLayout.waitingTerracotta`) when any session in
    ///   the project is in an active indicator state
    ///   (`.processing` / `.waiting` / `.longRunning` / `.needsAttention`).
    /// - **Normal** (`WorkspaceLayout.activityNormalForeground`) when no active
    ///   session but `lastActiveAt` is within 24h.
    /// - **Muted** (`WorkspaceLayout.activityMutedForeground`) otherwise.
    func projectActivityColor(for project: Project, now: () -> Date = Date.init) -> Color {
        Self.projectActivityColor(
            project: project,
            sessions: sessions,
            indicatorStates: globalIndicatorStates,
            now: now
        )
    }

    /// Pure-static variant of `projectActivityColor(for:)` for testing.
    nonisolated static func projectActivityColor(
        project: Project,
        sessions: [AgentSession],
        indicatorStates: [UUID: SessionIndicatorState],
        now: () -> Date = Date.init
    ) -> Color {
        let hasActive = sessions.contains { session in
            session.projectId == project.id
                && isActiveIndicatorState(indicatorStates[session.id])
        }
        if hasActive { return WorkspaceLayout.waitingTerracotta }

        let recentWindow: TimeInterval = 24 * 60 * 60
        if let lastActiveAt = project.lastActiveAt,
           now().timeIntervalSince(lastActiveAt) <= recentWindow {
            return WorkspaceLayout.activityNormalForeground
        }
        return WorkspaceLayout.activityMutedForeground
    }

    // MARK: - Section Computation (pure helpers)

    /// Returns true for indicator states that count as "active" for sidebar bucketing:
    /// `.processing`, `.waiting`, `.longRunning`, `.needsAttention`.
    nonisolated static func isActiveIndicatorState(_ state: SessionIndicatorState?) -> Bool {
        switch state {
        case .processing, .waiting, .longRunning, .needsAttention:
            return true
        case .inactive, .idle, .error, .none:
            return false
        }
    }

    /// Pure function that bucketizes projects into the four sidebar sections.
    /// Exposed as `static` for deterministic testing with injected clock + state.
    ///
    /// Rules (highest-priority match wins — a project lives in exactly one section):
    /// - `.pinned`     — `project.isPinned == true`
    /// - `.activeNow`  — any session is in an active indicator state **or** the
    ///                   project is within `gracePeriod` seconds of last-active
    /// - `.recent`     — `project.lastActiveAt` within the past 24h (inclusive)
    /// - `.all`        — everything else
    ///
    /// Intra-section order:
    /// - `.pinned`    — alphabetical (stable until Unit 6 adds user-chosen order)
    /// - `.activeNow` — alphabetical (case-insensitive)
    /// - `.recent`    — chronological by `project.lastActiveAt` descending
    /// - `.all`       — alphabetical (case-insensitive)
    ///
    /// Empty sections are dropped from the returned array.
    ///
    /// 24h boundary is **inclusive**: a project with `lastActiveAt` exactly 24h
    /// ago falls in `.recent`. Strictly older than 24h falls in `.all`.
    ///
    /// Grace period boundary is **exclusive** (`< gracePeriod`): at exactly
    /// `gracePeriod` seconds since last active, the project has aged out.
    nonisolated static func computeSectionedProjects(
        projects: [Project],
        sessions: [AgentSession],
        indicatorStates: [UUID: SessionIndicatorState],
        activeSinceTimestamps: [UUID: Date],
        gracePeriod: TimeInterval,
        now: () -> Date = Date.init
    ) -> SectionedProjects {
        let currentDate = now()
        let recentWindow: TimeInterval = 24 * 60 * 60  // 24h

        var pinned: [Project] = []
        var activeNow: [Project] = []
        var recent: [Project] = []
        var all: [Project] = []

        // Pre-group sessions by project id to avoid O(n*m) scans.
        var sessionsByProject: [UUID: [AgentSession]] = [:]
        for session in sessions {
            sessionsByProject[session.projectId, default: []].append(session)
        }

        for project in projects {
            if project.isPinned {
                pinned.append(project)
                continue
            }

            let projectSessions = sessionsByProject[project.id] ?? []
            let hasLiveActive = projectSessions.contains { session in
                isActiveIndicatorState(indicatorStates[session.id])
            }

            let inGrace: Bool = {
                guard let lastActive = activeSinceTimestamps[project.id] else { return false }
                return currentDate.timeIntervalSince(lastActive) < gracePeriod
            }()

            if hasLiveActive || inGrace {
                activeNow.append(project)
                continue
            }

            if let lastActiveAt = project.lastActiveAt,
               currentDate.timeIntervalSince(lastActiveAt) <= recentWindow {
                recent.append(project)
                continue
            }

            all.append(project)
        }

        // Alphabetical (case-insensitive) for pinned / activeNow / all.
        let alpha: (Project, Project) -> Bool = { a, b in
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        pinned.sort(by: alpha)
        activeNow.sort(by: alpha)
        all.sort(by: alpha)
        // Recent: chronological descending by lastActiveAt (most recent first).
        // Nil timestamps shouldn't land here by construction, but sort them last
        // deterministically if they do (alphabetical tiebreaker).
        recent.sort { a, b in
            switch (a.lastActiveAt, b.lastActiveAt) {
            case let (lhs?, rhs?):
                if lhs == rhs { return alpha(a, b) }
                return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return alpha(a, b)
            }
        }

        var result: SectionedProjects = []
        if !pinned.isEmpty {
            result.append((.pinned, pinned))
        }
        if !activeNow.isEmpty {
            result.append((.activeNow, activeNow))
        }
        if !recent.isEmpty {
            result.append((.recent, recent))
        }
        if !all.isEmpty {
            result.append((.all, all))
        }
        return result
    }

    /// Pure function that groups the sessions of a single project into the
    /// three expanded-view buckets. Empty buckets are dropped.
    ///
    /// Rules (highest-priority match wins):
    /// - `.active` — indicator state is `.processing`/`.waiting`/`.longRunning`/`.needsAttention`
    /// - `.recent` — not active and `lastActiveAt` within the past 24h (inclusive)
    /// - `.idle`   — everything else
    ///
    /// Sessions are alphabetical (case-insensitive) within each bucket.
    nonisolated static func computeSessionGroups(
        projectId: UUID,
        sessions: [AgentSession],
        indicatorStates: [UUID: SessionIndicatorState],
        now: () -> Date = Date.init
    ) -> [(SessionBucket, [AgentSession])] {
        let currentDate = now()
        let recentWindow: TimeInterval = 24 * 60 * 60

        var active: [AgentSession] = []
        var recent: [AgentSession] = []
        var idle: [AgentSession] = []

        for session in sessions where session.projectId == projectId {
            if isActiveIndicatorState(indicatorStates[session.id]) {
                active.append(session)
                continue
            }
            if let lastActiveAt = session.lastActiveAt,
               currentDate.timeIntervalSince(lastActiveAt) <= recentWindow {
                recent.append(session)
                continue
            }
            idle.append(session)
        }

        let alpha: (AgentSession, AgentSession) -> Bool = { a, b in
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        active.sort(by: alpha)
        recent.sort(by: alpha)
        idle.sort(by: alpha)

        var result: [(SessionBucket, [AgentSession])] = []
        if !active.isEmpty {
            result.append((.active, active))
        }
        if !recent.isEmpty {
            result.append((.recent, recent))
        }
        if !idle.isEmpty {
            result.append((.idle, idle))
        }
        return result
    }

    // MARK: - Private

    /// Debounced persistence — coalesces rapid mutations into a single disk write
    /// on a background thread to avoid blocking the main actor.
    private var persistTask: Task<Void, Never>?

    private func persist() {
        guard !persistenceDisabled else { return }
        persistTask?.cancel()
        persistTask = Task { [projects, sessions, templates, sidebarMode, lastSelectedProjectId, hasShownPinMigrationNotice, hasDismissedPinMigrationNotice] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let customTemplates = templates.filter { !$0.isDefault }
            // Overlay is transient — persist as closed so next launch starts closed.
            let persistedMode: SidebarMode = sidebarMode == .overlay ? .closed : sidebarMode
            let state = WorkspacePersistence.State(
                projects: projects,
                sessions: sessions,
                templates: customTemplates,
                sidebarMode: persistedMode,
                lastSelectedProjectId: lastSelectedProjectId,
                hasShownPinMigrationNotice: hasShownPinMigrationNotice,
                hasDismissedPinMigrationNotice: hasDismissedPinMigrationNotice
            )
            await Task.detached(priority: .utility) {
                WorkspacePersistence.save(state)
            }.value
        }
    }
}

// MARK: - Sidebar Section Types

/// The four sidebar sections, in the order they render from top to bottom.
enum SidebarSection: String, CaseIterable, Hashable {
    case pinned
    case activeNow
    case recent
    case all
}

/// Ordered list of `(section, projects)` pairs. Only non-empty sections are included.
/// Kept as a simple tuple-array for now; upgrade to a typed struct only if call
/// sites start needing keyed access beyond "iterate in order".
typealias SectionedProjects = [(SidebarSection, [Project])]

/// The three buckets used to group sessions inside an expanded project row.
enum SessionBucket: String, CaseIterable, Hashable {
    case active
    case recent
    case idle
}
