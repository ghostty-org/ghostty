import Foundation

/// Whether this copy of the app came out of a local build.
///
/// There are two Phantoms on a machine that develops Phantom: the one in
/// `/Applications` that gets used for work, and the one in `zig-out` that is
/// being changed. They look identical, which is how an afternoon gets spent
/// testing a fix in the wrong window — or, worse, how the working one gets
/// quit by a command aimed at the other.
enum DevelopmentBuild {
    /// Read from where the bundle lives, not from a flag someone has to
    /// remember to set. `zig build` puts the app in `zig-out`, and nothing
    /// installed ever runs from there — so the signal is a property of how
    /// the copy was produced rather than of anybody's discipline.
    static let isActive: Bool = {
        // An explicit override still wins, for a local build copied
        // elsewhere or a release being checked with the marker on.
        if let flag = Bundle.main.object(forInfoDictionaryKey: "PhantomDevelopmentBuild") as? Bool {
            return flag
        }
        return isBuildOutputPath(Bundle.main.bundlePath)
    }()

    /// Pure, so the one decision in here is testable without a bundle.
    static func isBuildOutputPath(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        return components.contains("zig-out") || components.contains("DerivedData")
    }

    /// What the badge says. Short, because it sits in a title bar.
    static let label = "DEV"

    /// Which environment a badge is marking.
    ///
    /// The colours are the convention, and the convention is inverted on
    /// purpose: green means "go ahead and break it", amber means "look before
    /// you touch", red means "full attention". Only `development` is ever
    /// produced today; the others exist so the scale is written down rather
    /// than reinvented when a staging build appears.
    enum Environment {
        case development
        case staging
        case production

        var label: String {
            switch self {
            case .development: return "DEV"
            case .staging: return "STAGING"
            case .production: return "PROD"
            }
        }
    }

    static var environment: Environment { .development }
}
