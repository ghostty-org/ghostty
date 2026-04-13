enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "The Ghostties app isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "Ghostties doesn't allow Shortcuts."
        }
    }
}
