//  Reliability diagnostics for the HID path.
//
//  Both of these exist because of Phase 2 failures that reported success: a
//  message the client accepted and the guest ignored. They drive the session's
//  scripted-input API and compare the screen before and after, so a silent no-op
//  is distinguishable from a reported failure.

import AppKit
import SimPaneKit

// MARK: - Soak

/// One process, one client, many actions — the shape the product actually uses,
/// which the per-action CLI modes never exercised.
@MainActor
final class SoakRunner {

    private let session: SimulatorSession
    private let iterations: Int
    /// Where to write the screen when an action reads UNCHANGED. A delta alone
    /// cannot tell "the input was dropped" from "the tap landed somewhere
    /// inert", and guessing between those two is how Phase 2 lost a day.
    private let unchangedSnapshotDirectory: String?

    init(session: SimulatorSession, iterations: Int) {
        self.session = session
        self.iterations = iterations
        self.unchangedSnapshotDirectory =
            ProcessInfo.processInfo.environment["SIMPANE_SOAK_SNAPSHOTS"]
        if let directory = unchangedSnapshotDirectory {
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }
    }

    private func captureUnchanged(_ label: String, _ iteration: Int) {
        guard let directory = unchangedSnapshotDirectory else { return }
        let name = label.replacingOccurrences(of: " ", with: "-")
        let path = "\(directory)/unchanged-\(iteration)-\(name).png"
        do {
            try session.framebufferPNG().write(to: URL(fileURLWithPath: path))
            print("        screen at the time -> \(path)")
        } catch {
            note("        could not capture: \(error.localizedDescription)")
        }
    }

    /// Runs one action and says whether the screen responded.
    @discardableResult
    private func act(_ label: String, _ iteration: Int, settle: TimeInterval = 2.2,
                     _ body: () -> String) -> Bool {
        let before = session.framebufferSample()
        let outcome = body()
        pump(settle)
        let delta = SimulatorSession.frameDifference(before, session.framebufferSample())
        let responded = delta > 0.01
        print(String(format: "%4d  %-14s %-16s %@", iteration,
                     (label as NSString).utf8String!, (outcome as NSString).utf8String!,
                     responded ? "changed" : "UNCHANGED"))
        if !responded { captureUnchanged(label, iteration) }
        return responded
    }

    private func attempt(_ body: @escaping () async throws -> Void) -> String {
        do { try runBlocking(body); return "ok" }
        catch { return "ERR(\(error.localizedDescription))" }
    }

    private func tap(_ x: Double, _ y: Double) -> String {
        attempt { try await self.session.tap(x: x, y: y) }
    }

    private func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> String {
        attempt {
            try await self.session.swipe(
                from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y1), steps: 20, stepDelay: 0.012)
        }
    }

    private func home() -> String {
        attempt { try await self.session.pressButton(.home) }
    }

    /// Interleaves drags with taps and buttons. The plain soak only taps, and a
    /// drag turned out to break whatever followed it.
    func runWithDrags() {
        print("soak+drags: \(iterations) iterations")
        print("iter  action         result           screen")
        print(String(repeating: "-", count: 58))

        for iteration in 1...iterations {
            act("open Settings", iteration) { self.tap(0.843, 0.483) }
            act("drag scroll", iteration) { self.drag(0.5, 0.75, 0.5, 0.35) }
            act("tap after drag", iteration) { self.tap(0.25, 0.30) }
            act("home", iteration) { self.home() }
        }
    }

    func run() {
        print("soak: \(iterations) iterations, one client, one process")
        print("iter  action         result           screen")
        print(String(repeating: "-", count: 58))

        var firstSilentFailure: Int?

        for iteration in 1...iterations {
            let before = session.framebufferSample()
            let outcome = tap(0.843, 0.483)
            pump(2.2)
            let responded = SimulatorSession.frameDifference(before, session.framebufferSample()) > 0.01
            print(String(format: "%4d  %-14s %-16s %@", iteration,
                         ("tap Settings" as NSString).utf8String!,
                         (outcome as NSString).utf8String!, responded ? "changed" : "UNCHANGED"))
            // A send that reported success and changed nothing is the failure mode
            // worth naming: an error would at least be visible.
            if !responded, outcome == "ok", firstSilentFailure == nil {
                firstSilentFailure = iteration
            }

            act("home", iteration, settle: 2.0) { self.home() }
        }

        if let firstSilentFailure {
            print("\nfirst SILENT failure (send reported ok, screen unchanged): iteration \(firstSilentFailure)")
        } else {
            print("\nno silent failures across \(iterations) iterations")
        }
    }
}

// MARK: - Probe

/// Does the HID session go stale between uses?
///
/// Sends one gesture that is known to land, waits a configurable interval, then
/// sends a second. Run against a freshly booted device so the first gesture is
/// guaranteed to work; the second is the measurement.
@MainActor
func runProbe(session: SimulatorSession, gap: TimeInterval) {
    func tap(_ x: Double, _ y: Double) -> String {
        do { try runBlocking { try await session.tap(x: x, y: y) }; return "ok" }
        catch { return "ERR(\(error.localizedDescription))" }
    }

    print(String(format: "probe: gap of %.1fs between gestures", gap))

    let a = session.framebufferSample()
    let r1 = tap(0.843, 0.483)          // Settings icon on the home screen
    pump(2.5)
    let b = session.framebufferSample()
    print("  gesture 1 (open Settings): \(r1)  "
        + (SimulatorSession.frameDifference(a, b) > 0.01 ? "LANDED" : "ignored"))

    pump(gap)

    let r2 = tap(0.25, 0.38)            // a row inside Settings
    pump(2.5)
    let c = session.framebufferSample()
    print("  gesture 2 (tap a row)    : \(r2)  "
        + (SimulatorSession.frameDifference(b, c) > 0.01 ? "LANDED" : "ignored"))
}
