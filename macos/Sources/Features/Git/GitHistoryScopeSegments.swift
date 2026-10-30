import AppKit
import SwiftUI

struct GitHistoryScopeSegments: NSViewRepresentable {
    let selectedID: String?
    let select: (GitHistoryScope) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: GitHistoryScope.allCases.map(\.displayName),
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.activate(_:)))
        control.setWidth(110, forSegment: 0)
        control.setWidth(110, forSegment: 1)
        for (index, scope) in GitHistoryScope.allCases.enumerated() {
            control.setToolTip(scope.displayName, forSegment: index)
        }
        control.controlSize = .small
        control.segmentStyle = .rounded
        control.setAccessibilityLabel(GitL10n.text("History branch scope"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = select
        control.selectedSegment = GitHistoryScope.allCases.firstIndex {
            selectedID == "scope:" + $0.rawValue
        } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: 220, height: 25)
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    final class Coordinator: NSObject {
        var select: (GitHistoryScope) -> Void
        init(select: @escaping (GitHistoryScope) -> Void) { self.select = select }

        @objc func activate(_ sender: NSSegmentedControl) {
            guard GitHistoryScope.allCases.indices.contains(sender.selectedSegment) else { return }
            select(GitHistoryScope.allCases[sender.selectedSegment])
            sender.selectedSegment = -1
        }
    }
}
