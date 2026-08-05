import Foundation
import Combine

/// Window-level sidebar layout state shared between the controller
/// (which owns the split view constraints) and the SwiftUI sidebar.
@MainActor
final class SidebarLayoutModel: ObservableObject {
    /// Collapsed shows only a thin rail with the expand button.
    @Published var isCollapsed = false

    /// Creates a new terminal tab in this window's tab group.
    var onNewTab: () -> Void = {}
}
