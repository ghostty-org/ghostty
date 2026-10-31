import Foundation

enum AgentHistoryRemoteError: Error, Equatable {
    case invalidHome
    case invalidPath
    case unavailable
}

struct AgentHistoryRemoteFile: Equatable, Sendable {
    let path: String
    let size: Int
    let modifiedAt: Date
}

struct AgentHistoryRemoteChunk: Equatable, Sendable {
    let file: AgentHistoryRemoteFile
    let headerData: Data
}

/// Reads an Agent's session store on a remote host through portable SSH
/// commands with stdout captured. This mirrors the existing in-tree SSH helpers
/// (BatchMode, bounded timeouts) and never owns keys, passwords, or known_hosts.
struct AgentHistoryRemoteAccess: Sendable {
    let alias: String
    let runCommand: @Sendable (String) async throws -> String

    init(alias: String) {
        self.alias = alias
        self.runCommand = { command in
            try await AgentHistoryRemoteAccess.executeSSH(
                alias: alias,
                command: command
            )
        }
    }

    init(
        alias: String,
        runCommand: @escaping @Sendable (String) async throws -> String
    ) {
        self.alias = alias
        self.runCommand = runCommand
    }

    func remoteHome() async throws -> String {
        let output = try await runCommand("printf '%s' \"$HOME\"")
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"),
              home.utf8.count <= 4_096,
              !home.contains("\0"),
              !home.contains("\n") else {
            throw AgentHistoryRemoteError.invalidHome
        }
        return home
    }

    /// Discovers agent session files and reads their headers in a single remote
    /// batch command over SSH. Existing directories are checked first so that
    /// missing agent directories on the remote host never cause `find` to fail
    /// or exit with a non-zero status.
    func discoverSessions(
        relativeRoots: [String],
        maximumSessions: Int,
        updatedAfter: Date? = nil
    ) async throws -> [AgentHistoryRemoteChunk] {
        let safeRoots = relativeRoots.filter { !$0.isEmpty && !$0.contains("'") }
        guard !safeRoots.isEmpty else { return [] }
        let boundedLimit = min(max(maximumSessions, 1), AgentHistoryStore.maximumSessions)
        let rootsJSON = String(data: try JSONEncoder().encode(safeRoots), encoding: .utf8)!
        let script = """
        python3 - \(Self.shellQuote(rootsJSON)) \(boundedLimit) \(updatedAfter.map { String($0.timeIntervalSince1970) } ?? "-inf") <<'OMG_HISTORY_PY'
        import json, os, sqlite3, sys
        minimum_modified = float(sys.argv[3])

        def read_zstd_prefix(path, limit=256 * 1024):
            try:
                import zstandard
                with open(path, 'rb') as source:
                    with zstandard.ZstdDecompressor().stream_reader(source) as reader:
                        return reader.read(limit)
            except Exception:
                import selectors, subprocess, time
                process = subprocess.Popen(
                    ['zstd', '--decompress', '--stdout', '--quiet', path],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0)
                try:
                    data = bytearray()
                    deadline = time.monotonic() + 5
                    with selectors.DefaultSelector() as ready:
                        ready.register(process.stdout, selectors.EVENT_READ)
                        while len(data) < limit:
                            remaining = deadline - time.monotonic()
                            if remaining <= 0 or not ready.select(remaining):
                                break
                            chunk = os.read(process.stdout.fileno(), min(65536, limit - len(data)))
                            if not chunk:
                                break
                            data.extend(chunk)
                    return bytes(data)
                finally:
                    process.stdout.close()
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

        candidates = []
        inspected = 0
        for relative in json.loads(sys.argv[1]):
            root = os.path.join(os.path.expanduser('~'), relative)
            if relative == '.gemini/antigravity-cli/conversations':
                index = os.path.join(os.path.dirname(root), 'conversation_summaries.db')
                try:
                    connection = sqlite3.connect('file:' + index + '?mode=ro', uri=True)
                    rows = connection.execute("SELECT conversation_id, title, preview, workspace_uris, strftime('%s', last_modified_time) FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT ?", (int(sys.argv[2]),))
                    from urllib.parse import urlparse, unquote
                    for ident, title, preview, uris, modified in rows:
                        path = os.path.join(root, ident + '.db')
                        if not os.path.isfile(path) or modified is None:
                            continue
                        if (float(modified) if float(modified) > 0 else os.path.getmtime(path)) < minimum_modified:
                            continue
                        workspaces = json.loads(uris) if uris else []
                        cwd = next((unquote(urlparse(uri).path) for uri in workspaces if uri.startswith('file://')), '')
                        records = [dict(type='session', id=ident, title=title or preview, cwd=cwd)]
                        if preview:
                            records.append(dict(type='user', content=preview))
                        print(json.dumps(dict(path=path, size=os.path.getsize(path), modified=float(modified) if float(modified) > 0 else os.path.getmtime(path), records=records)))
                    connection.close()
                except (sqlite3.Error, OSError, ValueError):
                    pass
                continue
            for directory, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if not d.startswith('.')]
                for name in files:
                    inspected += 1
                    if inspected > 200000:
                        break
                    path = os.path.join(directory, name)
                    if not (name.endswith('.jsonl') or name.endswith('.jsonl.zst')) or os.path.islink(path):
                        continue
                    try:
                        stat = os.stat(path)
                        if stat.st_mtime < minimum_modified:
                            continue
                        candidates.append((stat.st_mtime, path, stat.st_size))
                    except OSError:
                        pass
                if inspected > 200000:
                    break
        candidates.sort(reverse=True)
        for modified, path, size in candidates[:min(int(sys.argv[2]) * 2, 20000)]:
            try:
                if path.endswith('.jsonl.zst'):
                    # Bound output before buffering; reap the helper even when
                    # the prefix is complete before the archive finishes.
                    data = read_zstd_prefix(path)
                else:
                    with open(path, 'rb') as source:
                        data = source.read(2 * 1024 * 1024)
                        if len(data) < size:
                            data = data.rsplit(b'\\n', 1)[0]
                            source.seek(max(0, size - 128 * 1024))
                            tail = source.read().split(b'\\n')[1:]
                            # Pi's explicit session name can appear at the end.
                            for line in tail:
                                try:
                                    record = json.loads(line)
                                    if record.get('type') in ('session_info', 'title', 'title_change'):
                                        data += b'\\n' + line
                                except (ValueError, AttributeError):
                                    pass
                # Preserve JSON records but omit large system/tool payloads from transport.
                records = []
                for line in data.splitlines():
                    try:
                        record = json.loads(line)
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if not isinstance(record, dict):
                        continue
                    kind = record.get('type')
                    payload = record.get('message') or record.get('payload') or record
                    role = payload.get('role') if isinstance(payload, dict) else None
                    if kind in ('session', 'session_meta', 'title', 'title_change', 'session_info') or role == 'user' or kind == 'user':
                        records.append(record)
                print(json.dumps(dict(path=path, size=size, modified=modified, records=records)))
            except OSError:
                pass
        OMG_HISTORY_PY
        """
        let output = try await runCommand(script)
        return Self.parseBatchStream(output)
    }

