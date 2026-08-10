import Foundation
@testable import Ghostty
import Testing

/// Phantom's own version, told apart from the engine's.
///
/// The fork's releases were numbered from `build.zig.zon`, which still carried
/// Ghostty's 1.3.x — so a download read as a finished product while the app
/// itself already reported 0.2.0. The two now agree.
struct PhantomVersionTests {
    /// Below 1.0, SemVer already says "not stable". The about window says it
    /// out loud rather than relying on the reader knowing that.
    @Test func aZeroVersionIsABeta() {
        #expect(Phantom.isPrerelease, "the app's own version should still be 0.x")
        #expect(Phantom.versionSummary.hasSuffix("(beta)"))
    }

    /// And the label goes away on its own at 1.0, rather than needing to be
    /// remembered.
    @Test func theBetaLabelIsDerivedNotHardcoded() {
        #expect(Phantom.versionSummary.hasPrefix(Phantom.version))
        #expect(Phantom.versionSummary != Phantom.version)
    }

    /// The engine's version is a different number and must not be read from
    /// the bundle — that bug showed Phantom's version in the "Ghostty Core"
    /// row, which is worse than showing nothing.
    @Test func theEngineVersionIsItsOwnNumber() {
        #expect(Phantom.upstreamCoreVersion != Phantom.version)
        #expect(Phantom.upstreamCoreVersion.hasPrefix("1."))
    }

    @Test func theBundleReportsAVersionAtAll() {
        #expect(Phantom.version != "unknown")
    }
}
