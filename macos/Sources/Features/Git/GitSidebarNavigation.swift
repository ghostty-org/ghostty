import AppKit
import SwiftUI

struct GitSidebarNavigation: NSViewRepresentable {
    let selected: InspectorGitContent.ActiveTab
    let select: (InspectorGitContent.ActiveTab) -> Void

    func makeNSView(context: Context) -> GitPopoverSegments {
        let control = GitPopoverSegments()
        control.stretchesToWidth = true
        return control
    }
    func updateNSView(_ control: GitPopoverSegments, context: Context) {
        control.configure(segments: InspectorGitContent.ActiveTab.allCases.map {
            .init(id: $0.rawValue, title: GitL10n.text($0.rawValue), accessibilityLabel: GitL10n.text($0.rawValue))
        }, selectedID: selected.rawValue, colors: .init(nativeTheme: .resolve(for: control)), widths: [78, 78, 78])
        control.onSelect = { id in
            if let tab = InspectorGitContent.ActiveTab.allCases.first(where: { $0.rawValue == id }) { select(tab) }
        }
        control.setAccessibilityLabel(GitL10n.text("Git sections"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitPopoverSegments, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 28)
    }

}
