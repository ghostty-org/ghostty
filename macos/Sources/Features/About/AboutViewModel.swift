import Combine

class AboutViewModel: ObservableObject {
    /// Kept so the icon can respond to hover; the icon itself is Phantom's
    /// own, rather than a rotation through the upstream icon variants.
    @Published var isHovering: Bool = false
}
