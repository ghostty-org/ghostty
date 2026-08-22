import SwiftUI

// MARK: Surface Environment Keys

extension EnvironmentValues {
    @Entry var ghosttySurfaceView: Ghostty.SurfaceView?

    /// Optional read-only last-focused surface reference. If a surface view is currently focused this
    /// is equal to the currently focused surface.
    @Entry var ghosttyLastFocusedSurface: Weak<Ghostty.SurfaceView>?
}

extension View {
    func ghosttySurfaceView(_ surfaceView: Ghostty.SurfaceView?) -> some View {
        environment(\.ghosttySurfaceView, surfaceView)
    }

    /// The most recently focused surface (can be currently focused if the surface is currently focused).
    func ghosttyLastFocusedSurface(_ surfaceView: Weak<Ghostty.SurfaceView>?) -> some View {
        environment(\.ghosttyLastFocusedSurface, surfaceView)
    }
}

// MARK: Surface Focus Keys

extension FocusedValues {
    @Entry var ghosttySurfaceView: Ghostty.SurfaceView?

    @Entry var ghosttySurfacePwd: String?

    @Entry var ghosttySurfaceCellSize: CGSize?
}
