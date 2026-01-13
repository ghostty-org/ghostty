import Foundation
import Combine

/// Represents a project that can be launched in Terminaut
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var icon: String?
    var lastOpened: Date?
    var hasActivity: Bool = false

    init(id: UUID = UUID(), name: String, path: String, icon: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
        self.lastOpened = nil
    }
}

/// Manages the list of projects and persists them to disk
class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published var projects: [Project] = []
    @Published var selectedIndex: Int = 0

    private let projectsURL: URL

    private init() {
        // Store projects in ~/.terminaut/projects.json
        let home = FileManager.default.homeDirectoryForCurrentUser
        let terminautDir = home.appendingPathComponent(".terminaut")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: terminautDir, withIntermediateDirectories: true)

        projectsURL = terminautDir.appendingPathComponent("projects.json")
        loadProjects()
    }

    func loadProjects() {
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            // Create default projects for common locations
            scanForProjects()
            return
        }

        do {
            let data = try Data(contentsOf: projectsURL)
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            print("Failed to load projects: \(error)")
            scanForProjects()
        }
    }

    func saveProjects() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(projects)
            try data.write(to: projectsURL)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }

    /// Scan common directories for projects
    func scanForProjects() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectDirs = [
            home.appendingPathComponent("Projects"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Code"),
        ]

        var foundProjects: [Project] = []

        for dir in projectDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    // Check if it's a git repo or has common project files
                    let gitDir = url.appendingPathComponent(".git")
                    let packageJson = url.appendingPathComponent("package.json")
                    let cargoToml = url.appendingPathComponent("Cargo.toml")
                    let gemfile = url.appendingPathComponent("Gemfile")
                    let buildZig = url.appendingPathComponent("build.zig")
                    let claudeMd = url.appendingPathComponent("CLAUDE.md")

                    let isProject = [gitDir, packageJson, cargoToml, gemfile, buildZig, claudeMd].contains {
                        FileManager.default.fileExists(atPath: $0.path)
                    }

                    if isProject {
                        foundProjects.append(Project(
                            name: url.lastPathComponent,
                            path: url.path
                        ))
                    }
                }
            }
        }

        // Sort by name
        foundProjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        projects = foundProjects
        saveProjects()
    }

    func addProject(name: String, path: String) {
        let project = Project(name: name, path: path)
        projects.append(project)
        saveProjects()
    }

    func removeProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        projects.remove(at: index)
        if selectedIndex >= projects.count {
            selectedIndex = max(0, projects.count - 1)
        }
        saveProjects()
    }

    func markOpened(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastOpened = Date()
            saveProjects()
        }
    }

    // Navigation
    func moveSelection(by delta: Int) {
        guard !projects.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + projects.count) % projects.count
    }

    /// Grid-aware vertical navigation that stays in the same column
    func moveVertical(by rowDelta: Int, columnCount: Int) {
        guard !projects.isEmpty else { return }

        let currentRow = selectedIndex / columnCount
        let currentCol = selectedIndex % columnCount
        let totalRows = (projects.count + columnCount - 1) / columnCount

        var targetRow = currentRow + rowDelta

        if targetRow < 0 {
            // Wrap to bottom - find last row that has this column
            targetRow = totalRows - 1
            var targetIndex = targetRow * columnCount + currentCol
            while targetIndex >= projects.count && targetRow > 0 {
                targetRow -= 1
                targetIndex = targetRow * columnCount + currentCol
            }
            selectedIndex = min(targetIndex, projects.count - 1)
        } else if targetRow >= totalRows {
            // Wrap to top
            selectedIndex = currentCol
        } else {
            // Normal move
            let targetIndex = targetRow * columnCount + currentCol
            if targetIndex < projects.count {
                selectedIndex = targetIndex
            } else {
                // Target doesn't exist (partial row), wrap to top of column
                selectedIndex = currentCol
            }
        }
    }

    /// Horizontal navigation with row wrapping
    func moveHorizontal(by colDelta: Int, columnCount: Int) {
        guard !projects.isEmpty else { return }

        let newIndex = selectedIndex + colDelta

        if newIndex < 0 {
            // Wrap to end of previous row or last item
            selectedIndex = max(0, selectedIndex - 1)
        } else if newIndex >= projects.count {
            // At the end, wrap to start
            selectedIndex = 0
        } else {
            selectedIndex = newIndex
        }
    }

    var selectedProject: Project? {
        guard selectedIndex >= 0, selectedIndex < projects.count else { return nil }
        return projects[selectedIndex]
    }
}
