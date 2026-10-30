import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SplitTabPresentationTests {
    private func pane(_ state: TabActivityState = .idle, focused: Bool = false) -> SplitTabPane {
        .init(id: UUID(), icon: .systemSymbol("terminal"),
              activity: .init(source: "pi", state: state, label: nil, message: nil,
                              detail: nil, progress: nil, icon: nil),
              title: "Terminal", focused: focused)
    }

    @Test func switchingTabsClearsPaneFocusTintWithoutDiscardingFocusHistory() {
        let remembered = UUID(), other = UUID()
        #expect(SplitTabPane.isPaneFocused(selected: true, surfaceID: remembered, focusedID: remembered))
        #expect(!SplitTabPane.isPaneFocused(selected: true, surfaceID: other, focusedID: remembered))
        let inactive = SplitTabPane.isPaneFocused(selected: false, surfaceID: remembered, focusedID: remembered)
        #expect(!inactive)
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: inactive) == 0)
        #expect(AgentLogoStyle.tintStrength(state: nil, focused: inactive) == 0)
        #expect(SplitTabPane.isPaneFocused(selected: true, surfaceID: remembered, focusedID: remembered))
    }

    @Test func regionRetainsLastFocusWhenFocusMovesElsewhere() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = TabPaneFocusHistory()
        history.record(a, liveIDs: [a, b, c])
        history.record(b, liveIDs: [a, b, c])
        history.record(c, liveIDs: [a, b, c])
        #expect(history.representative(in: [a, b], focused: c) == b)
        #expect(history.representative(in: [a, b], focused: a) == a)
        history.record(nil, liveIDs: [a, c])
        #expect(history.representative(in: [a], focused: c) == a)
        #expect(history.representative(in: [], focused: c) == nil)
    }

    @Test func enlargedCompositionFitsFootprint() {
        #expect(TabIconMetrics.composition == 22)
        #expect(TabIconMetrics.composition < TabIconMetrics.footprint)
        for density in OhMyGhosttyTabRowDensity.allCases {
            #expect(TabIconMetrics.footprint <= density.rowHeight)
        }
        for preferred in [CGFloat(12), 16, 20] {
            #expect(TabIconMetrics.singleLogo(preferred) < TabIconMetrics.footprint)
        }
    }

    @Test func previewDividersRespectNestedRatiosAndBounds() {
        let a = MockView(), b = MockView(), c = MockView()
        let tree = SplitTree<MockView>(root: .split(.init(
            direction: .horizontal, ratio: 0.4, left: .leaf(view: a),
            right: .split(.init(direction: .vertical, ratio: 0.25,
                                left: .leaf(view: b), right: .leaf(view: c)))
        )), zoomed: nil)
        let dividers = TabSplitPreviewLayout.dividers(tree: tree, size: CGSize(width: 200, height: 120))
        #expect(dividers == [
            .init(start: CGPoint(x: 80, y: 0), end: CGPoint(x: 80, y: 120)),
            .init(start: CGPoint(x: 80, y: 30), end: CGPoint(x: 200, y: 30))
        ])
        #expect(TabSplitPreviewLayout.dividers(tree: SplitTree<MockView>(), size: .zero).isEmpty)
        #expect(TabSplitPreviewLayout.dividers(tree: SplitTree(view: a), size: CGSize(width: 200, height: 120)).isEmpty)
    }

    @Test func workingBreathHasVisibleRangeAndHonorsReducedMotion() {
        let low = AgentLogoStyle.breath(at: 0.9, reduceMotion: false)
        let high = AgentLogoStyle.breath(at: 0, reduceMotion: false)
        #expect(abs(low) < 0.001)
        #expect(abs(high - 1) < 0.001)
        #expect(AgentLogoStyle.logoOpacity(breath: high) - AgentLogoStyle.logoOpacity(breath: low) > 0.4)
        #expect(AgentLogoStyle.breath(at: 0, reduceMotion: true) == 1)
        #expect(AgentLogoStyle.breath(at: 0.9, reduceMotion: true) == 1)
        #expect(abs(AgentLogoStyle.breath(at: 1.8, reduceMotion: false) - 1) < 0.001)
    }

    @Test func breathRunsOnlyForVisibleWorkingLogos() {
        #expect(AgentLogoStyle.animates(state: .working, visible: true, reduceMotion: false))
        #expect(!AgentLogoStyle.animates(state: .working, visible: false, reduceMotion: false))
        #expect(!AgentLogoStyle.animates(state: .working, visible: true, reduceMotion: true))
        for state: TabActivityState? in [nil, .idle, .done, .needsAttention, .error] {
            #expect(!AgentLogoStyle.animates(state: state, visible: true, reduceMotion: false))
        }
    }

    @Test func nativeBreathAnimatesOnlyLayerOpacityAndStopsAtFullBrightness() throws {
        // Keep the unattached fixture's transaction open; committing an
        // orphan layer lets CoreAnimation discard its pending animations.
        CATransaction.begin()
        defer { CATransaction.commit() }
        let layer = CALayer()
        AgentLogoLayerBreath.setRunning(true, on: layer)
        let animation = try #require(layer.animation(forKey: AgentLogoLayerBreath.key) as? CABasicAnimation)
        #expect(animation.keyPath == "opacity")
        #expect(animation.fromValue as? Double == 1)
        #expect(animation.toValue as? Double == 0.30)
        #expect(animation.duration == 0.9)
        #expect(animation.autoreverses)
        #expect(animation.repeatCount.isInfinite)
        #expect(layer.opacity == 1)
        // Mark the installed animation to detect accidental restarts on an
        // unrelated activity/focus update.
        let marked = try #require(animation.copy() as? CABasicAnimation)
        marked.beginTime = 123
        layer.add(marked, forKey: AgentLogoLayerBreath.key)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key)?.beginTime == 123)
        AgentLogoLayerBreath.setRunning(false, on: layer)
        #expect(layer.animationKeys()?.isEmpty ?? true)
        #expect(layer.opacity == 1)
    }

    @Test func nativeLogoHasStableSizeAndDoesNotAnimateWithoutVisibleWindow() throws {
        let host = AgentLogoAnimationHost()
        host.setContent(AnyView(Color.red.frame(width: 18, height: 18)), working: true)
        #expect(host.hostingView.fittingSize == CGSize(width: 18, height: 18))
        let layer = try #require(host.layer)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
        #expect(host.hitTest(.zero) == nil)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        host.setContent(AnyView(Color.green.frame(width: 18, height: 18)), working: false)
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
        #expect(layer.opacity == 1)
        AgentLogoLayerBreath.setRunning(true, on: layer)
        host.stop()
        #expect(layer.animation(forKey: AgentLogoLayerBreath.key) == nil)
    }

    private func snapshot<V: View>(_ content: V) throws -> NSBitmapImageRep {
        // ImageRenderer cannot render the AppKit container. Exercise the real
        // NSHostingView/subview path instead of silently omitting the logos.
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @Test func focusAndWorkUseSameTintStrengthWhileDoneRemainsVisible() {
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: true) ==
                AgentLogoStyle.tintStrength(state: .working, focused: true))
        #expect(AgentLogoStyle.tintStrength(state: .idle, focused: false) == 0)
        #expect(AgentLogoStyle.tintStrength(state: .done, focused: true) ==
                AgentLogoStyle.tintStrength(state: .done, focused: false))
        #expect(AgentLogoStyle.tintStrength(state: .done, focused: true) >= 0.7)
        #expect(AgentLogoStyle.logoOpacity(breath: 0) == 0.30)
        #expect(AgentLogoStyle.logoOpacity(breath: 1) == 1)
    }

    @Test func renderAgentTintSamples() throws {
        let agents: [SupportedAgent] = [.codex, .pi, .antigravity]
        let states: [TabActivityState] = [.idle, .working, .needsAttention, .error, .done]
        let content = VStack(spacing: 16) {
            ForEach(agents, id: \.rawValue) { agent in
                HStack(spacing: 18) {
                    ForEach(states.indices, id: \.self) { index in
                        let sample = SplitTabPane(id: UUID(), icon: .asset(agent.assetName),
                                                  activity: pane(states[index]).activity,
                                                  title: agent.displayName, focused: false)
                        PaneLogoMark(pane: sample, size: 22)
                    }
                }
            }
        }.padding(20)
            .background(Color(red: 0.14, green: 0.14, blue: 0.19))
            .environment(\.colorScheme, .dark)
        let bitmap = try snapshot(content)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-agent-tint-preview.png"))
    }

    @Test func renderActualSizeComposition() throws {
        let positions: [[CGPoint]] = [
            [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
            [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
             CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
        ]
        let preview = HStack(spacing: 16) {
            ForEach(positions.indices, id: \.self) { layout in
                ZStack {
                    ForEach(positions[layout].indices, id: \.self) { index in
                        PaneLogoMark(pane: pane(index == positions[layout].count - 1 ? .working : .idle), size: TabIconMetrics.pane)
                            .position(x: positions[layout][index].x * TabIconMetrics.composition,
                                      y: positions[layout][index].y * TabIconMetrics.composition)
                    }
                }
                .frame(width: TabIconMetrics.composition, height: TabIconMetrics.composition)
                .frame(width: TabIconMetrics.footprint, height: TabIconMetrics.footprint)
            }
        }
        let bitmap = try snapshot(preview.padding(16).background(Color(nsColor: .windowBackgroundColor)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-pane-icons-preview.png"))
    }
}
