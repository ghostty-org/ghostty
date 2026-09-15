import Foundation

extension LocalWorkspaceFilesystem {
    func listTreeDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        let entries = try await listDirectory(at: path)
        return try await Task.detached(priority: .utility) {
            try entries.map { entry in
                try Task.checkCancellation()
                guard entry.isDirectory else { return entry }
                let chain = InspectorTreeLayout.chain(from: entry) { current in
                    let url = URL(fileURLWithPath: current.path)
                    guard let iterator = FileManager.default.enumerator(at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsSubdirectoryDescendants]) else { return nil }
                    var only: URL?
                    for case let child as URL in iterator where child.lastPathComponent != ".DS_Store" {
                        guard only == nil else { return nil }
                        only = child
                    }
                    guard let child = only,
                          let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                    return WorkspaceFileEntry(path: child.path, name: child.lastPathComponent, isDirectory: true)
                }
                return WorkspaceFileEntry(path: chain[chain.count - 1].path,
                    name: chain.map(\.name).joined(separator: "/"), isDirectory: true)
            }
        }.value
    }
}

extension SSHWorkspaceFilesystem {
    func listTreeDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        let command = "python3 -c " + Self.shellQuote(Self.compactTreeScript) + " " + Self.shellQuote(path)
        do {
            let output = try await SSHSFTPClient.runCommand(command, host: host.alias, connection: connection)
            guard let marker = output.range(of: "OMG-TREE-v1\n", options: .backwards) else {
                throw WorkspaceFilesystemError.invalidResponse
            }
            let entries = try JSONDecoder().decode([WorkspaceFileEntry].self, from: Data(output[marker.upperBound...].utf8))
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            try Task.checkCancellation()
            // Hosts without Python keep the existing SFTP browser available.
            return try await listDirectory(at: path)
        }
    }

    static let compactTreeScript = """
    import json, os, sys
    root = sys.argv[1]
    def only_directory(path):
        try:
            with os.scandir(path) as children:
                single = None
                for child in children:
                    if child.name == '.DS_Store':
                        continue
                    if single is not None:
                        return None
                    single = child
                if single is not None and single.is_dir(follow_symlinks=False):
                    return single
        except OSError:
            pass
        return None
    with os.scandir(root) as listing:
        entries = sorted((e for e in listing if e.name != '.DS_Store'),
                         key=lambda e: (not e.is_dir(follow_symlinks=False), e.name))[:500]
    result = []
    for entry in entries:
        directory = entry.is_dir(follow_symlinks=False)
        path, parts = entry.path, [entry.name]
        if directory:
            for _ in range(23):
                child = only_directory(path)
                if child is None:
                    break
                path = child.path
                parts.append(child.name)
        result.append(dict(path=path, name='/'.join(parts), isDirectory=directory))
    print('OMG-TREE-v1')
    print(json.dumps(result))
    """
}
