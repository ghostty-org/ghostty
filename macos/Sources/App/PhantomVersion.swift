import Foundation

/// Phantom's own identity, versioned independently of the upstream
/// Ghostty core it is built on.
enum Phantom {
    static let name = "Phantom"
    static let version = "0.1.0"
    static let tagline = "A Ghostty-powered terminal with grouped tabs,\nagent awareness and a native settings experience."

    static let author = "Isac Petinate"

    static let repositoryURL = URL(string: "https://github.com/ipetinate/ghostty")!

    /// Ghostty is not a dependency of this project — it is the project's
    /// engine. The about window says so plainly rather than burying it in a
    /// licence file.
    static let upstreamAuthor = "Mitchell Hashimoto"
    static let upstreamCredit = """
        Everything that makes a terminal a terminal here — the renderer, \
        the emulation, libghostty — is Ghostty, created by \
        \(upstreamAuthor) and its contributors. Phantom is a fork that \
        adds a sidebar and the app around it.
        """

    /// The upstream Ghostty version this build is based on.
    static var upstreamVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
