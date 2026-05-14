import SwiftUI

/// One ghost body in the empty-state physics simulation.
///
/// Velocity is expressed in points-per-frame at 60fps. Step functions multiply
/// by `dt * 60` so motion stays frame-rate independent without changing the
/// pacing units the design feedback is calibrated against.
struct GhostBody: Identifiable, Equatable {
    let id: UUID
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    let character: GhostCharacter
    var tint: Color

    static func == (lhs: GhostBody, rhs: GhostBody) -> Bool {
        lhs.id == rhs.id &&
        lhs.position == rhs.position &&
        lhs.velocity.dx == rhs.velocity.dx &&
        lhs.velocity.dy == rhs.velocity.dy &&
        lhs.radius == rhs.radius &&
        lhs.character == rhs.character
    }
}

/// Pure value-type physics world. Step returns a new world; no observable.
struct PhysicsWorld {
    var bodies: [GhostBody]

    /// Spawn `count` non-repeating ghosts inside `bounds`, with calm drift
    /// velocities (0.22–0.40 px/frame, randomized direction).
    static func initial(in bounds: CGRect, count: Int = 7, radius: CGFloat = 24) -> PhysicsWorld {
        guard bounds.width > radius * 4 && bounds.height > radius * 4 else {
            return PhysicsWorld(bodies: [])
        }
        let safe = bounds.insetBy(dx: radius, dy: radius)
        var used: Set<GhostCharacter> = []
        var bodies: [GhostBody] = []
        bodies.reserveCapacity(count)
        for _ in 0..<count {
            let char = GhostCharacter.randomUnused(excluding: used)
            used.insert(char)
            let angle = Double.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: 0.22...0.40)
            bodies.append(GhostBody(
                id: UUID(),
                position: CGPoint(
                    x: CGFloat.random(in: safe.minX...safe.maxX),
                    y: CGFloat.random(in: safe.minY...safe.maxY)
                ),
                velocity: CGVector(
                    dx: speed * CGFloat(cos(angle)),
                    dy: speed * CGFloat(sin(angle))
                ),
                radius: radius,
                character: char,
                tint: .secondary
            ))
        }
        return PhysicsWorld(bodies: bodies)
    }

    /// Advance the world by `dt` seconds clamped to `bounds`. Pure: returns a
    /// new world. `dt` is real wall-clock time; velocities are px/frame at 60fps.
    func stepped(by dt: TimeInterval, bounds: CGRect) -> PhysicsWorld {
        // Cap dt so a paused tab or a hitch can't teleport bodies through walls.
        let scaled = CGFloat(min(dt, 1.0 / 30.0) * 60.0)
        var next = bodies.map { body -> GhostBody in
            var b = body
            b.position.x += b.velocity.dx * scaled
            b.position.y += b.velocity.dy * scaled
            return PhysicsCollision.reflectAgainstWalls(body: b, in: bounds)
        }
        // Pairwise resolution. n is small (≤8), O(n²) is fine.
        for i in 0..<next.count {
            for j in (i + 1)..<next.count {
                let (a, b) = PhysicsCollision.resolvePair(next[i], next[j])
                next[i] = a
                next[j] = b
            }
        }
        return PhysicsWorld(bodies: next)
    }
}
