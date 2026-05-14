import XCTest
import CoreGraphics
import SwiftUI
@testable import Ghostty

final class EmptyStatePhysicsTests: XCTestCase {
    private let eps: CGFloat = 1e-9

    // MARK: - Wall reflection

    func testWallReflectionFlipsXOnRightWall() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        var body = makeBody(x: 96, y: 50, dx: 0.3, dy: 0.0, r: 10)
        body = PhysicsCollision.reflectAgainstWalls(body: body, in: bounds)
        XCTAssertEqual(body.position.x, 90, accuracy: eps)
        XCTAssertLessThan(body.velocity.dx, 0)
        XCTAssertEqual(body.velocity.dy, 0, accuracy: eps)
    }

    func testWallReflectionFlipsYOnBottomWall() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        var body = makeBody(x: 50, y: 96, dx: 0.0, dy: 0.3, r: 10)
        body = PhysicsCollision.reflectAgainstWalls(body: body, in: bounds)
        XCTAssertEqual(body.position.y, 90, accuracy: eps)
        XCTAssertLessThan(body.velocity.dy, 0)
    }

    func testWallReflectionLeavesInteriorAlone() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let original = makeBody(x: 50, y: 50, dx: 0.3, dy: -0.2, r: 10)
        let reflected = PhysicsCollision.reflectAgainstWalls(body: original, in: bounds)
        XCTAssertEqual(reflected.position.x, original.position.x, accuracy: eps)
        XCTAssertEqual(reflected.position.y, original.position.y, accuracy: eps)
        XCTAssertEqual(reflected.velocity.dx, original.velocity.dx, accuracy: eps)
        XCTAssertEqual(reflected.velocity.dy, original.velocity.dy, accuracy: eps)
    }

    // MARK: - Pair resolution

    func testPairResolutionExchangesVelocityForHeadOn() {
        let a = makeBody(x: 0, y: 0, dx: 0.4, dy: 0.0, r: 10)
        let b = makeBody(x: 18, y: 0, dx: -0.4, dy: 0.0, r: 10)
        let (a2, b2) = PhysicsCollision.resolvePair(a, b)
        // Head-on equal masses along x: their dx swaps sign.
        XCTAssertLessThan(a2.velocity.dx, 0)
        XCTAssertGreaterThan(b2.velocity.dx, 0)
        // No motion injected on y.
        XCTAssertEqual(a2.velocity.dy, 0, accuracy: eps)
        XCTAssertEqual(b2.velocity.dy, 0, accuracy: eps)
    }

    func testPairResolutionNoOpWhenNotOverlapping() {
        let a = makeBody(x: 0, y: 0, dx: 0.3, dy: 0.0, r: 10)
        let b = makeBody(x: 100, y: 0, dx: -0.3, dy: 0.0, r: 10)
        let (a2, b2) = PhysicsCollision.resolvePair(a, b)
        XCTAssertEqual(a2.position.x, a.position.x, accuracy: eps)
        XCTAssertEqual(b2.position.x, b.position.x, accuracy: eps)
        XCTAssertEqual(a2.velocity.dx, a.velocity.dx, accuracy: eps)
        XCTAssertEqual(b2.velocity.dx, b.velocity.dx, accuracy: eps)
    }

    func testPairResolutionSeparatesOverlappingBodies() {
        let a = makeBody(x: 0, y: 0, dx: 0.0, dy: 0.0, r: 10)
        let b = makeBody(x: 5, y: 0, dx: 0.0, dy: 0.0, r: 10)
        let (a2, b2) = PhysicsCollision.resolvePair(a, b)
        let separation = b2.position.x - a2.position.x
        XCTAssertEqual(separation, 20, accuracy: 1e-6)
    }

    func testPairResolutionDoesNotReverseSeparatingBodies() {
        // Already moving apart: positions overlap (or just touch) but
        // approachSpeed >= 0 means we should NOT flip their velocities.
        let a = makeBody(x: 0, y: 0, dx: -0.3, dy: 0.0, r: 10)
        let b = makeBody(x: 18, y: 0, dx: 0.3, dy: 0.0, r: 10)
        let (a2, b2) = PhysicsCollision.resolvePair(a, b)
        XCTAssertLessThan(a2.velocity.dx, 0)
        XCTAssertGreaterThan(b2.velocity.dx, 0)
    }

    // MARK: - World step

    func testWorldStepWithZeroVelocityProducesIdenticalPositions() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let body = makeBody(x: 100, y: 100, dx: 0.0, dy: 0.0, r: 10)
        let world = PhysicsWorld(bodies: [body])
        let next = world.stepped(by: 1.0 / 60.0, bounds: bounds)
        XCTAssertEqual(next.bodies[0].position.x, 100, accuracy: eps)
        XCTAssertEqual(next.bodies[0].position.y, 100, accuracy: eps)
    }

    func testInitialWorldRespectsCount() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let world = PhysicsWorld.initial(in: bounds, count: 5)
        XCTAssertEqual(world.bodies.count, 5)
        // No two bodies should share the same character on a clean spawn.
        let chars = Set(world.bodies.map { $0.character })
        XCTAssertEqual(chars.count, 5)
    }

    func testInitialWorldReturnsEmptyForTinyBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let world = PhysicsWorld.initial(in: bounds, count: 5, radius: 24)
        XCTAssertTrue(world.bodies.isEmpty)
    }

    // MARK: - Helper

    private func makeBody(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, r: CGFloat) -> GhostBody {
        GhostBody(
            id: UUID(),
            position: CGPoint(x: x, y: y),
            velocity: CGVector(dx: dx, dy: dy),
            radius: r,
            character: .blinky,
            tint: .secondary
        )
    }
}
