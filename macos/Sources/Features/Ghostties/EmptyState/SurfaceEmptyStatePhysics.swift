import SwiftUI

/// Ambient ghost-drift layer for an empty terminal surface.
///
/// Sits as the bottom-most child of `Ghostty.SurfaceWrapper`'s ZStack, behind
/// the Metal surface. Visible only while the surface has produced no output
/// and has no title. On first PTY output, fades out over 250ms and the
/// TimelineView dismounts so no frame work continues on active panes.
///
/// Phase A: drift + elastic ghost-ghost collisions + wall reflection.
/// Phase B will add drag/tap. Phase C/D are stretch.
struct SurfaceEmptyStatePhysics: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @State private var hasReceivedOutput: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEmpty: Bool {
        surfaceView.title.isEmpty && !hasReceivedOutput
    }

    var body: some View {
        Group {
            if isEmpty {
                if reduceMotion {
                    staticArrangement
                } else {
                    livePhysics
                }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .opacity(isEmpty ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: isEmpty)
        .onReceive(surfaceView.lastOutputSubject) { _ in
            hasReceivedOutput = true
        }
    }

    // MARK: - Live physics

    private var livePhysics: some View {
        GeometryReader { geo in
            PhysicsCanvas(bounds: CGRect(origin: .zero, size: geo.size))
        }
    }

    // MARK: - Reduce-Motion static fallback

    private var staticArrangement: some View {
        GeometryReader { geo in
            let count = 6
            let spacing = geo.size.width / CGFloat(count + 1)
            let y = geo.size.height / 2
            let chars = Array(GhostCharacter.allCases.prefix(count))
            ZStack {
                ForEach(Array(chars.enumerated()), id: \.offset) { idx, char in
                    GhostCharacterView(character: char, color: .secondary)
                        .frame(width: 48, height: 48)
                        .opacity(0.18)
                        .position(x: spacing * CGFloat(idx + 1), y: y)
                }
            }
        }
    }
}

/// Hosts the `TimelineView(.animation)` so it lives strictly inside the
/// "visible" branch — dismount when the parent hides this view, no idle frames.
private struct PhysicsCanvas: View {
    let bounds: CGRect
    @State private var world: PhysicsWorld
    @State private var lastTick: Date? = nil

    init(bounds: CGRect) {
        self.bounds = bounds
        _world = State(initialValue: PhysicsWorld.initial(in: bounds))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let _ = step(to: timeline.date)
            ZStack {
                ForEach(world.bodies) { body in
                    GhostCharacterView(character: body.character, color: body.tint)
                        .frame(width: body.radius * 2, height: body.radius * 2)
                        .position(body.position)
                }
            }
            .opacity(0.22)
        }
    }

    private func step(to date: Date) {
        let now = date
        let dt: TimeInterval
        if let last = lastTick {
            dt = max(0, now.timeIntervalSince(last))
        } else {
            dt = 1.0 / 60.0
        }
        // SwiftUI complains about state mutation during view update if we
        // mutate synchronously inside the body builder. Defer to next runloop.
        DispatchQueue.main.async {
            lastTick = now
            world = world.stepped(by: dt, bounds: bounds)
        }
    }
}
