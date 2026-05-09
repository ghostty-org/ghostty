import SwiftUI

/// Single-column disclosure-style sidebar showing projects with expandable session lists.
///
/// Replaces the previous two-column ZStack layout (icon rail + detail panel) with a
/// Finder/Arc-style list where projects are expandable rows that reveal sessions inline.
/// Multiple projects can be expanded simultaneously.
///
/// Freeze-on-focus (plan unit 4):
/// The smart-section layout is frozen while the view's window is key and released
/// on blur, on add/remove project, and on session creation. Freeze/release is
/// driven by `WorkspaceViewContainer`'s `windowDidBecomeKey` / `windowDidResignKey`
/// observers and `WorkspaceStore`'s structural-mutation methods — see those sites
/// for the wiring. This view doesn't observe focus directly because the sidebar
/// is hosted in an `NSHostingView` whose rows aren't text-input focusable, and
/// SwiftUI `.focused()` is unreliable in that context. Window-level key state
/// is the bulletproof signal. The `.animation(value: store.sectionSignature)`
/// modifier below animates only the layout commit when the snapshot releases.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator

    /// Per-window selection state — each window can focus a different project.
    @State private var selectedProjectId: UUID?

    /// Tracks which projects are expanded (per-window, not persisted).
    @State private var expandedProjectIds: Set<UUID> = []

    @AppStorage("ghostties.hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("ghostties.sidebarTab") private var sidebarTab: SidebarTab = .projects

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar toolbar: action buttons right of traffic lights
            titlebarToolbar

            if sidebarTab == .sessions {
                // Sessions tab: flat recents list across all projects.
                RecentsListView()
            } else {
                // Projects tab: existing disclosure list.

                // One-time pin-semantics migration banner.
                if store.hasShownPinMigrationNotice && !store.hasDismissedPinMigrationNotice {
                    PinMigrationNoticeBanner(onDismiss: store.dismissPinMigrationNotice)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                // Scrollable disclosure list or empty state
                if store.sectionedProjects.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.sectionedProjects, id: \.0) { section, projects in
                                if !projects.isEmpty {
                                    SidebarSectionHeader(section: section)
                                        .padding(.top, section == .pinned ? 0 : 8)

                                    ForEach(projects) { project in
                                        ProjectDisclosureRow(
                                            project: project,
                                            isExpanded: expandedBinding(for: project.id),
                                            selectedProjectId: $selectedProjectId
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .animation(
                            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                ? nil
                                : .default,
                            value: store.sectionSignature
                        )
                    }
                    .accessibilityLabel("Projects")
                }
            }

            Spacer(minLength: 0)
        }
        .background(.clear)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            // Restore persisted project selection, or default to the first project.
            if selectedProjectId == nil {
                if let lastId = store.lastSelectedProjectId,
                   store.projects.contains(where: { $0.id == lastId }) {
                    selectedProjectId = lastId
                } else {
                    selectedProjectId = store.flatProjectsInVisualOrder.first?.id
                }
            }
            // Auto-expand the project containing the active session.
            autoExpandActiveProject()
        }
        .onChange(of: selectedProjectId) { newId in
            store.lastSelectedProjectId = newId
            // When the user clicks a different project, auto-focus its last active session.
            if let projectId = newId {
                coordinator.focusLastSession(forProject: projectId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceSelectNextProject)) { notification in
            guard notification.object as? NSWindow === coordinator.containerView?.window else { return }
            selectAdjacentProject(offset: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceSelectPreviousProject)) { notification in
            guard notification.object as? NSWindow === coordinator.containerView?.window else { return }
            selectAdjacentProject(offset: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceNewSession)) { notification in
            guard notification.object as? NSWindow === coordinator.containerView?.window else { return }
            createNewSessionForSelectedProject()
        }
        .sheet(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { _ in }
        )) {
            OnboardingSheet {
                hasSeenOnboarding = true
            }
        }
    }

    // MARK: - Titlebar Toolbar

    private var titlebarToolbar: some View {
        HStack(spacing: 8) {
            SidebarTabPicker(selectedTab: $sidebarTab)
            Spacer()
            // + button only shown in Projects tab; Sessions tab has its own header button.
            if sidebarTab == .projects {
                ToolbarIconButton(systemName: "plus", label: "Add project", action: presentFolderPicker)
            }
        }
        .padding(.horizontal, 12)
        // frame height = 2× toolbarRowTopAnchorConstant centers controls on the same
        // horizontal row as the traffic lights and the sidebar toggle.
        .frame(height: store.toolbarRowTopAnchorConstant * 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            GhostCharacterView(character: .blinky, color: Color(.tertiaryLabelColor))
                .frame(width: 48, height: 48)

            Text("Add a project to get started")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            EmptyStateAddButton(action: presentFolderPicker)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No projects. Add a project to get started.")
    }

    // MARK: - Helpers

    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIds.contains(id) },
            set: { if $0 { expandedProjectIds.insert(id) } else { expandedProjectIds.remove(id) } }
        )
    }

    /// Auto-expand the project that contains the currently active session.
    private func autoExpandActiveProject() {
        guard let activeId = coordinator.activeSessionId,
              let session = store.sessions.first(where: { $0.id == activeId }) else { return }
        expandedProjectIds.insert(session.projectId)
    }

    // MARK: - Actions

    private var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return store.projects.first { $0.id == id }
    }

    private func presentFolderPicker() {
        if let id = store.addProjectViaFolderPicker() {
            selectedProjectId = id
            expandedProjectIds.insert(id)
        }
    }

    /// Create a new session in the currently selected project.
    private func createNewSessionForSelectedProject() {
        guard let project = selectedProject else { return }
        let template: AgentTemplate
        if let defaultId = project.defaultTemplateId,
           let defaultTemplate = store.templates.first(where: { $0.id == defaultId }) {
            template = defaultTemplate
        } else {
            template = AgentTemplate.shell
        }
        // Auto-expand the target project so the new session is visible.
        expandedProjectIds.insert(project.id)
        Task {
            await coordinator.createQuickSession(for: project, template: template)
        }
    }

    /// Move selection to the next or previous project in the flattened section
    /// order (the visual order the user sees on screen), auto-expanding the
    /// target project.
    private func selectAdjacentProject(offset: Int) {
        let visualOrder = store.flatProjectsInVisualOrder
        guard !visualOrder.isEmpty else { return }

        guard let currentId = selectedProjectId,
              let currentIndex = visualOrder.firstIndex(where: { $0.id == currentId }) else {
            selectedProjectId = visualOrder.first?.id
            if let id = visualOrder.first?.id { expandedProjectIds.insert(id) }
            return
        }

        let newIndex = (currentIndex + offset + visualOrder.count) % visualOrder.count
        let targetId = visualOrder[newIndex].id
        selectedProjectId = targetId
        expandedProjectIds.insert(targetId)
    }
}

