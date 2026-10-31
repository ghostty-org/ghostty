import AppKit

/// Loading intent survives pane caching; animation only belongs to a visible
/// window. A timer avoids one blocking AppKit animation worker per loading row.
final class NativeProgressIndicator: NSProgressIndicator {
    private(set) var animationRequested = false
    private(set) var animationIsRunning = false
    private var observations: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        usesThreadedAnimation = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    func setAnimating(_ requested: Bool) {
        animationRequested = requested
        reconcileAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let window {
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAnimation() }
            })
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRunning(false) }
            })
        }
        reconcileAnimation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        setRunning(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileAnimation()
    }

    private func reconcileAnimation() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        setRunning(animationRequested && visible && !isHiddenOrHasHiddenAncestor)
    }

    private func setRunning(_ running: Bool) {
        guard animationIsRunning != running else { return }
        animationIsRunning = running
        if running { super.startAnimation(nil) } else { super.stopAnimation(nil) }
    }
}
