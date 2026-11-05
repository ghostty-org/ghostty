import AppKit

enum SurfaceCoreResizeAction: Equatable {
    case normal(CGSize)
    case live(CGSize)
    case commit
}

/// Pure state machine used by `SurfacePresentation` so interactive resize
/// behavior can be tested without constructing a Ghostty surface.
struct SurfaceCoreResizeState {
    private(set) var requestedSize: CGSize?
    private(set) var appliedSize: CGSize?
    private(set) var committedSize: CGSize?
    private(set) var interactionDepth = 0
    private(set) var interactionMode: TerminalResizeRenderingMode?
    private(set) var hasUncommittedLiveSize = false

    mutating func beginInteraction(mode: TerminalResizeRenderingMode) {
        if interactionDepth == 0 { interactionMode = mode }
        interactionDepth += 1
    }

    mutating func request(_ size: CGSize) -> SurfaceCoreResizeAction? {
        guard requestedSize != size else { return nil }
        requestedSize = size

        guard interactionDepth > 0 else {
            appliedSize = size
            committedSize = size
            hasUncommittedLiveSize = false
            return .normal(size)
        }

        switch interactionMode {
        case .duringDrag:
            appliedSize = size
            hasUncommittedLiveSize = committedSize != size
            return .live(size)
        case .onRelease:
            return nil
        case nil:
            return nil
        }
    }

    mutating func commitLiveSizeIfNeeded() -> SurfaceCoreResizeAction? {
        guard interactionMode == .duringDrag,
              hasUncommittedLiveSize else { return nil }
        committedSize = appliedSize
        hasUncommittedLiveSize = false
        return .commit
    }

    mutating func endInteraction() -> SurfaceCoreResizeAction? {
        guard interactionDepth > 0 else { return nil }
        interactionDepth -= 1
        guard interactionDepth == 0 else { return nil }
        return finishInteraction()
    }

    mutating func cancelInteractions() -> SurfaceCoreResizeAction? {
        interactionDepth = 0
        return finishInteraction()
    }

    private mutating func finishInteraction() -> SurfaceCoreResizeAction? {
        defer { interactionMode = nil }
        switch interactionMode {
        case .duringDrag:
            return commitLiveSizeIfNeeded()
        case .onRelease:
            guard let size = requestedSize, appliedSize != size else { return nil }
            appliedSize = size
            committedSize = size
            hasUncommittedLiveSize = false
            return .normal(size)
        case nil:
            return nil
        }
    }
}

/// Issued by the model when the displayed split tree changes. Retained SwiftUI
/// trees keep their original lease; creating a new NSView does not renew it.
final class SurfacePresentationLease {}

/// Presentation and pending PTY geometry live as long as the Surface, not its
/// replaceable SwiftUI adapter. References back to AppKit owners stay weak.
@MainActor final class SurfacePresentation {
    private weak var surface: Ghostty.SurfaceView?
    private(set) var lease: SurfacePresentationLease?
    private weak var owner: SurfaceScrollView?
    private var resizeState = SurfaceCoreResizeState()
    private var resizeCommit: DispatchWorkItem?

    init(surface: Ghostty.SurfaceView) {
        self.surface = surface
    }

    func authorize(_ lease: SurfacePresentationLease?) {
        guard self.lease !== lease else { return }
        finishResize()
        self.lease = lease
        owner = nil
    }

    func revoke(_ lease: SurfacePresentationLease) {
        guard self.lease === lease else { return }
        authorize(nil)
    }

    func mount(_ wrapper: SurfaceScrollView, lease: SurfacePresentationLease?) -> Bool {
        guard let lease, self.lease === lease else { return false }
        if owner !== wrapper {
            finishResize()
            owner?.retire()
            owner = wrapper
        }
        return true
    }

    func owns(_ wrapper: SurfaceScrollView) -> Bool {
        owner === wrapper
    }

    func unmount(_ wrapper: SurfaceScrollView) {
        guard owns(wrapper) else { return }
        finishResize()
        owner = nil
    }

    func requestSize(_ size: CGSize) {
        if let action = resizeState.request(size) { apply(action) }
    }

    func beginResize() {
        resizeState.beginInteraction(mode: OhMyGhosttySettings.shared.terminalResizeRendering)
    }

    func endResize() {
        cancelScheduledCommit()
        if let action = resizeState.endInteraction() { apply(action) }
    }

    func finishResize() {
        cancelScheduledCommit()
        if let action = resizeState.cancelInteractions() { apply(action) }
    }

    private func cancelScheduledCommit() {
        resizeCommit?.cancel()
        resizeCommit = nil
    }

    private func apply(_ action: SurfaceCoreResizeAction) {
        guard let surface else { return }
        switch action {
        case .normal(let size):
            surface.sizeDidChange(size)
        case .live(let size):
            surface.liveSizeDidChange(size)
            cancelScheduledCommit()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resizeCommit = nil
                if let action = self.resizeState.commitLiveSizeIfNeeded() { self.apply(action) }
            }
            resizeCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        case .commit:
            surface.commitLiveSize()
        }
    }

    deinit {
        resizeCommit?.cancel()
    }
}
