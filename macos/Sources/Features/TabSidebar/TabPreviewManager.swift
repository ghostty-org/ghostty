import AppKit
import Combine
import SwiftUI

/// Manages thumbnail preview generation for terminal surfaces displayed in the tab sidebar.
/// Updates previews at a throttled rate (~5fps) to balance responsiveness with performance.
class TabPreviewManager: ObservableObject {
    /// Target FPS for preview updates (throttled to reduce GPU/CPU usage)
    static let targetFPS: Double = 5.0
    private let updateInterval: TimeInterval = 1.0 / targetFPS

    /// Preview images keyed by surface ID
    @Published private(set) var previews: [UUID: NSImage] = [:]

    /// The surfaces being tracked for preview generation
    private var surfaces: [Ghostty.SurfaceView] = []

    /// Timer for throttled updates
    private var updateTimer: Timer?

    /// Preview thumbnail size
    private(set) var thumbnailSize: CGSize

    /// Background queue for preview generation
    private let previewQueue = DispatchQueue(label: "com.ghostty.tabPreviewManager", qos: .userInitiated)

    /// Initializes the preview manager with a specified thumbnail width.
    /// - Parameter thumbnailWidth: The width of generated thumbnails in points. Height is calculated to maintain aspect ratio.
    init(thumbnailWidth: CGFloat = 180) {
        // Use 16:10 aspect ratio typical for terminal windows
        self.thumbnailSize = CGSize(width: thumbnailWidth, height: thumbnailWidth * 0.625)
    }

    /// Starts tracking the given surfaces for preview generation.
    /// - Parameter surfaces: The surfaces to generate previews for.
    func startTracking(surfaces: [Ghostty.SurfaceView]) {
        self.surfaces = surfaces
        startUpdateTimer()
        // Generate initial previews immediately
        updatePreviews()
    }

    /// Stops tracking all surfaces and invalidates the update timer.
    func stopTracking() {
        updateTimer?.invalidate()
        updateTimer = nil
        surfaces = []
    }

    /// Updates the list of tracked surfaces without restarting the timer.
    /// - Parameter surfaces: The new list of surfaces to track.
    func updateSurfaces(_ surfaces: [Ghostty.SurfaceView]) {
        self.surfaces = surfaces
        // Remove previews for surfaces that no longer exist
        let surfaceIds = Set(surfaces.map { $0.id })
        previews = previews.filter { surfaceIds.contains($0.key) }
    }

    // MARK: - Private Methods

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updatePreviews()
        }
        // Add to common run loop mode so timer fires during UI interactions
        if let timer = updateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func updatePreviews() {
        // Capture surfaces on main thread since they're NSViews
        let surfacesToCapture = surfaces

        previewQueue.async { [weak self] in
            guard let self = self else { return }

            var newPreviews: [UUID: NSImage] = [:]

            for surface in surfacesToCapture {
                // Must capture screenshot on main thread
                var screenshot: NSImage?
                DispatchQueue.main.sync {
                    screenshot = surface.screenshot()
                }

                // Use full resolution screenshot for better quality
                if let fullImage = screenshot {
                    newPreviews[surface.id] = fullImage
                }
            }

            DispatchQueue.main.async {
                // Only update changed previews to minimize UI updates
                for (id, image) in newPreviews {
                    self.previews[id] = image
                }
            }
        }
    }

    /// Creates a scaled-down thumbnail from the full-size image.
    /// - Parameter image: The source image to scale down.
    /// - Returns: A thumbnail image, or nil if scaling fails.
    private func createThumbnail(from image: NSImage) -> NSImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0 && sourceSize.height > 0 else { return nil }

        // Calculate scale to fit within thumbnail size while maintaining aspect ratio
        let scaleX = thumbnailSize.width / sourceSize.width
        let scaleY = thumbnailSize.height / sourceSize.height
        let scale = min(scaleX, scaleY)

        let targetSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1.0
        )

        thumbnail.unlockFocus()
        return thumbnail
    }

    deinit {
        stopTracking()
    }
}
