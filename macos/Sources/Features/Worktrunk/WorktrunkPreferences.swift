import Foundation

enum WorktrunkOpenBehavior: String, CaseIterable, Identifiable {
    case newTab = "new_tab"
    case splitRight = "split_right"
    case splitDown = "split_down"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        }
    }
}

enum WorktrunkPreferences {
    static let openBehaviorKey = "GhosttyWorktrunkOpenBehavior.v1"
}

