import AppKit
import SwiftUI

enum EditorContentKey: Hashable {
    case terminal
    case workspace
    case document(EditorDocumentID)
    case diff(UUID)
    case empty
}

struct EditorContentItem {
    let id: EditorContentKey
    let content: AnyView
}

/// The pane and the document deck use the same ownership rule: native hiding,
/// one fixed content rectangle, and a cache bounded by the open-document model.
struct NativeEditorContentDeck: NSViewControllerRepresentable {
    let items: [EditorContentItem]
    let selectedID: EditorContentKey
    var didSelect: (EditorContentKey) -> Void = { _ in }

    func makeNSViewController(context: Context) -> EditorContentDeckController {
        EditorContentDeckController()
    }

    func updateNSViewController(_ controller: EditorContentDeckController, context: Context) {
        controller.update(items: items.map {
            EditorContentItem(id: $0.id, content: AnyView($0.content.environment(\.self, context.environment)))
        }, selectedID: selectedID, didSelect: didSelect)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: EditorContentDeckController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class EditorContentDeckController: NSViewController {
    private(set) var hosts: [EditorContentKey: NSHostingView<AnyView>] = [:]
    private(set) var selectedID: EditorContentKey?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
    }

    func update(items: [EditorContentItem], selectedID: EditorContentKey,
                didSelect: (EditorContentKey) -> Void = { _ in }) {
        _ = view
        let available = Set(items.map(\.id))
        for key in hosts.keys where !available.contains(key) {
            if let host = hosts.removeValue(forKey: key) {
                relinquishFocus(in: host)
                host.removeFromSuperview()
            }
        }
        for item in items {
            if let host = hosts[item.id] {
                // Inactive leaves still receive their isActive=false transition
                // to flush autosave and dismiss editor-owned transient UI.
                host.rootView = item.content
            } else if item.id == selectedID || item.id == .terminal {
                let host = NSHostingView(rootView: item.content)
                host.sizingOptions = []
                host.frame = view.bounds
                host.autoresizingMask = [.width, .height]
                view.addSubview(host)
                hosts[item.id] = host
            }
        }
        for (id, host) in hosts {
            if id != selectedID { relinquishFocus(in: host) }
            host.isHidden = id != selectedID
        }
        let changed = self.selectedID != nil && self.selectedID != selectedID
        self.selectedID = selectedID
        if changed { didSelect(selectedID) }
    }

    private func relinquishFocus(in host: NSView) {
        if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: host) {
            view.window?.makeFirstResponder(nil)
        }
    }
}
