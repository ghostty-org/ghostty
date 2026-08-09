import Foundation
@testable import Ghostty
import Testing

/// `GitStatus.parse` against real `git status --porcelain=v2 --branch`
/// output.
///
/// Every fixture here was taken from an actual repository rather than
/// written from the manual, because the format's details are exactly where
/// a hand-rolled parser goes wrong: the field count differs per line type,
/// the path is the untouched remainder (and contains spaces), and a rename
/// packs two paths into one field separated by a tab.
struct GitStatusTests {
    // MARK: Branch header

    @Test func readsBranchAndUpstreamWithAheadBehind() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.oid ff26e65d96fda3bcf9e01c35ec967d796ae123df
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -9
        """)

        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 3)
        #expect(status.behind == 9)
        #expect(status.hasUpstream)
    }

    /// A branch that has never been pushed emits no `branch.upstream` line
    /// at all — that absence is what turns the button into "Publish
    /// Branch", so it has to survive parsing as nil rather than "".
    @Test func aBranchWithNoUpstreamHasNone() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.oid cfbb7cea9bdb90593f90a9ec1ae4fd591c5bf195
        # branch.head feat/sidebar-git-panel
        """)

        #expect(status.branch == "feat/sidebar-git-panel")
        #expect(status.upstream == nil)
        #expect(!status.hasUpstream)
        #expect(status.ahead == 0 && status.behind == 0)
    }

    @Test func detachedHeadIsRecognized() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.oid abc123
        # branch.head (detached)
        """)

        #expect(status.isDetached)
    }

    @Test func inSyncReportsZeroBothWays() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """)

        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    // MARK: Ordinary changes

    @Test func aStagedAdditionIsStagedOnly() {
        let status = GitStatus.parse(porcelainV2:
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 " +
            "35df2c58442ddcded2e91761c142ade6603eab68 macos/Sources/Helpers/LoginEnvironment.swift"
        )

        #expect(status.staged.count == 1)
        #expect(status.unstaged.isEmpty)
        #expect(status.staged[0].path == "macos/Sources/Helpers/LoginEnvironment.swift")
        #expect(status.staged[0].name == "LoginEnvironment.swift")
        #expect(status.staged[0].directory == "macos/Sources/Helpers")
        #expect(status.staged[0].badge(staged: true) == "A")
    }

    @Test func anUnstagedModificationIsUnstagedOnly() {
        let status = GitStatus.parse(porcelainV2:
            "1 .M N... 100644 100644 100644 a1d104a a1d104a macos/Sources/Helpers/ShellCommand.swift"
        )

        #expect(status.staged.isEmpty)
        #expect(status.unstaged.count == 1)
        #expect(status.unstaged[0].badge(staged: false) == "M")
    }

    /// The reason `XY` is kept as a pair instead of being collapsed: stage
    /// a file, edit it again, and it genuinely belongs in both lists — the
    /// staged copy and the newer unstaged one are different content.
    @Test func aFileStagedAndThenEditedAppearsInBothLists() {
        let status = GitStatus.parse(porcelainV2:
            "1 MM N... 100644 100644 100644 aaa bbb src/main.ts"
        )

        #expect(status.staged.count == 1)
        #expect(status.unstaged.count == 1)
        #expect(status.staged[0].path == "src/main.ts")
        #expect(status.staged[0].badge(staged: true) == "M")
        #expect(status.unstaged[0].badge(staged: false) == "M")
    }

    @Test func aStagedDeletionReadsAsDeleted() {
        let status = GitStatus.parse(porcelainV2:
            "1 D. N... 100644 000000 000000 aaa 000 old/gone.swift"
        )

        #expect(status.staged.count == 1)
        #expect(status.staged[0].badge(staged: true) == "D")
    }

    // MARK: Paths that break naive splitting

    /// The path is the last field precisely so it can contain spaces; a
    /// plain split on " " would truncate it and stage the wrong thing.
    @Test func pathsWithSpacesSurviveIntact() {
        let status = GitStatus.parse(porcelainV2:
            "1 .M N... 100644 100644 100644 aaa bbb docs/my notes/some file.md"
        )

        #expect(status.unstaged.count == 1)
        #expect(status.unstaged[0].path == "docs/my notes/some file.md")
        #expect(status.unstaged[0].name == "some file.md")
    }

    /// Assumes `core.quotePath=false` is passed. Without it git would emit
    /// `"arquivo-a\303\247\303\243o.ts"` and an accented filename would be
    /// unreadable and unstageable.
    @Test func nonAsciiPathsComeThroughAsUTF8() {
        let status = GitStatus.parse(porcelainV2:
            "1 .M N... 100644 100644 100644 aaa bbb src/configuração.ts"
        )

        #expect(status.unstaged[0].path == "src/configuração.ts")
    }

    // MARK: Renames

    /// A `2` line has one more field than a `1` line, and the last field
    /// packs the new and old path around a tab.
    @Test func aRenameKeepsBothPaths() {
        let status = GitStatus.parse(porcelainV2:
            "2 R. N... 100644 100644 100644 aaa bbb R100 src/new.swift\tsrc/old.swift"
        )

        #expect(status.staged.count == 1)
        #expect(status.staged[0].path == "src/new.swift")
        #expect(status.staged[0].originalPath == "src/old.swift")
        #expect(status.staged[0].badge(staged: true) == "R")
    }

    // MARK: Untracked

    @Test func untrackedFilesAreUnstagedAndMarked() {
        let status = GitStatus.parse(porcelainV2: "? macos/Sources/Git/GitCommand.swift")

        #expect(status.unstaged.count == 1)
        #expect(status.staged.isEmpty)
        #expect(status.unstaged[0].isUntracked)
        #expect(status.unstaged[0].isUntrackedOnly)
        #expect(status.unstaged[0].badge(staged: false) == "U")
    }

    @Test func ignoredFilesAreSkippedEntirely() {
        let status = GitStatus.parse(porcelainV2: "! node_modules/thing.js")

        #expect(status.isClean)
    }

    // MARK: Conflicts

    @Test func unmergedFilesGetTheirOwnSection() {
        let status = GitStatus.parse(porcelainV2:
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc src/conflicted.ts"
        )

        #expect(status.unmerged.count == 1)
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.isEmpty)
        #expect(status.unmerged[0].isUnmerged)
        #expect(status.unmerged[0].badge(staged: false) == "U")
    }

    // MARK: Whole-status behavior

    @Test func aCleanRepositoryHasNothingInAnySection() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.oid abc
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """)

        #expect(status.isClean)
        #expect(status.changeCount == 0)
    }

    @Test func amixedStatusSortsIntoTheRightSections() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.oid abc
        # branch.head feat/thing
        # branch.upstream origin/feat/thing
        # branch.ab +2 -0
        1 A. N... 000000 100644 100644 000 aaa added.swift
        1 .M N... 100644 100644 100644 aaa bbb edited.swift
        1 MM N... 100644 100644 100644 aaa bbb both.swift
        u UU N... 100644 100644 100644 100644 a b c conflict.swift
        ? brand-new.swift
        """)

        #expect(status.staged.map(\.name) == ["added.swift", "both.swift"])
        #expect(status.unstaged.map(\.name) == ["edited.swift", "both.swift", "brand-new.swift"])
        #expect(status.unmerged.map(\.name) == ["conflict.swift"])
        #expect(!status.isClean)
        #expect(status.ahead == 2)
    }

    @Test func garbageLinesAreIgnoredRatherThanCrashing() {
        let status = GitStatus.parse(porcelainV2: """
        # branch.head main
        1 tooshort
        2
        u
        ?
        random noise
        """)

        #expect(status.branch == "main")
        #expect(status.isClean)
    }

    @Test func emptyOutputParsesToAnEmptyStatus() {
        let status = GitStatus.parse(porcelainV2: "")

        #expect(status.branch == nil)
        #expect(status.isClean)
    }
}
