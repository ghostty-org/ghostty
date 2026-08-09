import Foundation
@testable import Ghostty
import Testing

/// `GitFailure` against git's real output.
///
/// Every transcript below is what git actually prints — the point of the
/// type is that the sentence worth reading is rarely the first or last
/// line, so tests built from paraphrased output would prove nothing.
struct GitFailureTests {
    // MARK: Working tree in the way

    /// The classic pull refusal. Note the ordering the parser has to
    /// survive: the useful sentence sits *after* a fetch transcript and
    /// *before* the file list.
    @Test func localChangesBlockingAPullAreNamed() {
        let failure = GitFailure(operation: "Pull", output: """
            From github.com:ipetinate/phantom
             * branch            main       -> FETCH_HEAD
            error: Your local changes to the following files would be overwritten by merge:
            \tmacos/Sources/App.swift
            \tREADME.md
            Please commit your changes or stash them before you merge.
            Aborting
            """)

        #expect(failure.title == "Local changes are in the way")
        #expect(failure.files == ["macos/Sources/App.swift", "README.md"])
        #expect(failure.summary != nil)
    }

    @Test func untrackedFilesBlockingACheckoutAreNamed() {
        let failure = GitFailure(operation: "Checkout", output: """
            error: The following untracked working tree files would be overwritten by checkout:
            \tsrc/new.ts
            Please move or remove them before you switch branches.
            Aborting
            """)

        #expect(failure.title == "Untracked files are in the way")
        #expect(failure.files == ["src/new.ts"])
    }

    /// The file list ends at the first un-indented line, not at the end of
    /// the output — otherwise the trailing advice becomes a "file".
    @Test func theFileListStopsAtTheNextSentence() {
        let failure = GitFailure(operation: "Pull", output: """
            error: Your local changes to the following files would be overwritten by merge:
            \tone.txt
            Please commit your changes or stash them before you merge.
            \tnot-a-file.txt
            """)

        #expect(failure.files == ["one.txt"])
    }

    // MARK: Remote state

    @Test func aRejectedPushExplainsThatTheRemoteMoved() {
        let failure = GitFailure(operation: "Push", output: """
            To github.com:ipetinate/phantom.git
             ! [rejected]        main -> main (non-fast-forward)
            error: failed to push some refs to 'github.com:ipetinate/phantom.git'
            hint: Updates were rejected because the tip of your current branch is behind
            """)

        #expect(failure.title == "The remote has changes you don't")
    }

    @Test func aBranchWithNoUpstreamPointsAtPublish() {
        let failure = GitFailure(operation: "Push", output: """
            fatal: The current branch feat/sidebar-git-panel has no upstream branch.
            To push the current branch and set the remote as upstream, use

                git push --set-upstream origin feat/sidebar-git-panel
            """)

        #expect(failure.title == "This branch isn't on the remote yet")
        #expect(failure.summary?.contains("Publish Branch") == true)
    }

    @Test func divergedBranchesAreCalledOutSeparately() {
        let failure = GitFailure(operation: "Pull", output: """
            hint: You have divergent branches and need to specify how to reconcile them.
            fatal: Need to specify how to reconcile divergent branches.
            """)

        #expect(failure.title != "Pull failed")
    }

    // MARK: Auth and network

    @Test func anSSHRefusalIsAuthNotNetwork() {
        let failure = GitFailure(operation: "Push", output: """
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            """)

        #expect(failure.title == "The remote refused the connection")
        #expect(failure.summary?.contains("SSH") == true)
    }

    @Test func anUnresolvableHostIsNetwork() {
        let failure = GitFailure(operation: "Fetch", output: """
            ssh: Could not resolve hostname github.com: nodename nor servname provided
            fatal: Could not read from remote repository.
            """)

        #expect(failure.title == "Couldn't reach the remote")
    }

    // MARK: Local mistakes

    @Test func nothingStagedIsItsOwnMessage() {
        let failure = GitFailure(operation: "Commit", output: """
            On branch main
            nothing to commit, working tree clean
            """)

        #expect(failure.title == "Nothing to commit")
    }

    @Test func anUnsetIdentityIsRecognized() {
        let failure = GitFailure(operation: "Commit", output: """
            Author identity unknown

            *** Please tell me who you are.

            Run

              git config --global user.email "you@example.com"
            """)

        #expect(failure.title == "Git doesn't know who you are")
    }

    @Test func anExistingBranchIsRecognized() {
        let failure = GitFailure(
            operation: "Create Branch",
            output: "fatal: a branch named 'main' already exists"
        )

        #expect(failure.title == "That branch already exists")
    }

    @Test func anEmptyStashIsRecognized() {
        let failure = GitFailure(operation: "Stash Pop", output: "No stash entries found.")
        #expect(failure.title == "There's no stash to pop")
    }

    // MARK: Hooks

    /// A hook rejection is the project's own rules talking, so the title
    /// says so and the transcript — which carries the actual lint output —
    /// is what the user reads.
    @Test func aHookRejectionIsFramedAsTheProjectsRules() {
        let failure = GitFailure(operation: "Commit", output: """
            ✖ eslint --fix found some errors. Please fix them and try committing again.
            husky - pre-commit hook exited with code 1 (error)
            """)

        #expect(failure.title.contains("hook"))
        #expect(failure.raw.contains("eslint"))
    }

    // MARK: Fallbacks

    /// Unrecognized output still has to produce something readable. Git's
    /// `error:`/`fatal:` line beats the last line, which is usually a hint.
    @Test func anUnknownFailureLeadsWithGitsOwnFlaggedLine() {
        let failure = GitFailure(operation: "Rebase", output: """
            Some transcript line
            fatal: it broke in a way nobody predicted
            hint: try turning it off and on again
            """)

        #expect(failure.title == "Rebase failed")
        #expect(failure.summary == "it broke in a way nobody predicted")
    }

    @Test func aSilentFailureStillSaysWhichOperationFailed() {
        let failure = GitFailure(operation: "Push", output: "   \n  ")

        #expect(failure.title == "Push failed")
        #expect(failure.summary != nil)
        #expect(failure.raw.isEmpty)
    }

    /// The transcript is kept verbatim in every case — it is the escape
    /// hatch for everything the summary flattens away.
    @Test func theRawTranscriptIsAlwaysPreserved() {
        let output = "error: Your local changes to the following files would be overwritten by merge:\n\tone.txt"
        let failure = GitFailure(operation: "Pull", output: output)

        #expect(failure.raw == output)
    }
}
