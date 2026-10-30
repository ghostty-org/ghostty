import AppKit
import SwiftUI

struct GitPullPushControl: NSViewRepresentable {
    let isBusy: Bool
    let canPull: Bool
    let canPush: Bool
    let canPushTo: Bool
    let canMerge: Bool
    let behindCount: Int?
    let aheadCount: Int?
    let perform: (InspectorGitAction) -> Void

    func makeNSView(context: Context) -> Control {
        Control()
    }

    func updateNSView(_ view: Control, context: Context) {
        view.configure(self)
    }

    final class Control: NSButton {
        private var content: GitPullPushControl?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .recessed
            isBordered = false
            image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: GitL10n.text("Pull or Push"))
            imagePosition = .imageOnly
            setAccessibilityLabel(GitL10n.text("Pull or Push"))
            target = self
            action = #selector(toggleMenu)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(_ content: GitPullPushControl) {
            self.content = content
            isEnabled = content.canPull || content.canPush || content.canPushTo || content.canMerge
            if content.isBusy {
                title = ""
                image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: GitL10n.text("Pull or Push"))
            } else {
                title = ""
                image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: GitL10n.text("Pull or Push"))
            }
        }

        @objc private func toggleMenu() {
            guard let content, window != nil else { return }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            guard let content else { return menu }
            menu.autoenablesItems = false
            let snapshot = content
            addItem("Pull", symbol: "arrow.down", count: content.behindCount,
                    enabled: content.canPull, action: .pull, snapshot: snapshot, to: menu)
            addItem("Push", symbol: "arrow.up", count: content.aheadCount,
                    enabled: content.canPush, action: .push, snapshot: snapshot, to: menu)
            menu.addItem(.separator())
            addItem("Push to…", symbol: "arrow.up.right", enabled: content.canPushTo,
                    action: .pushTo, snapshot: snapshot, to: menu)
            addItem("Merge into…", symbol: "arrow.triangle.pull", enabled: content.canMerge,
                    action: .merge, snapshot: snapshot, to: menu)
            return menu
        }

        fileprivate enum Action: Int {
            case pull, push, pushTo, merge
        }

        private func addItem(
            _ title: String,
            symbol: String,
            count: Int? = nil,
            enabled: Bool,
            action: Action,
            snapshot: GitPullPushControl,
            to menu: NSMenu
        ) {
            let suffix = count.flatMap { $0 > 0 ? "  \($0)" : nil } ?? ""
            let item = NSMenuItem(title: GitL10n.text(title) + suffix, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            item.tag = action.rawValue
            item.representedObject = GitPullPushInvocation(action: action, perform: snapshot.perform)
            item.isEnabled = enabled
            menu.addItem(item)
        }

        @objc private func performMenuAction(_ item: NSMenuItem) {
            guard let invocation = item.representedObject as? GitPullPushInvocation else { return }
            switch invocation.action {
            case .pull: invocation.perform(.pull)
            case .push: invocation.perform(.push)
            case .pushTo: invocation.perform(.pushTo)
            case .merge: invocation.perform(.integration(.review, nil))
            }
        }
    }
}

private final class GitPullPushInvocation: NSObject {
    let action: GitPullPushControl.Control.Action
    let perform: (InspectorGitAction) -> Void

    init(action: GitPullPushControl.Control.Action, perform: @escaping (InspectorGitAction) -> Void) {
        self.action = action
        self.perform = perform
    }
}
