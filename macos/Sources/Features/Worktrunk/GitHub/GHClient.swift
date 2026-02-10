import Foundation

enum GHClientError: LocalizedError {
    case executableNotFound
    case nonZeroExit(code: Int32, stderr: String)
    case invalidUTF8
    case invalidJSON(String)
    case notAuthenticated
    case notGitHubRepo

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "GitHub CLI (gh) not found. Install with: brew install gh"
        case .nonZeroExit(let code, let stderr):
            if stderr.contains("gh auth login") {
                return "GitHub CLI not authenticated. Run: gh auth login"
            }
            if stderr.isEmpty { return "gh failed (exit \(code))." }
            let firstLine = stderr.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? stderr
            return "gh failed (exit \(code)): \(firstLine)"
        case .invalidUTF8:
            return "gh returned invalid UTF-8 output."
        case .invalidJSON(let detail):
            return "gh returned invalid JSON: \(detail)"
        case .notAuthenticated:
            return "GitHub CLI not authenticated. Run: gh auth login"
        case .notGitHubRepo:
            return "Not a GitHub repository."
        }
    }
}

struct GHClient {
    struct CommandResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private struct Invocation {
        var executableURL: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private actor PRListCache {
        struct Key: Hashable {
            var repoPath: String
            var headBranch: String?
            var includeChecks: Bool
        }

        struct Entry {
            var fetchedAt: Date
            var prs: [PRStatus]
        }

        private var cache: [Key: Entry] = [:]
        private var inFlight: [Key: Task<[PRStatus], Error>] = [:]
        private let ttl: TimeInterval = 5

        func getOrFetch(key: Key, fetch: @escaping () async throws -> [PRStatus]) async throws -> [PRStatus] {
            let now = Date()
            if let entry = cache[key], now.timeIntervalSince(entry.fetchedAt) < ttl {
                return entry.prs
            }
            if let task = inFlight[key] {
                return try await task.value
            }

            let task = Task { try await fetch() }
            inFlight[key] = task
            do {
                let prs = try await task.value
                cache[key] = Entry(fetchedAt: now, prs: prs)
                inFlight[key] = nil
                return prs
            } catch {
                inFlight[key] = nil
                throw error
            }
        }
    }

    private static let prListCache = PRListCache()

    // MARK: - Public API

    /// Check if gh CLI is available and authenticated
    static func isAvailable() async -> Bool {
        do {
            _ = try await run(["auth", "status"])
            return true
        } catch {
            return false
        }
    }

    /// List open PRs for a repository, optionally filtering by branch
    static func listPRs(repoPath: String, headBranch: String? = nil, includeChecks: Bool = true) async throws -> [PRStatus] {
        var args = [
            "pr", "list",
            "--json", includeChecks
                ? "number,title,headRefName,state,url,updatedAt,statusCheckRollup"
                : "number,title,headRefName,state,url,updatedAt",
            "--limit", "50"
        ]

        if let branch = headBranch {
            args.append(contentsOf: ["--head", branch])
        }

        let key = PRListCache.Key(repoPath: repoPath, headBranch: headBranch, includeChecks: includeChecks)
        return try await prListCache.getOrFetch(key: key) {
            let result = try await run(args, cwd: URL(fileURLWithPath: repoPath))
            return try parsePRListResponse(result.stdout)
        }
    }

    /// Fetch PR status for a specific branch (returns nil if no PR exists)
    static func prForBranch(repoPath: String, branch: String) async throws -> PRStatus? {
        let prs = try await listPRs(repoPath: repoPath, headBranch: branch, includeChecks: true)
        // Prefer open PRs, fall back to most recent
        return prs.first(where: { $0.isOpen }) ?? prs.first
    }

    /// Fetch PR info for a branch without loading CI checks (faster, used by diff UI).
    static func prForBranchLite(repoPath: String, branch: String) async throws -> PRStatus? {
        let prs = try await listPRs(repoPath: repoPath, headBranch: branch, includeChecks: false)
        return prs.first(where: { $0.isOpen }) ?? prs.first
    }

