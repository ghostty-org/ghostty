import SwiftUI

struct HostingWindowKey: EnvironmentKey {
    typealias Value = () -> NSWindow? // needed for weak link
    static let defaultValue: Self.Value = { nil }
}

extension EnvironmentValues {
    /// This can be used to set the hosting NSWindow to a NSHostingView
    var hostingWindow: HostingWindowKey.Value {
        get { return self[HostingWindowKey.self] }
        set { self[HostingWindowKey.self] = newValue }
    }
}