    func read(path: String, maximumBytes: Int) async throws -> Data {
        guard Self.validRemotePath(path), maximumBytes > 0 else {
            throw AgentHistoryRemoteError.invalidPath
        }
        let command = "head -c \(maximumBytes) \(Self.shellQuote(path)) 2>/dev/null | sed '$d'"
        let output = try await runCommand(command)
        return Data(output.utf8)
    }

    struct PromptTail: Sendable {
        let revision: String
        let offset: UInt64
        let data: Data?
    }

    /// A bounded snapshot of one already-resolved JSONL file. Base64 preserves
    /// UTF-8 split across the byte boundary; the parser discards that first line.
    func promptTail(path: String, previousRevision: String?, maximumBytes: Int) async throws -> PromptTail {
        guard Self.validRemotePath(path), maximumBytes > 0, maximumBytes <= 8 * 1_024 * 1_024 else {
            throw AgentHistoryRemoteError.invalidPath
        }
        let command = """
        file=\(Self.shellQuote(path))
        [ -f "$file" ] && [ ! -L "$file" ] || exit 1
        revision=$(stat -c '%i:%s:%y:%z' "$file" 2>/dev/null) || revision=$(stat -f '%i:%z:%m:%c' "$file") || exit 1
        if [ "$revision" = \(Self.shellQuote(previousRevision ?? "")) ]; then
          printf 'UNCHANGED\\n'
          exit 0
        fi
        size=$(wc -c < "$file" | tr -d ' ')
        start=0
        [ "$size" -le \(maximumBytes) ] || start=$((size - \(maximumBytes)))
        printf '%s\\n%s\\n' "$revision" "$start"
        tail -c +$((start + 1)) "$file" | head -c $((size - start)) | base64
        """
        let output = try await runCommand(command)
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "UNCHANGED", let previousRevision {
            return .init(revision: previousRevision, offset: 0, data: nil)
        }
        let parts = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let offset = UInt64(parts[1]),
              let data = Data(base64Encoded: parts.count == 3 ? String(parts[2]) : "",
                              options: .ignoreUnknownCharacters), data.count <= maximumBytes else {
            throw AgentHistoryRemoteError.unavailable
        }
        return .init(revision: String(parts[0]), offset: offset, data: data)
    }

