import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class GitDiffScrollLink {
    var enabled = true
    var presentation = GitDiffPresentation(before: "", after: "", patch: "")
    private var endpoints: [Int: Endpoint] = [:]
    private var pendingLines: [Int: Int] = [:]
    private var syncing = false

    final class Endpoint {
        weak var view: TextView?
        var observer: NSObjectProtocol?
        var lastOrigin: NSPoint?
        init(_ view: TextView) { self.view = view }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func register(_ view: TextView, side: Int) {
        let endpoint = Endpoint(view)
        endpoints[side] = endpoint
        guard let clip = view.enclosingScrollView?.contentView else { return }
        endpoint.lastOrigin = clip.bounds.origin
        clip.postsBoundsChangedNotifications = true
        endpoint.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                  object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled(side: side) }
        }
        applyPendingJump(side: side)
    }

    func unregister(_ view: TextView?, side: Int) {
        if endpoints[side]?.view === view { endpoints.removeValue(forKey: side) }
    }

    func scrolled(side: Int) {
        guard let source = endpoints[side], let view = source.view,
              let clip = view.enclosingScrollView?.contentView else { return }
        let origin = clip.bounds.origin
        guard origin != source.lastOrigin else { return }
        source.lastOrigin = origin
        guard enabled, !syncing, let destination = endpoints[1 - side], let target = destination.view,
              let targetScroll = target.enclosingScrollView,
              let line = view.layoutManager.textLineForPosition(max(0, origin.y)) else { return }
        let mapping = side == 0 ? presentation.beforeToAfter : presentation.afterToBefore
        guard let index = mapping[line.index],
              let targetLine = target.layoutManager.textLineForIndex(index) else { return }
        syncing = true
        defer { syncing = false }
        // CodeEditTextView removed `ensureLayoutUntil` because it destroyed
        // layout information; `rectForOffset` lays out the line it resolves.
        _ = target.layoutManager.rectForOffset(targetLine.range.location)
        let laidOut = target.layoutManager.textLineForIndex(index) ?? targetLine
        let fraction = max(0, min(1, (origin.y - line.yPos) / max(1, line.height)))
        let y = laidOut.yPos + fraction * laidOut.height
        let targetClip = targetScroll.contentView
        let point = NSPoint(x: max(0, min(origin.x, target.bounds.width - targetClip.bounds.width)),
                            y: max(0, min(y, target.bounds.height - targetClip.bounds.height)))
        destination.lastOrigin = point
        targetClip.scroll(to: point)
        targetScroll.reflectScrolledClipView(targetClip)
    }

    func jump(to lines: [Int: Int]) {
        pendingLines.merge(lines) { _, new in new }
        for side in lines.keys { applyPendingJump(side: side) }
    }

    func queueJump(to lines: [Int: Int]) {
        pendingLines = lines
    }

    private func applyPendingJump(side: Int) {
        guard let index = pendingLines[side], let endpoint = endpoints[side], let view = endpoint.view,
              let scrollView = view.enclosingScrollView,
              let line = view.layoutManager.textLineForIndex(index) else { return }
        _ = view.layoutManager.rectForOffset(line.range.location)
        let resolved = view.layoutManager.textLineForIndex(index) ?? line
        let clip = scrollView.contentView
        let point = NSPoint(x: clip.bounds.origin.x,
                            y: max(0, min(resolved.yPos - 8, view.bounds.height - clip.bounds.height)))
        endpoint.lastOrigin = point
        clip.scroll(to: point)
        scrollView.reflectScrolledClipView(clip)
        pendingLines.removeValue(forKey: side)
    }
}

@MainActor
final class GitDiffScrollEndpoint: @preconcurrency TextViewCoordinator {
    let link: GitDiffScrollLink
    let side: Int
    private weak var view: TextView?
    init(link: GitDiffScrollLink, side: Int) { self.link = link; self.side = side }
    func prepareCoordinator(controller: TextViewController) {
        view = controller.textView
        // The source editor calls prepare before loadView creates its scroll view.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let text = controller?.textView, self.view === text else { return }
            self.link.register(text, side: self.side)
        }
    }
    func destroy() {
        link.unregister(view, side: side)
        view = nil
    }
}

/// Each native editor gets its own endpoint. A departing editor must never
/// unregister the replacement created while changing files or display modes.
struct GitDiffLinkedEditor: View {
    let text: String
    let path: String
    let highlights: [Int: Bool]
    let isActive: Bool
    let theme: EditorTheme
    let wordWrap: Bool
    let close: () -> Void
    let actions: GitDiffEditorActions
    @State private var endpoint: GitDiffScrollEndpoint

    init(text: String, path: String, highlights: [Int: Bool], isActive: Bool,
         theme: EditorTheme, wordWrap: Bool = true, link: GitDiffScrollLink, side: Int,
         actions: GitDiffEditorActions = GitDiffEditorActions(), close: @escaping () -> Void) {
        self.text = text; self.path = path; self.highlights = highlights
        self.isActive = isActive; self.theme = theme; self.close = close
        self.wordWrap = wordWrap
        self.actions = actions
        _endpoint = State(initialValue: GitDiffScrollEndpoint(link: link, side: side))
    }

    var body: some View {
        CodeEditorView(text: .constant(text), fileURL: URL(fileURLWithPath: path, isDirectory: false),
                       diffLines: highlights, additionalCoordinators: [endpoint],
                       isEditable: false, isActive: isActive, isSurfaceFocused: actions.isSurfaceFocused,
                       terminalTheme: theme, wordWrapOverride: wordWrap, onFocus: actions.focus, onClose: close, onOpen: actions.open,
                       onNextDocument: actions.nextDocument, onPreviousDocument: actions.previousDocument,
                       onSaveAll: actions.saveAll, onHide: actions.hide)
    }
}
