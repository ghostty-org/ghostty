import Foundation

/// Phantom's own identity, versioned independently of the upstream
/// Ghostty core it is built on.
enum Phantom {
    static let name = "Phantom"
    static let version = "0.1.0"
    static let tagline = "A Ghostty-powered terminal with grouped tabs,\nagent awareness and a native settings experience."

    static let repositoryURL = URL(string: "https://github.com/ipetinate/ghostty")!
    static let upstreamURL = URL(string: "https://github.com/ghostty-org/ghostty")!

    /// The upstream Ghostty version this build is based on.
    static var upstreamVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
