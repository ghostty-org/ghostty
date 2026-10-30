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
        private var composerHeightConstraint: NSLayoutConstraint!
        private var queueHeightConstraint: NSLayoutConstraint!
        private var requestedComposerHeight: CGFloat = 0
        private var requestedQueueHeight: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            for host in [contentHost, composerHost, queueHost] {
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            composerHeightConstraint = composerHost.heightAnchor.constraint(equalToConstant: 0)
            queueHeightConstraint = queueHost.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                contentHost.topAnchor.constraint(equalTo: topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: composerHost.topAnchor),
                composerHost.bottomAnchor.constraint(equalTo: queueHost.topAnchor),
                queueHost.bottomAnchor.constraint(equalTo: bottomAnchor),
                composerHeightConstraint,
                queueHeightConstraint,
            ])
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
            // Preserve the Surface and ComposerTextView instances, including
            // first responder, selection, marked text and scrollback state.
            contentHost.rootView = content
            composerHost.rootView = composer
            queueHost.rootView = queue

            // Assign both final extents together. Do not animate constraints or
            // call layout between them: the terminal sees one layout commit.
            // Queue card animations remain entirely inside the queue leaf.
            requestedComposerHeight = max(0, composerHeight)
            requestedQueueHeight = max(0, queueHeight)
            applyAccessoryHeights()
        }

        override func layout() {
            applyAccessoryHeights()
            super.layout()
        }

        private func applyAccessoryHeights() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                let nextQueueHeight = min(requestedQueueHeight, max(0, bounds.height))
                let nextComposerHeight = min(requestedComposerHeight, max(0, bounds.height - nextQueueHeight))
                if composerHeightConstraint.constant != nextComposerHeight {
                    composerHeightConstraint.constant = nextComposerHeight
                }
                if queueHeightConstraint.constant != nextQueueHeight {
                    queueHeightConstraint.constant = nextQueueHeight
                }
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
