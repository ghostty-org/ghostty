import Foundation

enum GitCollectionMode: String, CaseIterable {
    case list, tree
    var symbol: String { self == .list ? "list.bullet" : "list.bullet.indent" }
    var title: String { self == .list ? GitL10n.text("List") : GitL10n.text("Tree") }
}

enum GitChangeSection: String, Equatable, Sendable {
    case staged, unstaged
    var target: GitDiffTarget { self == .staged ? .staged : .unstaged }
    var title: String { self == .staged ? GitL10n.text("Staged") : GitL10n.text("Unstaged / Untracked") }
    func rowID(path: String) -> String { "changes/\(rawValue)/file/\(path)" }
}

enum GitCollectionSource: Equatable {
    case decorations([GitRefDecoration])
    case changes(staged: [GitDiffFile], unstaged: [GitDiffFile], stagedError: String?, unstagedError: String?)
    case refs(branches: [GitBranchInfo], worktrees: [GitWorktreeInfo], scopes: Bool, branchesError: String?, worktreesError: String?)

    static func changes(_ tree: GitWorkingTreeContent) -> Self {
        .changes(staged: tree.staged, unstaged: tree.unstaged, stagedError: tree.stagedError, unstagedError: tree.unstagedError)
    }
}

struct GitCollectionItem: Equatable {
    enum Kind: Equatable {
        case category(Int)
        case folder(Int)
        case file(GitDiffFile, GitChangeSection)
        case branch(GitBranchInfo, worktrees: [String])
        case worktree(GitWorktreeInfo)
        case scope(GitHistoryScope)
        case ref(GitRefDecoration)
        case notice(error: Bool)
    }
    let id: String
    var title: String
    var subtitle: String?
    let kind: Kind
    var enabled = true
    var pending = false
    var stageBatch: GitStageBatch?
    var fullPath: String?