    /// Fetch the patch diff for a PR number.
    static func prDiff(repoPath: String, number: Int) async throws -> String {
        let result = try await run([
            "pr", "diff",
            String(number),
            "--patch",
        ], cwd: URL(fileURLWithPath: repoPath))
        return result.stdout
    }

    /// Get GitHub repo info from a local git repo
    static func getRepoInfo(repoPath: String) async throws -> GitHubRepoInfo? {
        let result = try await run(["repo", "view", "--json", "owner,name"], cwd: URL(fileURLWithPath: repoPath))

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = (json["owner"] as? [String: Any])?["login"] as? String,
              let name = json["name"] as? String else {
            return nil
        }

        return GitHubRepoInfo(owner: owner, name: name, remoteName: "origin")
    }

    // MARK: - Low-level

    static func run(_ args: [String], cwd: URL? = nil) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(args, cwd: cwd)
        }.value
    }

    private static func runSync(_ args: [String], cwd: URL?) throws -> CommandResult {
        let invocation = try makeInvocation(args)

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = cwd

        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        guard let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw GHClientError.invalidUTF8
        }

        let result = CommandResult(
            stdout: stdout,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )

        if result.exitCode != 0 {
            if result.stderr.contains("gh auth login") || result.stderr.contains("not logged in") {
                throw GHClientError.notAuthenticated
            }
            throw GHClientError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }

        return result
    }

    private static func makeInvocation(_ args: [String]) throws -> Invocation {
        var env = ProcessInfo.processInfo.environment

        // GUI apps often have minimal PATH
        let prefix = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = env["PATH"] ?? ""
        if existingPath.isEmpty {
            env["PATH"] = prefix.joined(separator: ":")
        } else {
            let existingComponents = Set(existingPath.split(separator: ":").map(String.init))
            let missingPaths = prefix.filter { !existingComponents.contains($0) }
            if !missingPaths.isEmpty {
                env["PATH"] = (missingPaths + [existingPath]).joined(separator: ":")
            }
        }

        // Find gh executable
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return Invocation(executableURL: URL(fileURLWithPath: path), arguments: args, environment: env)
            }
        }

        // Fall back to PATH resolution
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        guard FileManager.default.isExecutableFile(atPath: envURL.path) else {
            throw GHClientError.executableNotFound
        }

        return Invocation(executableURL: envURL, arguments: ["gh"] + args, environment: env)
    }

    // MARK: - JSON Parsing

    private static func parsePRListResponse(_ json: String) throws -> [PRStatus] {
        guard let data = json.data(using: .utf8) else {
            throw GHClientError.invalidJSON("Invalid UTF-8")
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GHClientError.invalidJSON("Expected array")
        }

        let now = Date()
        return array.compactMap { item -> PRStatus? in
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let headRefName = item["headRefName"] as? String,
                  let state = item["state"] as? String,
                  let url = item["url"] as? String else {
                return nil
            }

            let updatedAt = parseDate(item["updatedAt"] as? String) ?? now
            let checks = parseStatusCheckRollup(item["statusCheckRollup"])

            return PRStatus(
                number: number,
                title: title,
                headRefName: headRefName,
                state: state,
                url: url,
                checks: checks,
                updatedAt: updatedAt,
                fetchedAt: now
            )
        }
    }

    private static func parseStatusCheckRollup(_ rollup: Any?) -> [PRCheck] {
        guard let contexts = rollup as? [[String: Any]] else {
            return []
        }

        return contexts.compactMap { ctx -> PRCheck? in
            // Handle both CheckRun and StatusContext types
            let name = ctx["name"] as? String ?? ctx["context"] as? String ?? "Unknown"
            let state = ctx["state"] as? String ?? ctx["status"] as? String ?? "PENDING"
            let conclusion = ctx["conclusion"] as? String
            let detailsUrl = ctx["detailsUrl"] as? String ?? ctx["targetUrl"] as? String
            let workflowName = ctx["workflowName"] as? String

            return PRCheck(
                name: name,
                state: state,
                conclusion: conclusion,
                detailsUrl: detailsUrl,
                workflowName: workflowName
            )
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
