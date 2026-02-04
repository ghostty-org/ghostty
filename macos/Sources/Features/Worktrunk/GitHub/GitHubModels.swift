import Foundation

// MARK: - CI Status

enum CIState: String, Codable, Equatable {
    case passed
    case failed
    case pending
    case skipped
    case cancelled
    case none  // no checks configured

    var isTerminal: Bool {
        switch self {
        case .passed, .failed, .skipped, .cancelled, .none:
            return true
        case .pending:
            return false
        }
    }
}

// MARK: - PR Check

struct PRCheck: Codable, Identifiable, Equatable {
    let name: String
    let state: String       // SUCCESS, FAILURE, PENDING, etc.
    let conclusion: String? // pass, fail, skip, etc.
    let detailsUrl: String?
    let workflowName: String?

    var id: String { name }

    var bucket: CIState {
        let s = state.uppercased()
        let c = conclusion?.uppercased()

        if s == "SUCCESS" || c == "SUCCESS" { return .passed }
        if s == "FAILURE" || s == "ERROR" || c == "FAILURE" { return .failed }
        if s == "PENDING" || s == "IN_PROGRESS" || s == "QUEUED" || s == "WAITING" { return .pending }
        if s == "SKIPPED" || c == "SKIPPED" || c == "NEUTRAL" { return .skipped }
        if s == "CANCELLED" || c == "CANCELLED" { return .cancelled }
        return .pending
    }
}

// MARK: - PR Status

struct PRStatus: Identifiable, Equatable {
    let number: Int
    let title: String
    let headRefName: String  // branch name
    let state: String        // OPEN, CLOSED, MERGED
    let url: String
    let checks: [PRCheck]
    let updatedAt: Date
    let fetchedAt: Date

    var id: Int { number }

    var isOpen: Bool { state.uppercased() == "OPEN" }
    var isMerged: Bool { state.uppercased() == "MERGED" }
    var isClosed: Bool { state.uppercased() == "CLOSED" }

    var overallCIState: CIState {
        if checks.isEmpty { return .none }

        // Any failed = failed
        if checks.contains(where: { $0.bucket == .failed }) { return .failed }
        // Any pending = pending
        if checks.contains(where: { $0.bucket == .pending }) { return .pending }
        // All passed/skipped = passed
        if checks.allSatisfy({ $0.bucket == .passed || $0.bucket == .skipped || $0.bucket == .cancelled }) {
            return .passed
        }
        return .pending
    }

    var checkCounts: (passed: Int, failed: Int, pending: Int, skipped: Int) {
        var passed = 0, failed = 0, pending = 0, skipped = 0
        for check in checks {
            switch check.bucket {
            case .passed: passed += 1
            case .failed: failed += 1
            case .pending: pending += 1
            case .skipped, .cancelled: skipped += 1
            case .none: break
            }
        }
        return (passed, failed, pending, skipped)
    }
}

// MARK: - GitHub Repo Info

struct GitHubRepoInfo: Codable, Hashable {
    let owner: String
    let name: String
    let remoteName: String  // "origin", "upstream", etc.

    var fullName: String { "\(owner)/\(name)" }
}

// MARK: - Cache Entry

struct PRStatusCacheEntry: Equatable {
    let status: PRStatus
    let isTerminal: Bool

    var age: TimeInterval {
        Date().timeIntervalSince(status.fetchedAt)
    }

    var isStale: Bool {
        // Terminal states never go stale (until invalidated by push)
        if isTerminal { return false }
        // Pending states are stale after 5 minutes
        return age > 300
    }
}
