import AppKit
import SwiftUI

/// The terminal and accessories have one native geometry owner. Hosting views
/// render leaves only; none of their intrinsic sizes can resize this container.
struct AgentQuickInputDockContainer: NSViewRepresentable {
    let content: AnyView
    let composer: AnyView
    let queue: AnyView
    let composerHeight: CGFloat
    let queueHeight: CGFloat

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ view: Container, context: Context) {
        view.update(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            queue: AnyView(queue.environment(\.self, context.environment)),
            composerHeight: composerHeight,
            queueHeight: queueHeight
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Container: NSView {
        let contentHost = NSHostingView(rootView: AnyView(EmptyView()))
        let composerHost = NSHostingView(rootView: AnyView(EmptyView()))
        let queueHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var requestedComposerHeight: CGFloat = 0
        private var requestedQueueHeight: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            for host in [contentHost, composerHost, queueHost] {
                host.sizingOptions = []
                addSubview(host)
            }
            composerHost.isHidden = true
            queueHost.isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(
            content: AnyView,
            composer: AnyView,
            queue: AnyView,
            composerHeight: CGFloat,
            queueHeight: CGFloat
        ) {
            requestedComposerHeight = max(0, composerHeight)
            requestedQueueHeight = max(0, queueHeight)
            // Publish the final viewport before SwiftUI updates the terminal
            // leaf. Updating its root at the old size produces an extra TUI
            // layout/redraw between the old and new composer reservations.
            applyAccessoryFrames()
            // Preserve the Surface and ComposerTextView instances, including
            // first responder, selection, marked text and scrollback state.
            contentHost.rootView = content
            composerHost.rootView = composer
            queueHost.rootView = queue

        }

        override func layout() {
            applyAccessoryFrames()
            super.layout()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            applyAccessoryFrames()
        }

        private func applyAccessoryFrames() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                let nextQueueHeight = min(requestedQueueHeight, max(0, bounds.height))
                let nextComposerHeight = min(requestedComposerHeight, max(0, bounds.height - nextQueueHeight))
                let frames: [(NSView, NSRect)] = [
                    (queueHost, .init(x: 0, y: 0, width: bounds.width, height: nextQueueHeight)),
                    (composerHost, .init(x: 0, y: nextQueueHeight, width: bounds.width, height: nextComposerHeight)),
                    (contentHost, .init(x: 0, y: nextQueueHeight + nextComposerHeight, width: bounds.width,
                                        height: max(0, bounds.height - nextQueueHeight - nextComposerHeight)))
                ]
                for (host, frame) in frames where host.frame != frame { host.frame = frame }
                if composerHost.isHidden != (nextComposerHeight == 0) {
                    composerHost.isHidden = nextComposerHeight == 0
                }
                if queueHost.isHidden != (nextQueueHeight == 0) {
                    queueHost.isHidden = nextQueueHeight == 0
                }
            }
        }
    }
}
