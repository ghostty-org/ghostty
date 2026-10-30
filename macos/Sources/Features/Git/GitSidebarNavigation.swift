import AppKit
import SwiftUI

struct GitSidebarNavigation: NSViewRepresentable {
    let selected: InspectorGitContent.ActiveTab
    let select: (InspectorGitContent.ActiveTab) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: InspectorGitContent.ActiveTab.allCases.map { GitL10n.text($0.rawValue) },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.activate(_:))
        )
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.setAccessibilityLabel(GitL10n.text("Git sections"))
        update(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        update(control, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 28)
    }

    private func update(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = select
        control.selectedSegment = InspectorGitContent.ActiveTab.allCases.firstIndex(of: selected) ?? 0
        control.setAccessibilityValue(GitL10n.text(selected.rawValue))
    }

    @MainActor
    final class Coordinator: NSObject {
        var select: (InspectorGitContent.ActiveTab) -> Void

        init(select: @escaping (InspectorGitContent.ActiveTab) -> Void) {
            self.select = select
        }

        @objc func activate(_ sender: NSSegmentedControl) {
            let tabs = InspectorGitContent.ActiveTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            select(tabs[sender.selectedSegment])
        }
    }
}
