import AppKit
import Combine

/// One management session survives the popover's native close boundary. Actions
/// bind an explicit workspace/tab identity; hover never changes their target.
@MainActor
final class TerminalWorkspacePickerModel: ObservableObject {
    enum Page: Equatable { case switcher, create, edit(UUID), move, delete(UUID) }
    @Published var page: Page = .switcher
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var name = ""
    @Published var symbol = "briefcase"
    @Published var color = "blue"
    @Published private(set) var isPerforming = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private weak var controller: TerminalController?
    private let dismiss: (@escaping () -> Void) -> Void
    private let reopen: () -> Void
    let store: TerminalWorkspaceStore
    let coordinator: TerminalWorkspaceCoordinator

    init(controller: TerminalController, dismiss: @escaping (@escaping () -> Void) -> Void,
         reopen: @escaping () -> Void) {
        self.controller = controller
        self.store = controller.workspaceCoordinator.store
        self.coordinator = controller.workspaceCoordinator
        self.dismiss = dismiss
        self.reopen = reopen
        selectedID = coordinator.previousWorkspaceID(in: controller) ?? controller.workspaceID
    }

    var currentID: UUID? { controller?.workspaceID }
    var movingTabTitle: String { controller?.titleOverride ?? controller?.window?.title ?? WorkspaceL10n.text("Current tab", "当前标签") }
    var filtered: [TerminalWorkspace] {
        store.workspaces.filter {
            (page != .move || $0.id != currentID) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    var validName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 40
    }
    var canCreate: Bool { store.workspaces.count < 100 }
    var duplicateName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let editingID: UUID? = if case .edit(let id) = page { id } else { nil }
        return store.workspaces.contains { $0.id != editingID && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }
    }

    func reset() {
        page = .switcher
        query = ""
        error = nil
        notice = nil
        if let controller { selectedID = coordinator.previousWorkspaceID(in: controller) ?? controller.workspaceID }
    }

    func back() { page = .switcher; error = nil; query = "" }
    func cancel() {
        guard !isPerforming else { return }
        if page == .switcher { controller?.workspaceSwitcherIsPresented = false } else { back() }
    }
    func beginCreate() {
        page = .create
        name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        symbol = "briefcase"
        color = "blue"
        error = nil
        notice = nil
    }
    func beginEdit(_ id: UUID) {
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
        page = .edit(id)
        name = workspace.name
        symbol = workspace.symbol
        color = workspace.color
        error = nil
        notice = nil
    }
    func beginMove() { page = .move; query = ""; selectedID = filtered.first?.id; error = nil; notice = nil }
    func canDelete(_ id: UUID) -> Bool { store.workspaces.count > 1 && id != currentID }
    var deletionDestination: TerminalWorkspace? { currentID.flatMap { id in store.workspaces.first { $0.id == id } } }

    func beginDelete(_ id: UUID) {
        guard canDelete(id) else { return }
        page = .delete(id)
        error = nil
        notice = nil
    }

    func tabCount(_ id: UUID, allWindows: Bool = false) -> Int {
        (store.snapshot.windows ?? [:]).filter { allWindows || $0.key == controller?.windowSessionID }
            .values.reduce(0) { $0 + ($1.groups[id]?.tabs.count ?? 0) }
    }

    func step(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selectedID } ?? 0
        selectedID = filtered[(index + delta + filtered.count) % filtered.count].id
    }

    func activateSelected() {
        guard let id = selectedID, filtered.contains(where: { $0.id == id }) else { return }
        activate(id)
    }

    func activate(_ id: UUID) {
        guard let controller else { return }
        if page == .move {
            perform { self.coordinator.move(controller, to: id) }
        } else {
            guard !isPerforming else { return }
            isPerforming = true
            error = nil
            dismiss { [self] in
                coordinator.requestWorkspaceSwitch(to: id, from: controller) { [weak self] outcome in
                    guard let self else { return }
                    self.isPerforming = false
                    switch outcome {
                    case .committed, .superseded: self.reset()
                    case .failed:
                        self.error = self.coordinator.operationError ?? WorkspaceL10n.text(
                            "The workspace could not be opened.", "未能打开工作区。")
                        self.reopen()
                    }
                }
            }
        }
    }

    func save() {
        guard validName, !isPerforming, let controller else { return }
        switch page {
        case .create:
            guard canCreate else {
                error = WorkspaceL10n.text("You can have up to 100 workspaces.", "最多可创建 100 个工作区。")
                return
            }
            let name = name, symbol = symbol, color = color
            perform { self.coordinator.createWorkspace(name: name, symbol: symbol, color: color, from: controller) != nil }
        case .edit(let id):
            store.update(id: id, name: name, symbol: symbol, color: color)
            selectedID = id
            notice = WorkspaceL10n.text("Workspace updated", "工作区已更新")
            back()
        default: break
        }
    }

    func confirmDelete() {
        guard case .delete(let id) = page, let controller, canDelete(id) else { return }
        perform { self.coordinator.deleteWorkspace(id, from: controller) }
    }

    private func perform(_ action: @escaping () -> Bool) {
        guard !isPerforming else { return }
        isPerforming = true
        error = nil
        dismiss { [self] in
            let success = action()
            isPerforming = false
            if success {
                reset()
            } else {
                error = coordinator.operationError ?? WorkspaceL10n.text(
                    "The operation could not be completed. Your workspaces are unchanged; please try again.",
                    "操作未完成，工作区保持原状，请重试。")
                reopen()
            }
        }
    }
}