    static func parseBatchStream(_ output: String) -> [AgentHistoryRemoteChunk] {
        var results: [AgentHistoryRemoteChunk] = []
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["path"] as? String, validRemotePath(path),
                  let size = object["size"] as? Int,
                  let modified = object["modified"] as? Double, modified.isFinite,
                  let records = object["records"] as? [[String: Any]] else { continue }
            var header = Data()
            for record in records {
                guard let encoded = try? JSONSerialization.data(withJSONObject: record) else { continue }
                header.append(encoded)
                header.append(0x0A)
            }
            results.append(.init(file: .init(path: path, size: size,
                modifiedAt: Date(timeIntervalSince1970: modified)), headerData: header))
        }
        if !results.isEmpty { return results }
        let parts = output.components(separatedBy: "===OMG_FILE===")
        for part in parts where !part.isEmpty {
            guard let endRange = part.range(of: "\n===OMG_END===") ?? part.range(of: "===OMG_END===") else {
                continue
            }
            let body = String(part[..<endRange.lowerBound])
            guard let newlineIndex = body.firstIndex(of: "\n") else { continue }
            let lsLine = String(body[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
            let headerText = String(body[body.index(after: newlineIndex)...])
            guard let file = parseLongListingLine(lsLine) else { continue }
            results.append(.init(file: file, headerData: Data(headerText.utf8)))
        }
        return results
    }

    /// Parses a single `ls -ld` long listing produced by `ls -ld`.
    static func parseLongListingLine(_ line: String) -> AgentHistoryRemoteFile? {
        guard line.count > 10, line.first != "t" else { return nil }
        let columns = line.split(
            maxSplits: 8,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard columns.count == 9 else { return nil }
        guard let size = Int(columns[4]) else { return nil }
        let name = String(columns[8])
        guard validRemotePath(name) else { return nil }
        let month = String(columns[5])
        let day = String(columns[6])
        let time = String(columns[7])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        var date: Date?
        if time.contains(":") {
            formatter.defaultDate = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date())))
            formatter.dateFormat = "MMM dd HH:mm"
            let parsed = formatter.date(from: "\(month) \(day) \(time)")
            if let parsed, parsed > Date().addingTimeInterval(60) {
                date = Calendar.current.date(byAdding: .year, value: -1, to: parsed)
            } else {
                date = parsed
            }
        } else {
            formatter.dateFormat = "MMM dd yyyy"
            date = formatter.date(from: "\(month) \(day) \(time)")
        }

        return .init(
            path: name,
            size: size,
            modifiedAt: date ?? .distantPast
        )
    }

    static func parseLongListings(_ output: String) -> [AgentHistoryRemoteFile] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { parseLongListingLine(String($0)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func validRemotePath(_ path: String) -> Bool {
        path.hasPrefix("/") &&
            !path.isEmpty &&
            path.utf8.count <= 4_096 &&
            !path.contains("\0") &&
            !path.contains("\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func executeSSH(
        alias: String,
        command: String
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let remoteCommand = "exec /bin/sh -c \(shellQuote(command))"
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            alias,
            remoteCommand,
        ]
        process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("omg-agent-history-\(UUID().uuidString).out")
                guard FileManager.default.createFile(
                    atPath: outputURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ), let output = try? FileHandle(forWritingTo: outputURL) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                defer {
                    try? output.close()
                    try? FileManager.default.removeItem(at: outputURL)
                }
                process.standardOutput = output
                do {
                    try process.run()
                } catch {
                    throw AgentHistoryRemoteError.unavailable
                }
                // Compressed archives make discovery slower; keep a bounded
                // but generous ceiling so large stores still complete.
                let timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(60))
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                timeout.cancel()
                try? output.close()
                guard process.terminationStatus == 0,
                      let data = try? Data(contentsOf: outputURL) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                // Remote readers drop their potentially incomplete final line
                // before transport, so the bounded JSONL stream stays valid UTF-8.
                guard let text = String(bytes: data, encoding: .utf8) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                return text
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
