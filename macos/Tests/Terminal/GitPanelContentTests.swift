import Foundation
@testable import Ghostty
import Testing

/// Which state the Git panel's file area shows.
///
/// The case worth guarding is the pair that looks identical from the
/// view's side: a nil status before the first load and a nil status after
/// one. Treating both as "loading" leaves a spinner turning forever on a
/// repository git can't read; treating both as "empty" is what made the
/// panel draw nothing at all while `git status` ran.
struct GitPanelContentTests {
    /// Built through the parser rather than a memberwise init, so these
    /// stay tied to what git actually produces.
    private func status(clean: Bool) -> GitStatus {
        let header = "# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0"
        guard !clean else { return GitStatus.parse(porcelainV2: header) }
        return GitStatus.parse(
            porcelainV2: header + "\n1 M. N... 100644 100644 100644 abc def a.txt"
        )
    }

    @Test func noStatusBeforeTheFirstLoadIsLoading() {
        #expect(GitPanelContent.resolve(status: nil, hasLoaded: false) == .loading)
    }

    /// The regression this type exists for: git answered and had nothing to
    /// give, so the panel must stop waiting.
    @Test func noStatusAfterTheFirstLoadIsUnreadable() {
        #expect(GitPanelContent.resolve(status: nil, hasLoaded: true) == .unreadable)
    }

    @Test func aCleanTreeIsItsOwnState() {
        #expect(GitPanelContent.resolve(status: status(clean: true), hasLoaded: true) == .clean)
    }

    @Test func changesAreListed() {
        #expect(GitPanelContent.resolve(status: status(clean: false), hasLoaded: true) == .changes)
    }

    /// A status that arrived before the flag was flipped still wins: having
    /// something to show always beats saying nothing is known yet.
    @Test func aStatusOutranksTheLoadedFlag() {
        #expect(GitPanelContent.resolve(status: status(clean: false), hasLoaded: false) == .changes)
        #expect(GitPanelContent.resolve(status: status(clean: true), hasLoaded: false) == .clean)
    }
}
