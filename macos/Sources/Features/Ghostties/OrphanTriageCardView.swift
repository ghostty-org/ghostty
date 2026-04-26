import AppKit
import SwiftUI

/// Inline triage card for orphan Inbox rows (U6 / SEA-162).
///
/// Rendered inside `InboxZoneView` immediately below the anchor row. Pushes
/// all rows below it down within the Inbox zone (D4 push mechanic — intra-zone
/// reflow). The anchor row gets a 2px terracotta left-rule while the card is
/// open (D20).
///
/// Fields: project picker (required, D6), optional template, optional title
/// edit. Confirm writes frontmatter then chains into `startInboxTask` (U4).
/// Cancel closes with no writes.
///
/// Reduced-motion: height/translate animations short-circuit to instant;
/// only opacity crossfade is used at 200ms (D19).
///
/// D26: lives flat under `macos/Sources/Features/Ghostties/`, no subdirectory.
@MainActor
struct OrphanTriageCardView: View {

    let task: TaskItem

    @ObservedObject var triageStore: OrphanTriageStore
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject var handlers: RowClickHandlersBox

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived state

    private var hasProjects: Bool { !workspaceStore.projects.isEmpty }
    private var hasSelectedProject: Bool { triageStore.selectedProjectId != nil }
    private var hasError: Bool { triageStore.errorTaskIds.contains(task.id) }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardContent
        }
        .background(cardBackground)
        .overlay(alignment: .leading) {
            // 2px terracotta left-rule on card left edge (D20).
            Rectangle()
                .fill(WorkspaceLayout.waitingTerracotta)
                .frame(width: 2)
        }
        .clipShape(Rectangle())
        // Click-outside cancels (D25). The background intercepts any tap that
        // doesn't land on an interactive control inside the card.
        .transition(revealTransition)
        .animation(revealAnimation, value: triageStore.activeTaskId)
    }

    // MARK: - Card content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Error banner (D13)
            if hasError {
                errorBanner
            }

            // Project picker (required, D6)
            projectPickerSection

            // Template picker (optional)
            templatePickerSection

            // Title edit (optional)
            titleEditSection

            // Action row
            actionRow
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Error banner (D13)

    private var errorBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text("Could not save changes. Try again.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.12))
        )
    }

    // MARK: - Project picker (D6, D7)

    @ViewBuilder
    private var projectPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("PROJECT")

            if hasProjects {
                // Picker: required, no pre-selection (D6).
                Picker("", selection: $triageStore.selectedProjectId) {
                    Text("Pick a project…")
                        .tag(Optional<UUID>.none)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))

                    ForEach(workspaceStore.projects) { project in
                        Text(project.name)
                            .tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // D7: empty projects — show terracotta-tinted [+ Add project…] chip.
                addProjectChip
            }
        }
    }

    /// D7: terracotta-tinted chip shown when `WorkspaceStore.projects` is empty.
    /// Clicking opens `NSOpenPanel`, inserts the project, auto-selects it.
    private var addProjectChip: some View {
        Button(
            action: {
                triageStore.addProjectViaFolderPicker(workspaceStore: workspaceStore)
            },
            label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add project…")
                        .font(.system(size: 11, weight: .medium))
                }
                // D20: terracotta-tinted text only on the [+ Add project…] chip.
                .foregroundStyle(WorkspaceLayout.waitingTerracotta)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(WorkspaceLayout.waitingTerracotta.opacity(0.08))
                )
            }
        )
        .buttonStyle(.plain)
        .accessibilityLabel("Add project folder")
    }

    // MARK: - Template picker (optional)

    private var templatePickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("TEMPLATE (optional)")

            // Disabled when no project selected (D7: title and template stay
            // inert until a project is added).
            Picker("Agent template (optional)", selection: $triageStore.selectedTemplateName) {
                Text("None")
                    .tag(Optional<String>.none)
                ForEach(relevantTemplates, id: \.id) { template in
                    Text(template.name)
                        .tag(Optional(template.name))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!hasSelectedProject && !hasProjects)
            .opacity((!hasSelectedProject && !hasProjects) ? 0.4 : 1)
        }
    }

    /// Templates available for this task's project context (global + project-scoped).
    private var relevantTemplates: [AgentTemplate] {
        guard let projectId = triageStore.selectedProjectId,
              let project = workspaceStore.projects.first(where: { $0.id == projectId }) else {
            return workspaceStore.templates.filter { $0.isGlobal }
        }
        return workspaceStore.templates(for: project.id)
    }

    // MARK: - Title edit (optional)

    private var titleEditSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("TITLE (optional)")

            TextField("Task title", text: $triageStore.editedTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: colorScheme == .dark
                            ? .controlBackgroundColor
                            : .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .disabled(!hasSelectedProject && !hasProjects)
                .opacity((!hasSelectedProject && !hasProjects) ? 0.4 : 1)
                // FYI-2: VoiceOver label for the title edit field.
                .accessibilityLabel("Task title (optional)")
                .accessibilityHint("Override the task title before assigning it to a project")
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            // Cancel
            Button("Cancel") {
                triageStore.cancel()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .keyboardShortcut(.cancelAction)

            // Confirm — neutral chrome, never terracotta (D20).
            Button("Assign") {
                triageStore.confirm(
                    task: task,
                    taskStore: taskStore,
                    workspaceStore: workspaceStore,
                    handlers: handlers.value
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .controlAccentColor))
            .font(.system(size: 11, weight: .semibold))
            .disabled(!triageStore.canConfirm)
            .keyboardShortcut(.defaultAction)
            // FYI-2: VoiceOver label for the confirm button.
            .accessibilityLabel("Assign task to project")
            .accessibilityHint("Assigns the task to the selected project and starts it")
        }
    }

    // MARK: - Field label helper

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }

    // MARK: - Background

    private var cardBackground: some View {
        Color(nsColor: colorScheme == .dark
            ? WorkspaceLayout.canvasBackgroundDark
            : WorkspaceLayout.canvasBackgroundLight)
    }

    // MARK: - Animation (D18, D19) — tokens from WorkspaceLayout.Animation

    /// Card reveal: uses `.sidebarPush` token (D18).
    /// Reduced-motion: `.sidebarReducedMotion` opacity crossfade only (D19).
    private var revealAnimation: Animation {
        reduceMotion ? .sidebarReducedMotion : .sidebarPush
    }

    /// Transition: slide+opacity in full-motion mode; opacity-only in
    /// reduced-motion mode (D19).
    private var revealTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity.animation(.sidebarReducedMotion)
            : AnyTransition.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            ).animation(.sidebarCollapse)
    }
}

// MARK: - RowClickHandlersBox

/// Value-type `RowClickHandlers` can't be observed by SwiftUI directly since
/// it's a struct. This lightweight reference box lets `OrphanTriageCardView`
/// hold a live reference to the handlers bundle created at click-time.
///
/// The box is re-created by `InboxZoneView` whenever the triage store opens a
/// new orphan — so the handlers always capture the current environment objects.
@MainActor
final class RowClickHandlersBox: ObservableObject {
    let value: RowClickHandlers

    init(_ handlers: RowClickHandlers) {
        self.value = handlers
    }
}
