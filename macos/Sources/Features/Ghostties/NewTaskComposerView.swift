import AppKit
import SwiftUI

/// Inline composer card for creating a new task (U8 / SEA-164).
///
/// Placed inside the sidebar — either replacing the empty-Inbox canvas (D5 /
/// when Inbox is empty) or at the top of the Inbox lane pushing rows down.
///
/// Three triggers open this view:
///   a. `[+ Start]` button in the sidebar header (D22, wired by `TaskSidebarView`).
///   b. Click on empty-Inbox area (wired by `InboxZoneView`).
///   c. `⌘⇧N` global shortcut (wired in `AppDelegate`).
///
/// **D20 colour budget:** title focus ring uses `rgba(255,255,255,0.40)`.
/// Start button is solid white-chrome. The only terracotta surface is the
/// `[+ Add project…]` chip when `WorkspaceStore.projects` is empty (D7).
///
/// **D18/D19 animation:** 180ms `easeOut` reveal; reduced-motion falls back to
/// 200ms opacity crossfade with no translate/clip.
///
/// D26: lives flat under `macos/Sources/Features/Ghostties/`, no subdirectory.
@MainActor
struct NewTaskComposerView: View {

    @ObservedObject var store: NewTaskComposerStore
    @ObservedObject var taskStore: TaskStore
    @EnvironmentObject private var workspaceStore: WorkspaceStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Allows the view to programmatically focus the title field via
    /// `FocusState`. Toggled by `store.focusTitleFieldTrigger`.
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerCard
        }
        // D18/D19: animated reveal.
        .transition(revealTransition)
        .animation(revealAnimation, value: store.isOpen)
        // Consume the focus trigger from the store.
        .onChange(of: store.focusTitleFieldTrigger) { triggered in
            if triggered {
                titleFocused = true
                store.focusTitleFieldTrigger = false
            }
        }
    }

    // MARK: - Card

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title field
            titleField

            // Row: Project picker micro-label + picker chip
            projectRow

            // Row: Template picker micro-label + picker chip
            templateRow

            // Action row: Start button + cancel hint
            actionRow

            // Inline error (D13)
            if let err = store.writeError {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .background(cardBackground)
        .overlay(alignment: .bottom) {
            // Bottom hairline separator so the card reads as a surface.
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
    }

    // MARK: - Title field

    private var titleField: some View {
        TextField("What are you starting?", text: $store.titleText)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.primary)
            .textFieldStyle(.plain)
            .focused($titleFocused)
            // D20: focus ring uses rgba(255,255,255,0.40) — rendered as an
            // overlay border on the container below the field.
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                titleFocused
                                    ? Color.white.opacity(0.40)
                                    : Color.clear,
                                lineWidth: 1.5
                            )
                    )
            )
            // Confirm on Return key.
            .onSubmit {
                triggerConfirm()
            }
            // FYI-2: VoiceOver label for the title field.
            .accessibilityLabel("Task title")
            .accessibilityHint("Enter a description of the task you are starting")
    }

    // MARK: - Project row (D6, D7)

    private var projectRow: some View {
        HStack(spacing: 6) {
            // Micro-label "in" (D23)
            Text("in")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .textCase(.uppercase)
                .frame(width: 20, alignment: .leading)

            if workspaceStore.projects.isEmpty {
                // D7: onboarding — terracotta add-project chip.
                Button {
                    store.addProjectViaPanel(workspaceStore: workspaceStore)
                } label: {
                    Text("+ Add project…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WorkspaceLayout.waitingTerracotta)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(WorkspaceLayout.waitingTerracotta.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            } else {
                // Project picker menu.
                Menu {
                    ForEach(workspaceStore.projects) { project in
                        Button {
                            store.selectedProjectId = project.id
                        } label: {
                            Text(project.name)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedProjectName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.85))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var selectedProjectName: String {
        guard let id = store.selectedProjectId,
              let project = workspaceStore.projects.first(where: { $0.id == id }) else {
            return "pick project"
        }
        return project.name
    }

    // MARK: - Template row

    private var templateRow: some View {
        HStack(spacing: 6) {
            // Micro-label "via" (D23)
            Text("via")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .textCase(.uppercase)
                .frame(width: 20, alignment: .leading)

            Menu {
                Button {
                    store.selectedTemplateName = nil
                } label: {
                    Text("None")
                }
                Divider()
                ForEach(availableTemplates, id: \.id) { template in
                    Button {
                        store.selectedTemplateName = template.name
                    } label: {
                        Text(template.name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.selectedTemplateName ?? "none")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            store.selectedTemplateName == nil
                                ? Color(nsColor: .tertiaryLabelColor)
                                : Color.primary.opacity(0.85)
                        )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var availableTemplates: [AgentTemplate] {
        workspaceStore.templates(for: store.selectedProjectId)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            // D20: solid white-chrome start button — NOT terracotta.
            Button {
                triggerConfirm()
            } label: {
                HStack(spacing: 4) {
                    Text("Start")
                        .font(.system(size: 12, weight: .semibold))
                    Text("↵")
                        .font(.system(size: 11, weight: .regular))
                }
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        // D20: rgba(255,255,255,0.92) background.
                        .fill(Color.white.opacity(0.92))
                )
            }
            .buttonStyle(.plain)
            .disabled(!store.canConfirm || !workspaceStore.projects.isEmpty ? !store.canConfirm : true)
            // FYI-2: VoiceOver label for the Start/confirm button.
            .accessibilityLabel("Start task")
            .accessibilityHint("Creates and starts the new task. Keyboard shortcut: Return")

            // Cancel hint: small esc keychip + "cancel" at 32% white opacity (D23).
            HStack(spacing: 4) {
                Text("esc")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                Text("cancel")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .onTapGesture {
                store.cancel()
            }
        }
    }

    // MARK: - Confirm dispatch

    private func triggerConfirm() {
        guard store.canConfirm else { return }
        _Concurrency.Task { @MainActor in
            await store.confirm(taskStore: taskStore, workspaceStore: workspaceStore)
        }
    }

    // MARK: - Background

    private var cardBackground: Color {
        Color(nsColor: colorScheme == .dark
              ? WorkspaceLayout.chromeBackgroundDark
              : WorkspaceLayout.chromeBackgroundLight)
        .opacity(0.0)   // transparent — inherits from sidebar chrome
    }

    // MARK: - Animation (D18, D19) — tokens from WorkspaceLayout.Animation

    private var revealAnimation: Animation {
        reduceMotion ? .sidebarReducedMotion : .sidebarPush
    }

    private var revealTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity.animation(.sidebarReducedMotion)
            : AnyTransition.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal:   .opacity.combined(with: .move(edge: .top))
            ).animation(.sidebarPush)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("New Task Composer — Dark") {
    let ws = WorkspaceStore(testingProjects: [
        Project(name: "ghostties", rootPath: "/Users/sean/Code/ghostties", isPinned: true)
    ])
    let composerStore = NewTaskComposerStore(isolatedForTesting: ())
    composerStore.open(workspaceStore: ws)

    NewTaskComposerView(
        store: composerStore,
        taskStore: TaskStore()
    )
    .environmentObject(ws)
    .preferredColorScheme(.dark)
    .frame(width: 280)
    .padding(16)
    .background(Color(white: 0.14))
}
#endif
