import Testing
@testable import Ghostty

struct GitDiffPresentationTests {
    @Test func commitBodyOmitsTemporaryPastedImages() {
        let metadata = GitCommitMetadata(
            commitID: GitCommitID("0123456789abcdef"),
            authorName: "Test",
            authorEmail: "test@example.com",
            authoredAt: "2026-11-06",
            parents: [],
            message: """
            Add validation

            Image attachment: true

            /var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-paste/omg-paste-72C0E55E-5A19-4963-8B86-FBE0A4276DE4.png
            Keep this explanation.
            """
        )
        #expect(!metadata.body.contains("omg-paste"))
        #expect(!metadata.body.contains("Image attachment"))
        #expect(metadata.body.contains("Keep this explanation."))
    }

    @Test func reviewNavigationRequiresConfirmationBeforeCrossingFiles() {
        var navigator = GitDiffReviewNavigator()
        #expect(navigator.move(.next, changeCount: 2, fileCount: 3) == .jump(0))
        #expect(navigator.move(.next, changeCount: 2, fileCount: 3) == .jump(1))
        #expect(navigator.move(.next, changeCount: 2, fileCount: 3) == .hint(.nextFile))
        #expect(navigator.move(.next, changeCount: 2, fileCount: 3)
            == .openFile(offset: 1, landing: .first))
        #expect(navigator.land(.first, changeCount: 3) == 0)
        #expect(navigator.move(.previous, changeCount: 3, fileCount: 3) == .hint(.previousFile))
        #expect(navigator.move(.previous, changeCount: 3, fileCount: 3)
            == .openFile(offset: -1, landing: .last))
        #expect(navigator.land(.last, changeCount: 4) == 3)
    }

    @Test func reviewNavigationWrapsAcrossTheFirstAndLastFile() {
        var first = GitDiffReviewNavigator()
        #expect(first.land(.first, changeCount: 1) == 0)
        #expect(first.move(.previous, changeCount: 1, fileCount: 2) == .hint(.previousFile))
        #expect(first.move(.previous, changeCount: 1, fileCount: 2) == .openFile(offset: -1, landing: .last))

        var last = GitDiffReviewNavigator()
        #expect(last.land(.last, changeCount: 1) == 0)
        #expect(last.move(.next, changeCount: 1, fileCount: 2) == .hint(.nextFile))
        #expect(last.move(.next, changeCount: 1, fileCount: 2) == .openFile(offset: 1, landing: .first))
    }

    @Test func inlineIncludesUnchangedSourceAndBothSidesOfReplacement() {
        let value = GitDiffPresentation(before: "one\nold\nlast\n", after: "one\nnew\nextra\nlast\n",
                                        patch: "@@ -1,3 +1,4 @@\n one\n-old\n+new\n+extra\n last\n")
        #expect(value.isConsistent)
        #expect(value.text == "one\nold\nnew\nextra\nlast")
        #expect(value.highlights == [1: false, 2: true, 3: true])
        #expect(value.beforeHighlights == [1: false])
        #expect(value.afterHighlights == [1: true, 2: true])
        #expect(value.beforeToAfter[2] == 3)
        #expect(value.afterToBefore[3] == 2)
        #expect(value.rows[1].beforeLine == 2 && value.rows[1].afterLine == nil)
        #expect(value.rows[3].afterLine == 3 && value.rows[3].beforeLine == nil)
        #expect(value.changeAnchors.count == 1)
        #expect(value.changeAnchors[0].before == 1)
        #expect(value.changeAnchors[0].after == 1)
        #expect(value.changeAnchors[0].inline == 1)
    }

    @Test func zeroContextInsertionAndDeletionMapFollowingLines() {
        let insertion = GitDiffPresentation(before: "a\nb\nc\n", after: "a\nx\ny\nb\nc\n",
                                             patch: "@@ -1,0 +2,2 @@\n+x\n+y\n")
        #expect(insertion.isConsistent)
        #expect(insertion.beforeToAfter[1] == 3)
        #expect(insertion.afterToBefore[4] == 2)
        #expect(insertion.beforeHighlights.isEmpty)
        #expect(insertion.afterHighlights == [1: true, 2: true])
        let deletion = GitDiffPresentation(before: "a\nb\nc\n", after: "a\nc\n",
                                            patch: "@@ -2 +1,0 @@\n-b\n")
        #expect(deletion.isConsistent)
        #expect(deletion.beforeToAfter[2] == 1)
        #expect(deletion.beforeHighlights == [1: false])
        #expect(deletion.afterHighlights.isEmpty)
        #expect(insertion.changeAnchors.count == 1 && insertion.changeAnchors[0].after == 1)
        #expect(deletion.changeAnchors.count == 1 && deletion.changeAnchors[0].before == 1)
    }

    @Test func emptyFileAndCRLFAndStaleSnapshot() {
        let added = GitDiffPresentation(before: "", after: "let x = 1\r\n", patch: "@@ -0,0 +1 @@\n+let x = 1\n")
        #expect(added.isConsistent && added.highlights == [0: true])
        #expect(added.beforeHighlights.isEmpty && added.afterHighlights == [0: true])
        let removed = GitDiffPresentation(before: "gone\n", after: "", patch: "@@ -1 +0,0 @@\n-gone\n")
        #expect(removed.isConsistent && removed.highlights == [0: false])
        #expect(removed.beforeHighlights == [0: false] && removed.afterHighlights.isEmpty)
        let stale = GitDiffPresentation(before: "old\n", after: "newer\n", patch: "@@ -1 +1 @@\n-old\n+new\n")
        #expect(!stale.isConsistent)
    }

    @Test func actualCRLFPatchPreservesEveryDeletedAndModifiedLine() {
        let removed = GitDiffPresentation(before: "first\r\nsecond\r\n", after: "",
            patch: "@@ -1,2 +0,0 @@\n-first\r\n-second\r\n")
        #expect(removed.isConsistent)
        #expect(removed.beforeHighlights == [0: false, 1: false])
        let modified = GitDiffPresentation(before: "first\r\nold\r\n", after: "first\r\nnew\r\n",
            patch: "@@ -1,2 +1,2 @@\n first\r\n-old\r\n+new\r\n")
        #expect(modified.isConsistent)
        #expect(modified.beforeHighlights == [1: false] && modified.afterHighlights == [1: true])
    }

    @Test func bothSourceHighlightsIgnorePatchHeadersAndNoNewlineMarkers() {
        let patch = """
        diff --git a/file b/file
        --- a/file
        +++ b/file
        @@ -2,2 +2,3 @@
         same
        -old
        +new
        +extra
        @@ -10 +11 @@
        -last
        \\ No newline at end of file
        +changed
        \\ No newline at end of file
        """
        let unchanged = (4...9).map { "line \($0)" }.joined(separator: "\n")
        let value = GitDiffPresentation(before: "first\nsame\nold\n\(unchanged)\nlast",
                                        after: "first\nsame\nnew\nextra\n\(unchanged)\nchanged", patch: patch)
        #expect(value.isConsistent)
        #expect(value.beforeHighlights == [2: false, 9: false])
        #expect(value.afterHighlights == [2: true, 3: true, 10: true])
    }

    @Test func branchTreeSeparatesLocalRemoteAndFolderPrefixes() {
        let id = GitCommitID("abc")
        let branches = [
            GitBranchInfo(name: "feature/one", commit: id, isCurrent: true, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "feature/two", commit: id, isCurrent: false, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "origin/feature/one", commit: id, isCurrent: false, isRemote: true, upstream: "", tracking: ""),
        ]
        let roots = GitCollectionBuilder.nodes(source: .refs(branches: branches, worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .tree)
        #expect(roots[0].children[0].item.title == "feature")
        #expect(roots[0].children[0].children.count == 2)
        #expect(roots[1].children[0].item.title == "origin")
        if case .branch(let remote, _) = roots[1].children[0].children[0].children[0].item.kind {
            #expect(remote.isRemote)
        } else { Issue.record("Expected a remote branch leaf") }
    }
}