// MARK: - Pin Migration Notice Banner

/// One-time explanatory banner shown after the pin-semantics migration runs.
/// Sits at the top of the sidebar (under the toolbar) and reads like a quiet
/// note rather than an alert. Dismissed via `WorkspaceStore.dismissPinMigrationNotice()`,
/// which writes a persisted flag so it never re-appears.
private struct PinMigrationNoticeBanner: View {
    let onDismiss: () -> Void

    @State private var isCloseHovered = false

    var body: some View {
        // Matches the column structure of `ProjectDisclosureRow` so the pin
        // icon x-center aligns with row ghost icon x-center, and the text
        // x-start aligns with project NAME text.
        HStack(alignment: .top, spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceLayout.waitingTerracotta)
                .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)
                .padding(.top, 1)

            Text("Pin now means \u{201C}always on top.\u{201D} Re-pin the projects you want above the smart sections.")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseHovered ? Color.primary.opacity(0.10) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { isCloseHovered = $0 }
            .accessibilityLabel("Dismiss pin migration notice")
        }
        .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WorkspaceLayout.waitingTerracotta.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WorkspaceLayout.waitingTerracotta.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pin meaning has changed. Re-pin the projects you want above the smart sections.")
    }
}

// MARK: - Section Header

/// Small section header rendered above each non-empty group in the sidebar.
/// Uses uppercase tracking + muted foreground to recede behind the project rows
/// while still serving as a clear waypoint when scanning the list.
private struct SidebarSectionHeader: View {
    let section: SidebarSection

    var body: some View {
        // Matches the column structure of `ProjectDisclosureRow` header so
        // section icons vertically center-align with row ghost icons, and
        // section LABEL text left-aligns with project NAME text.
        HStack(spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)

            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)

            Spacer(minLength: 0)
        }
        .foregroundStyle(WorkspaceLayout.sectionHeaderForeground)
        .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        switch section {
        case .pinned:    return "Pinned"
        case .activeNow: return "Active Now"
        case .recent:    return "Recent"
        case .all:       return "All Projects"
        }
    }

    private var iconName: String {
        switch section {
        case .pinned:    return "pin.fill"
        case .activeNow: return "bolt.fill"
        case .recent:    return "clock.fill"
        case .all:       return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Empty State Add Button

/// "Add Project" button with hover feedback for the sidebar empty state.
private struct EmptyStateAddButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                Text("Add Project")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Toolbar Icon Button

/// A small icon button with hover highlight for the sidebar toolbar.
private struct ToolbarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
    }
}
