import SwiftUI

/// Renders the tree-preserving adaptive layout computed by `AdaptiveLayout`.
/// Sits alongside `TerminalSplitTreeView` — the embedder picks which one to
/// render based on `layoutMode` (see ADAPTIVE_LAYOUT_PLAN.md Phase 4).
///
/// Split/drag operations (`TerminalSplitOperation.resize`/`.drop`) aren't
/// meaningful here — ratios are computed from focus, not user drags — so
/// tiles are hosted with a no-op action.
struct AdaptiveLayoutContainer: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let tree: SplitTree<Ghostty.SurfaceView>
    let focusedSurfaceID: Ghostty.SurfaceView.ID?
    var params: AdaptiveLayout.Params = .default

    /// Every tile — active, scaled, or pill — gets the same rounded
    /// boundary and a small gap from its neighbors (via the `.padding(3)`
    /// below), per the "all rounded" note in the user's UX sketch.
    private static let tileCornerRadius: CGFloat = 10

    var body: some View {
        let leaves = Array(tree)
        let engineTree = tree.root.flatMap(Self.convert)

        GeometryReader { geometry in
            let slots = AdaptiveLayout.layout(
                tree: engineTree,
                activeID: focusedSurfaceID,
                bounds: geometry.size,
                params: params)
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    if let surfaceView = leaves.first(where: { $0.id == slot.id }) {
                        AdaptiveLayoutTile(surfaceView: surfaceView, tier: slot.tier)
                            .clipShape(RoundedRectangle(cornerRadius: Self.tileCornerRadius))
                            .padding(3)
                            .frame(width: slot.rect.width, height: slot.rect.height)
                            .position(x: slot.rect.midX, y: slot.rect.midY)
                            .id(surfaceView.id)
                            // `.scaleEffect` on the live surface inside a condensed
                            // tile (see `AdaptiveLayoutTile`) is a rendering-only
                            // transform — AppKit's hit-testing doesn't follow it, so
                            // clicks on a shrunk tile land on the surface's
                            // unscaled/canonical frame instead of its visible
                            // (smaller) area. That broke Ghostty's own
                            // click-to-focus hitTest check (`SurfaceView_AppKit.swift`
                            // `localEventLeftMouseDown`), needing repeated clicks to
                            // register. Handle focus-switching explicitly here, on
                            // the outer frame (which SwiftUI positions/sizes
                            // correctly, unlike the scaled content inside it).
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    guard surfaceView.id != focusedSurfaceID else { return }
                                    surfaceView.window?.makeFirstResponder(surfaceView)
                                }
                            )
                    }
                }
            }
            // Fills the gaps between tiles (created by each tile's
            // `.padding(3)`) so the rounded boundaries are actually
            // visible — without this, the gap shows through to whatever's
            // behind the container, which is often indistinguishable from
            // the panes' own background. Reuses the same configurable
            // divider color the manual split view uses, for consistency.
            .background(ghostty.config.splitDividerColor)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: slots)
        }
    }

    /// Direct structural copy of a `SplitTree.Node` into the engine's
    /// generic `TreeNode` — same left/right/ratio shape, just keyed by
    /// `SurfaceView.id` instead of the `SurfaceView` itself, so the pure
    /// engine never needs to know about `NSView`.
    private static func convert(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> AdaptiveLayout.TreeNode<Ghostty.SurfaceView.ID> {
        switch node {
        case .leaf(let view):
            return .leaf(view.id)
        case .split(let split):
            let direction: AdaptiveLayout.Direction = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
            return .split(
                direction: direction,
                ratio: split.ratio,
                left: convert(split.left),
                right: convert(split.right))
        }
    }
}

private struct AdaptiveLayoutTile: View {
    let surfaceView: Ghostty.SurfaceView
    let tier: AdaptiveLayout.Tier

    var body: some View {
        // `.active` and `.scaled` both host the same `TerminalSplitLeaf` in
        // the same branch — only the applied scale differs (1.0 vs
        // computed) — so a tier change on focus swap only changes
        // modifiers, not the view's structural identity. Splitting these
        // into separate switch arms previously tore down and recreated the
        // surface host on every focus change, which read as the pane
        // "disappearing."
        if tier == .pill {
            // Rounding is applied uniformly by the outer `.clipShape` in
            // AdaptiveLayoutContainer, so a plain Rectangle is enough here.
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    AdaptiveLayoutTileLabel(surfaceView: surfaceView)
                        .padding(.horizontal, 8))
        } else {
            GeometryReader { geometry in
                // Real resize, not a scale or a crop — the surface renders
                // at its actual tile size, so its PTY grid gets fewer
                // columns/rows and text wraps naturally at the tile's real
                // width, at normal font size (this is what makes condensed
                // tiles readable rather than a tiny shrunk-down overview).
                // This trades away the "stable PTY grid" premise from
                // Phase 2 for this tier: every focus change resizes the
                // PTY of both the outgoing and incoming pane, same as
                // `.active` already did. Fine for plain shell content; a
                // full-screen TUI app (vim, htop) sitting in a condensed
                // tile will reflow/redraw on every relayout.
                TerminalSplitLeaf(surfaceView: surfaceView, isSplit: tier != .active, action: { _ in })
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        // Ghostty only shows a pane's title in the window
                        // titlebar while it's focused, so a condensed
                        // (unfocused) tile would otherwise be unlabeled —
                        // add a small floating header just for this tier.
                        // `.active` doesn't need one (it owns the titlebar);
                        // `.pill` already shows the title as its only
                        // content, so a second label would be redundant.
                        if tier == .scaled {
                            AdaptiveLayoutTileLabel(surfaceView: surfaceView)
                                .frame(maxWidth: max(0, geometry.size.width - 28), alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Color(nsColor: .windowBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .padding(6)
                        }
                    }
            }
        }
    }
}

/// Title label for unfocused tiles (`.scaled` header and `.pill` content):
/// a small colored dot identifying the tab, followed by its title.
private struct AdaptiveLayoutTileLabel: View {
    let surfaceView: Ghostty.SurfaceView

    /// Distinct, theme-adaptive system colors for the dots.
    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink,
    ]

    /// Derived from the surface's UUID bytes (not `hashValue`, which is
    /// seeded per process) so a tab keeps the same color as focus moves
    /// around and the layout re-renders.
    static func color(for id: UUID) -> Color {
        let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return palette[sum % palette.count]
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.color(for: surfaceView.id))
                .frame(width: 8, height: 8)
            Text(surfaceView.title.isEmpty ? "Terminal" : surfaceView.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
