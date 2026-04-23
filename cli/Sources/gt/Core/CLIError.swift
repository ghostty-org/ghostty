import Foundation

/// Single error type for the CLI. Maps to the exit codes defined in the spec:
///   0 success  · 1 usage  · 2 not found  · 3 ambiguous
enum CLIError: LocalizedError {
    case usage(String)
    case notFound(String)
    case ambiguousID(prefix: String, matches: [String])
    case io(String)

    var errorDescription: String? {
        switch self {
        case .usage(let m):
            return "error: \(m)"
        case .notFound(let m):
            return "error: \(m)"
        case .ambiguousID(let prefix, let matches):
            let list = matches.sorted().joined(separator: ", ")
            return "error: \"\(prefix)\" matches \(matches.count) tasks: [\(list)]. use full id"
        case .io(let m):
            return "error: \(m)"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .notFound: return 2
        case .ambiguousID: return 3
        case .io: return 1
        }
    }
}