    var isFolder: Bool { if case .folder = kind { return true }; return false }
    var isCategory: Bool { if case .category = kind { return true }; return false }
    var isSelectable: Bool { !isCategory && { if case .notice = kind { return false }; return true }() }
    var tooltip: String {
        if let fullPath { return fullPath }
        switch kind {
        case .ref(let ref): return ref.name
        case .file(let file, _): return (file.isUntracked ? GitL10n.text("Untracked") : file.kind.label) + " · " + file.displayPath
        case .branch(let branch, let paths):
            return ([branch.name, branch.upstream + " " + branch.tracking] + paths.map { GitL10n.text("Worktree: ") + $0 })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .worktree(let worktree):
            return [worktree.branchName, worktree.path, worktree.isDirty == true ? GitL10n.text("Dirty") : nil,
                    worktree.lockedReason, worktree.prunableReason, worktree.statusError].compactMap { $0 }.joined(separator: "\n")
        default: return [title, subtitle].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

final class GitCollectionNode {
    var item: GitCollectionItem
    var children: [GitCollectionNode]
    init(_ item: GitCollectionItem, children: [GitCollectionNode] = []) {
        self.item = item; self.children = children
    }
}

struct GitCollectionRow: Equatable {
    var item: GitCollectionItem
    let depth: Int
    var expanded = false
    var isTree = false
    var representedIDs: [String] = []
    var id: String { item.id }
    var height: CGFloat {
        switch item.kind {
        case .category: 30
        case .file: item.subtitle == nil ? (isTree ? 24 : 26) : 38
        case .folder: 24
        case .worktree: 40
        default: 26
        }
    }
}

/// Presentation state is independent of Git status and survives tab/mode changes.
final class GitCollectionState {
    var collapsed: [String: Set<String>] = [:]
    var selected: [String: String] = [:]
    var selections: [String: Set<String>] = [:]
    var scrollAnchors: [String: (id: String, offset: CGFloat)] = [:]
}

enum GitCollectionBuilder {
    /// History files are read-only: no index batching or staging metadata is needed.
    static func historyFiles(_ files: [GitDiffFile]) -> [GitCollectionNode] {
        grouped(files.map { file in
            (file.path, GitCollectionItem(id: "history/file/" + file.path,
                title: (file.path as NSString).lastPathComponent, kind: .file(file, .unstaged)))
        }, category: "history", mode: .tree)
    }
    static func nodes(source: GitCollectionSource, mode: GitCollectionMode, query: String = "",
                      pending: Set<String> = [], canWrite: Bool = true, extraRefs: [GitRefDecoration] = [],
                      favoriteBranchIDs: Set<String>? = nil, includesHead: Bool = false) -> [GitCollectionNode] {
        switch source {
        case .decorations(let refs): return referenceNodes(refs, mode: mode, query: query)
        case .changes(let staged, let unstaged, let stagedError, let unstagedError):
            let entries = GitStageBatch.entries(staged: staged, unstaged: unstaged)
            let folders = GitStageBatch.folders(entries)
            let writable = canWrite && stagedError == nil && unstagedError == nil
            let sections = [(GitChangeSection.staged, staged, stagedError), (.unstaged, unstaged, unstagedError)].map { section, files, error in
                let key = "changes/" + section.rawValue
                let entries = files.filter { matches(query, text: $0.displayPath) }.map { file in
                    let folder = (file.path as NSString).deletingLastPathComponent
                    return (file.path, GitCollectionItem(id: section.rowID(path: file.path),
                        title: (file.path as NSString).lastPathComponent,
                        subtitle: mode == .list ? folder : nil,
                        kind: .file(file, section), enabled: canWrite && error == nil && !pending.contains(file.path),
                        pending: pending.contains(file.path), stageBatch: .init(entries: [.init(file: file, section: section)])))
                }
                let children = grouped(entries, category: key, mode: mode)
                func configureFolders(_ nodes: [GitCollectionNode]) {
                    for node in nodes {
                        if node.item.isFolder {
                            let path = String(node.item.id.dropFirst((key + "/folder/").count))
                            if let batch = folders[path] {
                                node.item.stageBatch = batch
                                node.item.pending = !batch.paths.isDisjoint(with: pending)
                                node.item.enabled = writable && !node.item.pending
                            }
                        }
                        configureFolders(node.children)
                    }
                }
                configureFolders(children)
                let node = category(key, title: section.title, count: files.count, children: children, error: error,
                                    empty: query.isEmpty ? GitL10n.text("No changes") : GitL10n.text("No matching files"))
                if !files.isEmpty {
                    let batch = GitStageBatch(entries: files.map { .init(file: $0, section: section) })
                    node.item.stageBatch = batch
                    node.item.pending = !batch.paths.isDisjoint(with: pending)
                    node.item.enabled = writable && !node.item.pending
                }
                return node
            }
            return sections
        case .refs(let branches, let worktrees, let scopes, let branchesError, let worktreesError):
            let occupied = Dictionary(grouping: worktrees.compactMap { tree in tree.branchRef.map { ($0, tree.path) } }, by: { $0.0 })
            let head = GitCollectionNode(.init(id: "HEAD", title: "HEAD",
                kind: .ref(.init(name: "HEAD", kind: .head)), enabled: branchesError == nil))
            if let favoriteBranchIDs {
                let favorites = branches.filter { favoriteBranchIDs.contains($0.id) }
                let entries = favorites.filter { matches(query, text: $0.name) }.map { branch in
                    (branch.name, GitCollectionItem(id: branch.id, title: branch.name,
                        kind: .branch(branch, worktrees: occupied[branch.id, default: []].map(\.1)), enabled: branchesError == nil))
                }
                let hasHead = includesHead && favoriteBranchIDs.contains("HEAD")
                var children = grouped(entries, category: "refs/favorites", mode: mode)
                if hasHead && matches(query, text: "HEAD") { children.insert(head, at: 0) }
                return [category("refs/favorites", title: GitL10n.text("Favorite Branches"), count: favorites.count + (hasHead ? 1 : 0),
                    children: children, error: branchesError,
                    empty: query.isEmpty ? GitL10n.text("No favorite branches. Star a branch to add it here.") : GitL10n.text("No matching branches"))]
            }
            var roots = scopes && query.isEmpty ? GitHistoryScope.allCases.map { scope in
                GitCollectionNode(.init(id: "scope:" + scope.rawValue, title: scope.displayName, kind: .scope(scope)))
            } : []
            if includesHead && matches(query, text: "HEAD") { roots.append(head) }
            for remote in [false, true] {
                let key = remote ? "refs/remote" : "refs/local"
                let all = branches.filter { $0.isRemote == remote }
                let entries = all.filter { matches(query, text: $0.name) }.map { branch in
                    (branch.name, GitCollectionItem(id: branch.id, title: branch.name,
                        kind: .branch(branch, worktrees: occupied[branch.id, default: []].map(\.1)), enabled: branchesError == nil))
                }
                roots.append(category(key, title: remote ? GitL10n.text("Remote Branches") : GitL10n.text("Branches"), count: all.count,
                    children: grouped(entries, category: key, mode: mode), error: branchesError,
                    empty: query.isEmpty ? GitL10n.text("No branches") : GitL10n.text("No matching branches")))
            }
            let trees = worktrees.filter { matches(query, text: $0.branchName + " " + $0.path + " " + ($0.head?.rawValue ?? "")) }
                .map { worktree in
                    GitCollectionNode(.init(id: "worktree:" + worktree.path,
                        title: worktree.branchRef == nil ? worktree.head?.shortSHA ?? GitL10n.text("No commits") : worktree.branchName,
                        subtitle: worktree.path, kind: .worktree(worktree), enabled: worktreesError == nil && !worktree.isBare))
                }
            roots.append(category("worktrees", title: GitL10n.text("Worktrees"), count: worktrees.count, children: trees,
                                  error: worktreesError, empty: query.isEmpty ? GitL10n.text("No worktrees") : GitL10n.text("No matching worktrees")))
            if !extraRefs.isEmpty { roots += referenceNodes(extraRefs, mode: mode, query: query) }
            return roots
        }
    }

    static func referenceID(_ ref: GitRefDecoration) -> String { "ref:" + ref.kind.rawValue + ":" + ref.name }
    private static func referenceNodes(_ refs: [GitRefDecoration], mode: GitCollectionMode, query: String) -> [GitCollectionNode] {
        let groups: [(String, String, Set<GitRefDecorationKind>)] = [
            ("head", "HEAD", [.head]), ("branches", GitL10n.text("Branches"), [.currentBranch, .localBranch]),
            ("remote", GitL10n.text("Remote Branches"), [.remoteBranch]), ("tags", GitL10n.text("Tags"), [.tag]),
        ]
        return groups.compactMap { key, title, kinds in
            let all = refs.filter { kinds.contains($0.kind) }
            guard !all.isEmpty else { return nil }
            let entries = all.filter { matches(query, text: $0.name) }.map { ref in
                (ref.name, GitCollectionItem(id: referenceID(ref), title: ref.name, kind: .ref(ref)))
            }
            return category("decorations/" + key, title: title, count: all.count,
                            children: grouped(entries, category: "decorations/" + key, mode: mode), error: nil, empty: GitL10n.text("No matching references"))
        }
    }

    static func rows(_ nodes: [GitCollectionNode], collapsed: Set<String> = []) -> [GitCollectionRow] {
        var result: [GitCollectionRow] = []
        func hasFolders(_ nodes: [GitCollectionNode]) -> Bool {
            nodes.contains { $0.item.isFolder || hasFolders($0.children) }
        }
        let isTree = hasFolders(nodes)
        func append(_ nodes: [GitCollectionNode], depth: Int) {
            for node in nodes {
                let chain = InspectorTreeLayout.chain(from: node) { current in
                    guard current.item.isFolder, current.children.count == 1,
                          let child = current.children.first, child.item.isFolder else { return nil }
                    return child
                }
                let tail = chain[chain.count - 1]
                var item = tail.item
                if chain.count > 1 { item.title = chain.map { $0.item.title }.joined(separator: "/") }
                let expanded = !chain.contains { collapsed.contains($0.item.id) }
                result.append(.init(item: item, depth: depth, expanded: expanded, isTree: isTree, representedIDs: chain.map { $0.item.id }))
                if expanded || item.isCategory { append(tail.children, depth: item.isCategory ? depth : depth + 1) }
            }
        }
        append(nodes, depth: 0)
        return result
    }

    private static func matches(_ query: String, text: String) -> Bool {
        let parts = query.split(whereSeparator: \.isWhitespace)
        return parts.allSatisfy { text.matchedIndices(for: String($0)) != nil }
    }

    private static func category(_ key: String, title: String, count: Int, children: [GitCollectionNode],
                                 error: String?, empty: String) -> GitCollectionNode {
        var values = children
        if let error { values.insert(GitCollectionNode(.init(id: key + "/error", title: error, kind: .notice(error: true))), at: 0) }
        if values.isEmpty { values = [GitCollectionNode(.init(id: key + "/empty", title: empty, kind: .notice(error: false)))] }
        return GitCollectionNode(.init(id: key, title: title, kind: .category(count)), children: values)
    }

    private static func grouped(_ entries: [(String, GitCollectionItem)], category: String, mode: GitCollectionMode) -> [GitCollectionNode] {
        let sorted = entries.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard mode == .tree else { return sorted.map { GitCollectionNode($0.1) } }
        let root = GitCollectionNode(.init(id: category, title: "", kind: .category(entries.count)))
        var folders: [String: GitCollectionNode] = [:]
        for (path, value) in sorted {
            let parts = path.split(separator: "/").map(String.init)
            var parent = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix += "/" + part
                let key = category + "/folder" + prefix
                let folder: GitCollectionNode
                if let existing = folders[key] {
                    folder = existing
                    if case .folder(let count) = folder.item.kind {
                        folder.item = .init(id: key, title: part, kind: .folder(count + 1), fullPath: String(prefix.dropFirst()))
                    }
                } else {
                    folder = GitCollectionNode(.init(id: key, title: part, kind: .folder(1), fullPath: String(prefix.dropFirst())))
                    folders[key] = folder
                    parent.children.append(folder)
                }
                parent = folder
            }
            var item = value
            item.title = parts.last ?? value.title
            parent.children.append(GitCollectionNode(item))
        }
        func order(_ node: GitCollectionNode) {
            node.children.sort {
                if $0.item.isFolder != $1.item.isFolder { return $0.item.isFolder }
                return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
            node.children.forEach(order)
        }
        order(root)
        return root.children
    }
}
