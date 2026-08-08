@testable import Ghostty
import Testing

struct DevServerCenterTests {
    // MARK: - port(inColumns:)

    /// Real `lsof -iTCP -sTCP:LISTEN -P -n` rows, split the same way
    /// `listeningPorts()` splits them, so this is what actually reaches the
    /// parser rather than a hand-simplified string.
    private func columns(_ line: String) -> [Substring] {
        line.split(separator: " ", omittingEmptySubsequences: true)
    }

    @Test func parsesWildcardAddress() {
        let line = "node      35934 isac.petinate   47u  IPv4 0xbb46b3e3fb5ea6e      0t0  TCP *:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    @Test func parsesLoopbackAddress() {
        let line = "node      35934 isac.petinate   47u  IPv4 0xbb46b3e3fb5ea6e      0t0  TCP 127.0.0.1:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    @Test func parsesIPv6LoopbackAddress() {
        let line = "node      35934 isac.petinate   47u  IPv6 0xbb46b3e3fb5ea6e      0t0  TCP [::1]:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    /// The trailing `(LISTEN)` column must not be mistaken for the address:
    /// it has no colon, but this guards against a future column reordering
    /// that could make it look port-shaped.
    @Test func ignoresTrailingListenMarker() {
        let line = "rapportd   1118 isac.petinate   10u  IPv4 0xef81939da8d4b4cf      0t0    TCP *:59477 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 59477)
    }

    @Test func returnsNilWhenNoColumnHasAPort() {
        let line = "COMMAND     PID          USER   FD   TYPE             DEVICE SIZE/OFF   NODE NAME"
        #expect(DevServerCenter.port(inColumns: columns(line)) == nil)
    }

    // MARK: - resolve(tracked:listeners:parents:)

    /// The real shape this exists for: a dev server sits several process
    /// layers below the tab's foreground job (`pnpm` -> `nx` -> `vite`), not
    /// as its direct child.
    @Test func attributesPortToTrackedAncestorSeveralHopsUp() {
        let tracked: Set<Int> = [100] // the surface's foreground PID (zsh)
        let parents: [Int: Int] = [
            200: 100, // pnpm, child of the shell
            300: 200, // nx, child of pnpm
            400: 300, // vite, child of nx — the actual listener
        ]
        let listeners: [Int: [Int]] = [400: [5173]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 5173])
    }

    @Test func attributesPortWhenListenerIsItselfTracked() {
        let tracked: Set<Int> = [400]
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: [:])
        #expect(resolved == [400: 3000])
    }

    /// The lowest port is treated as the server itself; higher ones on the
    /// same listener (an HMR or debug side channel) are dropped rather than
    /// overwriting it.
    @Test func picksTheLowestPortWhenAListenerHasSeveral() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [400: 100]
        let listeners: [Int: [Int]] = [400: [24678, 5173]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 5173])
    }

    /// Same when two distinct listeners resolve up to the same tracked
    /// ancestor (a server plus a separately spawned watcher, say).
    @Test func picksTheLowestPortAcrossSeparateListenersUnderTheSameAncestor() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [400: 100, 500: 100]
        let listeners: [Int: [Int]] = [400: [3000], 500: [9229]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 3000])
    }

    @Test func listenerWithNoPathToATrackedPIDIsIgnored() {
        let tracked: Set<Int> = [999]
        let parents: [Int: Int] = [400: 1] // walks straight to PID 1, no tracked ancestor
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved.isEmpty)
    }

    @Test func listenerWithAMissingParentLinkStopsWithoutCrashing() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [:] // 400's parent is unknown to the table
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved.isEmpty)
    }

    @Test func emptyListenersResolveToNothing() {
        let resolved = DevServerCenter.resolve(tracked: [100], listeners: [:], parents: [:])
        #expect(resolved.isEmpty)
    }
}
