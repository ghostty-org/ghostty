import CoreGraphics

/// Pure collision math for the empty-state physics layer. No SwiftUI imports;
/// every function takes plain values and returns plain values so the math is
/// unit-testable without a host app.
enum PhysicsCollision {

    /// Clamp a body's position to `bounds` and reflect its velocity on the
    /// axis it crossed. The body is treated as a circle of radius `body.radius`.
    static func reflectAgainstWalls(body: GhostBody, in bounds: CGRect) -> GhostBody {
        var b = body
        let r = b.radius
        if b.position.x < bounds.minX + r {
            b.position.x = bounds.minX + r
            if b.velocity.dx < 0 { b.velocity.dx = -b.velocity.dx }
        } else if b.position.x > bounds.maxX - r {
            b.position.x = bounds.maxX - r
            if b.velocity.dx > 0 { b.velocity.dx = -b.velocity.dx }
        }
        if b.position.y < bounds.minY + r {
            b.position.y = bounds.minY + r
            if b.velocity.dy < 0 { b.velocity.dy = -b.velocity.dy }
        } else if b.position.y > bounds.maxY - r {
            b.position.y = bounds.maxY - r
            if b.velocity.dy > 0 { b.velocity.dy = -b.velocity.dy }
        }
        return b
    }

    /// Equal-mass perfectly-elastic circle-circle collision. If `a` and `b`
    /// overlap, separate them along the contact normal and exchange the
    /// normal-component of their velocities. Tangential component is preserved.
    /// If they do not overlap, returns them unchanged.
    static func resolvePair(_ a: GhostBody, _ b: GhostBody) -> (GhostBody, GhostBody) {
        var a = a
        var b = b
        let dx = b.position.x - a.position.x
        let dy = b.position.y - a.position.y
        let distSq = dx * dx + dy * dy
        let minDist = a.radius + b.radius
        if distSq >= minDist * minDist { return (a, b) }
        let dist = sqrt(distSq)
        // Degenerate: exactly co-located. Nudge along x to avoid NaN.
        let nx: CGFloat
        let ny: CGFloat
        if dist < 1e-9 {
            nx = 1
            ny = 0
        } else {
            nx = dx / dist
            ny = dy / dist
        }
        // Separate along the normal so they're just touching.
        let overlap = minDist - dist
        let half = overlap * 0.5
        a.position.x -= nx * half
        a.position.y -= ny * half
        b.position.x += nx * half
        b.position.y += ny * half
        // Velocity exchange along normal. Equal mass => swap normal components,
        // keep tangential. Only swap if approaching (dot of relative velocity
        // on the normal is negative from a's frame).
        let rvx = b.velocity.dx - a.velocity.dx
        let rvy = b.velocity.dy - a.velocity.dy
        let approachSpeed = rvx * nx + rvy * ny
        if approachSpeed < 0 {
            a.velocity.dx += approachSpeed * nx
            a.velocity.dy += approachSpeed * ny
            b.velocity.dx -= approachSpeed * nx
            b.velocity.dy -= approachSpeed * ny
        }
        return (a, b)
    }
}
