import AppKit
import Testing
@testable import Ghostty

@MainActor
struct OMGAppearanceSynchronizationTests {
    @Test func inheritedConfigAppearanceDoesNotAlternateWithSystem() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let policy = OMGAppearancePolicy(override: nil, configured: dark)
        #expect(policy.appearance?.name == .darkAqua)
        #expect(!policy.overridesEveryWindow)
        var current: NSAppearance?
        var assignments = 0
        for _ in 0..<100 where policy.needsUpdate(current: current) {
            current = policy.appearance
            assignments += 1
        }
        #expect(assignments == 1)
        #expect(current?.name == .darkAqua)
    }

    @Test func overridesHaveOneApplicationAndWindowPolicy() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(OMGAppearancePolicy(override: .light, configured: dark).appearance?.name == .aqua)
        #expect(OMGAppearancePolicy(override: .dark, configured: light).appearance?.name == .darkAqua)
        let system = OMGAppearancePolicy(override: .system, configured: dark)
        #expect(system.appearance == nil)
        #expect(system.overridesEveryWindow)
        #expect(system.needsUpdate(current: dark))
        #expect(!system.needsUpdate(current: nil))
        #expect(!OMGAppearancePolicy(override: nil, configured: nil).needsUpdate(current: nil))
    }

    @Test func repeatedAndReentrantSchemeNotificationsAreSuppressed() {
        let tracker = OMGColorSchemeTracker()
        var reloads = 0
        func report(_ dark: Bool) {
            guard tracker.consume(isDark: dark) else { return }
            reloads += 1
            // libghostty may synchronously publish configuration during this call.
            #expect(!tracker.consume(isDark: dark))
        }
        for _ in 0..<100 { report(true) }
        #expect(reloads == 1)
        report(false)
        report(false)
        #expect(reloads == 2)
        report(true)
        #expect(reloads == 3)
    }

    @Test func applicationWritesSettleEvenWhenKVOReportsEveryAssignment() throws {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        let tracker = OMGColorSchemeTracker()
        var assignments = 0
        var reports = 0
        let observation = application.observe(\.effectiveAppearance, options: [.new]) { _, change in
            assignments += 1
            if let appearance = change.newValue, tracker.consume(isDark: appearance.isDark) { reports += 1 }
        }
        defer { observation.invalidate() }
        let policy = OMGAppearancePolicy(override: nil, configured: NSAppearance(named: .darkAqua))
        for _ in 0..<100 { policy.apply(to: application) }
        #expect(assignments <= 1)
        #expect(reports <= 1)
        #expect(application.appearance?.name == .darkAqua)
    }
}
