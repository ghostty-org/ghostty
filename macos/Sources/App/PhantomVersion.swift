import Foundation

/// Phantom's own identity, versioned independently of the upstream
/// Ghostty core it is built on.
enum Phantom {
    static let name = "Phantom"
    static let tagline = "A Ghostty-powered terminal with grouped tabs,\nagent awareness and a native settings experience."

    /// Phantom's own semantic version. Reads the bundle rather than
    /// duplicating it as a second hardcoded string: `MARKETING_VERSION` in
    /// the Xcode project (`Ghostty` target, macOS) is the one place this is
    /// set, so bumping a release means changing it there, not here and
    /// there and hoping they stay in sync.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static let repositoryURL = URL(string: "https://github.com/ipetinate/phantom")!

    /// Ghostty is not a dependency of this project — it is the project's
    /// engine. The about window says so plainly rather than burying it in a
    /// licence file, with both names linked to their real homes rather than
    /// left as unclickable text.
    static let upstreamAuthor = "Mitchell Hashimoto"
    static let upstreamURL = "https://ghostty.org"
    static let upstreamAuthorURL = "https://github.com/mitchellh"
    static let upstreamCredit = """
        Everything that makes a terminal a terminal here — the renderer, \
        the emulation, libghostty — is [Ghostty](\(upstreamURL)), created by \
        [\(upstreamAuthor)](\(upstreamAuthorURL)) and its contributors. \
        Phantom is a fork that adds a sidebar and the app around it.
        """

    /// The upstream Ghostty core this build is based on — `build.zig.zon`'s
    /// own `.version`, which is the actual source of truth for it.
    ///
    /// Not read from the bundle: `CFBundleShortVersionString` is Phantom's
    /// *own* version (see `version` above), a completely different number
    /// that happened to satisfy the compiler while reporting the wrong
    /// thing here — Ghostty Core showed Phantom's version, not Ghostty's.
    /// There is no build step wiring `build.zig.zon` into the app bundle,
    /// so this has to be updated by hand when rebasing onto a newer
    /// Ghostty tip; it is not going to drift quietly, since a stale value
    /// only shows up here, not as a build failure.
    static let upstreamCoreVersion = "1.3.2-dev"
}
