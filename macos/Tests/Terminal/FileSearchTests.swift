import Foundation
@testable import Ghostty
import Testing

/// The file-name search behind the field at the top of the tree.
struct FileSearchTests {
    /// Builds a small tree on disk and returns its root.
    private func makeTree() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phantom-search-\(UUID().uuidString)")
        let fm = FileManager.default

        for directory in ["src", "src/deep", "node_modules", "node_modules/pkg", ".git"] {
            try? fm.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        for file in [
            "README.md",
            "src/index.ts",
            "src/deep/index.ts",
            "node_modules/pkg/index.ts",
            ".git/index.ts",
        ] {
            try? "x".write(
                to: root.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private func search(_ query: String, in root: URL, showHidden: Bool = false) -> [String] {
        FileExplorerModel
            .search(query: query, under: root, showHidden: showHidden)
            .map(\.node.path)
    }

    @Test func itFindsByPartOfTheName() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = search("readme", in: root)
        #expect(found.count == 1)
        #expect(found.first?.hasSuffix("README.md") == true)
    }

    @Test func itIsCaseInsensitive() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!search("README", in: root).isEmpty)
        #expect(!search("readme", in: root).isEmpty)
    }

    /// It looks below the root, not only in it — a search that only saw the
    /// top folder would be a worse version of reading the tree.
    @Test func itDescendsIntoSubdirectories() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = search("index", in: root)
        #expect(found.contains { $0.hasSuffix("src/index.ts") })
        #expect(found.contains { $0.hasSuffix("src/deep/index.ts") })
    }

    /// Build directories are skipped: searching them buries the answer under
    /// thousands of matches nobody meant.
    @Test func itSkipsBuildAndVcsDirectories() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = search("index", in: root)
        #expect(!found.contains { $0.contains("node_modules") })
        #expect(!found.contains { $0.contains("/.git/") })
    }

    /// Matches are a flat list, so no row is indented against a parent the
    /// list isn't showing.
    @Test func matchesAreFlat() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = FileExplorerModel.search(query: "index", under: root, showHidden: false)
        #expect(rows.allSatisfy { $0.depth == 0 })
    }

    @Test func nothingMatchingIsAnEmptyListRatherThanEverything() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(search("zzzznotathing", in: root).isEmpty)
    }

    /// Breadth-first, so with a result cap the shallow files — the ones you
    /// probably meant — are the ones that survive.
    @Test func shallowMatchesComeFirst() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = search("index", in: root)
        guard let shallow = found.firstIndex(where: { $0.hasSuffix("src/index.ts") }),
              let deep = found.firstIndex(where: { $0.hasSuffix("src/deep/index.ts") })
        else {
            Issue.record("both files should be found")
            return
        }
        #expect(shallow < deep)
    }
}
