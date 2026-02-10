import CryptoKit
import Foundation

struct DiffReviewDraftStore {
    var baseDir: URL

    init(baseDir: URL = AgentStatusPaths.baseSupportDir.appendingPathComponent("diff-review", isDirectory: true)) {
        self.baseDir = baseDir
    }

    func draftURL(for context: DiffReviewContext) -> URL {
        let key = contextKeyString(context)
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDir.appendingPathComponent("\(hex).json", isDirectory: false)
    }

    func load(context: DiffReviewContext) throws -> DiffReviewDraft {
        let url = draftURL(for: context)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DiffReviewDraft.self, from: data)
    }

    func save(_ draft: DiffReviewDraft, context: DiffReviewContext) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let url = draftURL(for: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft)
        try data.write(to: url, options: [.atomic])
    }

    func exportJSONString(_ draft: DiffReviewDraft, context: DiffReviewContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = ExportPayload(context: context, draft: draft)
        guard let data = try? encoder.encode(payload) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct ExportPayload: Codable {
        var context: DiffReviewContext
        var draft: DiffReviewDraft
    }

    private func contextKeyString(_ context: DiffReviewContext) -> String {
        let scope = context.scope?.rawValue ?? ""
        let pr = context.pullRequestNumber.map(String.init) ?? ""
        return "\(context.repoRoot)|\(context.source.rawValue)|\(scope)|\(pr)"
    }
}

