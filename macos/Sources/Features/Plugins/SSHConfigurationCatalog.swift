import Darwin
import Foundation

struct SSHRegistrationChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let endpoint: String
    let connection: GitSSHConnection
    let fromConfiguration: Bool
    var title: String { name + " · " + endpoint }
}

/// Enumerates concrete config aliases, then asks OpenSSH for effective endpoint
/// values. Parsing configuration does not connect to any remote machine.
enum SSHConfigurationCatalog {
    static func aliases(at file: URL, relativeRoot: URL? = nil) -> [String] {
        var visited: Set<String> = []
        var result: Set<String> = []
        let root = relativeRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        func read(_ file: URL, depth: Int) {
            guard depth < 16, visited.count < 128, visited.insert(file.standardizedFileURL.path).inserted,
                  let data = try? Data(contentsOf: file), data.count <= 2_097_152,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let words = tokens(String(line))
                guard let key = words.first?.lowercased() else { continue }
                let values = words.dropFirst().filter { $0 != "=" }
                if key == "host" {
                    result.formUnion(values.filter { SSHPlugin.validAlias($0) && !$0.hasPrefix("-") })
                } else if key == "include" {
                    for value in values {
                        let expanded = (value as NSString).expandingTildeInPath
                        let pattern = expanded.hasPrefix("/") ? expanded : root.appendingPathComponent(expanded).path
                        var matches = glob_t()
                        if glob(pattern, 0, nil, &matches) == 0, let paths = matches.gl_pathv {
                            for index in 0..<Int(matches.gl_pathc) {
                                if let path = paths[index] { read(URL(fileURLWithPath: String(cString: path)), depth: depth + 1) }
                            }
                        }
                        globfree(&matches)
                    }
                }
            }
        }
        read(file, depth: 0)
        return result.sorted()
    }

    private static func tokens(_ line: String) -> [String] {
        var values: [String] = [], word = ""
        var quote: Character?, escaped = false
        for character in line {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character
            } else if character == "#" { break
            } else if character.isWhitespace || character == "=" {
                if !word.isEmpty { values.append(word); word = "" }
            } else { word.append(character) }
        }
        if !word.isEmpty { values.append(word) }
        return values
    }

    static func endpoint(from output: String) -> String? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let host = values["hostname"], let user = values["user"] else { return nil }
        let address = host.contains(":") ? "[\(host)]" : host
        return user + "@" + address + (values["port"].flatMap { $0 == "22" ? nil : ":" + $0 } ?? "")
    }

    static func resolve(_ connection: GitSSHConnection) async throws -> String {
        let result = try await GitProcessRunner().run(executablePath: connection.executablePath,
            arguments: ["-G", "-o", "CanonicalizeHostname=no"] + connection.options + ["--", connection.destination],
            workingDirectory: connection.localWorkingDirectory, timeout: 10)
        guard result.isSuccess, let endpoint = endpoint(from: result.stdoutString) else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return endpoint
    }

    static func choices(live: [GitSSHConnection], file: URL? = nil) async -> [SSHRegistrationChoice] {
        let config = file ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        var connections = live
        let systemAliases = file == nil ? aliases(at: URL(fileURLWithPath: "/etc/ssh/ssh_config"),
                                                 relativeRoot: URL(fileURLWithPath: "/etc/ssh")) : []
        for name in Set(aliases(at: config)).union(systemAliases).sorted() {
            if let connection = try? GitSSHConnection(destination: name,
                options: file == nil ? [] : ["-F", config.path], workspaceID: "ssh:" + name,
                localWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path) {
                connections.append(connection)
            }
        }
        var choices: [SSHRegistrationChoice] = []
        // Keep concurrency bounded while resolving config aliases locally.
        for start in stride(from: 0, to: connections.count, by: 6) {
            let batch = Array(connections[start..<min(start + 6, connections.count)])
            let resolved = await withTaskGroup(of: SSHRegistrationChoice?.self) { group in
                for connection in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let endpoint = (try? await resolve(connection)) ?? connection.displayEndpoint
                        let name = connection.workspaceID.hasPrefix("ssh:") ? String(connection.workspaceID.dropFirst(4)) : connection.destination
                        return .init(id: RegisteredSSHHost.id(for: connection), name: name, endpoint: endpoint, connection: connection,
                                     fromConfiguration: !live.contains(connection))
                    }
                }
                var values: [SSHRegistrationChoice] = []
                for await choice in group { if let choice { values.append(choice) } }
                return values
            }
            choices.append(contentsOf: resolved)
        }
        let liveIDs = Set(live.map { RegisteredSSHHost.id(for: $0) })
        choices.sort {
            if liveIDs.contains($0.id) != liveIDs.contains($1.id) { return liveIDs.contains($0.id) }
            return $0.id < $1.id
        }
        var seen: Set<String> = []
        return choices.filter {
            let key = $0.title + "\0" + $0.connection.executablePath + "\0" + $0.connection.options.joined(separator: "\0")
            return seen.insert(key).inserted
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
