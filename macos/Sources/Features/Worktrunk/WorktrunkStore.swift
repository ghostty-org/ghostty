import Foundation

final class WorktrunkStore: ObservableObject {
    struct Repository: Identifiable, Codable, Hashable {
        var id: UUID
        var path: String
        var displayName: String?

        init(id: UUID = UUID(), path: String, displayName: String? = nil) {
            self.id = id
            self.path = path
            self.displayName = displayName
        }

        var name: String {
            if let displayName, !displayName.isEmpty { return displayName }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    struct Worktree: Identifiable, Hashable {
        var repositoryID: UUID
        var branch: String
        var path: String
        var isMain: Bool
        var isCurrent: Bool

        var id: String { "\(repositoryID.uuidString)::\(branch)::\(path)" }
    }

    private struct WtListItem: Decodable {
        var branch: String?
        var path: String?
        var kind: String
        var isMain: Bool
        var isCurrent: Bool

        enum CodingKeys: String, CodingKey {
            case branch
            case path
            case kind
            case isMain = "is_main"
            case isCurrent = "is_current"
        }
    }

    @Published private(set) var repositories: [Repository] = []
    @Published private var worktreesByRepositoryID: [UUID: [Worktree]] = [:]
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String? = nil

    private let repositoriesKey = "GhosttyWorktrunkRepositories.v1"

    init() {
        load()
    }

    func worktrees(for repositoryID: UUID) -> [Worktree] {
        worktreesByRepositoryID[repositoryID] ?? []
    }

    func addRepositoryValidated(path: String, displayName: String? = nil) async {
        let normalized = normalizePath(path)

        let alreadyExists = repositories.contains(where: { normalizePath($0.path) == normalized })
        guard !alreadyExists else {
            await MainActor.run { errorMessage = nil }
            return
        }

        do {
            _ = try await WorktrunkClient.run(["-C", normalized, "list", "--format=json"])
            await MainActor.run {
                addRepository(path: normalized, displayName: displayName)
                errorMessage = nil
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await MainActor.run { errorMessage = message }
        }
    }

    func addRepository(path: String, displayName: String? = nil) {
        let normalized = normalizePath(path)
        guard !repositories.contains(where: { normalizePath($0.path) == normalized }) else { return }
        repositories.append(.init(path: normalized, displayName: displayName))
        save()
        Task { await refreshAll() }
    }

    func removeRepository(id: UUID) {
        repositories.removeAll(where: { $0.id == id })
        worktreesByRepositoryID[id] = nil
        save()
    }

    func refreshAll() async {
        await MainActor.run {
            isRefreshing = true
        }

        for repo in repositories {
            await refresh(repoID: repo.id)
        }

        await MainActor.run {
            isRefreshing = false
        }
    }

    func refresh(repoID: UUID) async {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        do {
            let result = try await WorktrunkClient.run(["-C", repo.path, "list", "--format=json"])
            let data = Data(result.stdout.utf8)
            let items = try JSONDecoder().decode([WtListItem].self, from: data)

            let worktrees: [Worktree] = items.compactMap { item in
                guard item.kind == "worktree" else { return nil }
                guard let branch = item.branch, !branch.isEmpty else { return nil }
                guard let path = item.path, !path.isEmpty else { return nil }
                return Worktree(
                    repositoryID: repoID,
                    branch: branch,
                    path: path,
                    isMain: item.isMain,
                    isCurrent: item.isCurrent
                )
            }
            await MainActor.run {
                worktreesByRepositoryID[repoID] = worktrees.sorted { a, b in
                    if a.isCurrent != b.isCurrent { return a.isCurrent }
                    if a.isMain != b.isMain { return a.isMain }
                    return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
                }
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }

    func createWorktree(
        repoID: UUID,
        branch: String,
        base: String?,
        createBranch: Bool
    ) async -> Worktree? {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return nil }

        do {
            var args = ["-C", repo.path, "switch", "--yes"]
            if createBranch {
                args.append("--create")
            }
            if let base, !base.isEmpty {
                args.append(contentsOf: ["--base", base])
            }
            args.append(branch)

            _ = try await WorktrunkClient.run(args)

            await refresh(repoID: repoID)
            return worktrees(for: repoID).first(where: { $0.branch == branch })
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            return nil
        }
    }

    private func load() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: repositoriesKey) else { return }
        do {
            repositories = try JSONDecoder().decode([Repository].self, from: data)
        } catch {
            repositories = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(repositories)
            UserDefaults.standard.set(data, forKey: repositoriesKey)
        } catch {
            // Ignore persistence failure.
        }
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
