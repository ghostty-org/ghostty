import Foundation
import SwiftUI
import Combine

@MainActor
final class SidePanelViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProjectIndex: Int = 0
    @Published var isVisible: Bool = true

    private let path: URL

    var currentProject: Project? {
        guard currentProjectIndex >= 0 && currentProjectIndex < projects.count else { return nil }
        return projects[currentProjectIndex]
    }

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.path = configDir.appendingPathComponent("tasks.json")
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: path.path) else {
            projects = [Project(name: "Default")]
            return
        }
        do {
            let data = try Data(contentsOf: path)
            projects = try JSONDecoder().decode([Project].self, from: data)
            if projects.isEmpty {
                projects = [Project(name: "Default")]
            }
        } catch {
            projects = [Project(name: "Default")]
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: path)
        } catch {
            print("Failed to save: \(error)")
        }
    }

    func addProject(name: String) {
        let project = Project(name: name)
        projects.append(project)
        currentProjectIndex = projects.count - 1
        save()
    }

    func deleteProject(at index: Int) {
        guard projects.count > 1 else { return }
        projects.remove(at: index)
        if currentProjectIndex >= projects.count {
            currentProjectIndex = projects.count - 1
        }
        save()
    }

    func selectProject(at index: Int) {
        guard index >= 0 && index < projects.count else { return }
        currentProjectIndex = index
    }

    func addCard(title: String, description: String = "", priority: Priority = .p2, status: CardStatus = .todo) {
        guard currentProjectIndex < projects.count else { return }
        let card = Card(title: title, description: description, status: status, priority: priority)
        projects[currentProjectIndex].cards.append(card)
        save()
    }

    func updateCard(_ card: Card) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == card.id }) {
            projects[currentProjectIndex].cards[idx] = card
            save()
        }
    }

    func deleteCard(id: String) {
        guard currentProjectIndex < projects.count else { return }
        projects[currentProjectIndex].cards.removeAll { $0.id == id }
        save()
    }

    func moveCard(id: String, to status: CardStatus) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == id }) {
            projects[currentProjectIndex].cards[idx].status = status
            save()
        }
    }

    func addSession(to cardId: String, session: Session) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[idx].sessions.append(session)
            save()
        }
    }

    func deleteSession(cardId: String, sessionId: String) {
        guard currentProjectIndex < projects.count else { return }
        if let cardIdx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[cardIdx].sessions.removeAll { $0.id == sessionId }
            save()
        }
    }

    func toggleCardExpanded(_ cardId: String) {
        guard currentProjectIndex < projects.count else { return }
        if let idx = projects[currentProjectIndex].cards.firstIndex(where: { $0.id == cardId }) {
            projects[currentProjectIndex].cards[idx].isExpanded.toggle()
        }
    }
}
