import AppKit
import SwiftUI

/// A segmented control that shows an icon beside each label.
///
/// SwiftUI's segmented `Picker` renders a `Label` as its title alone and
/// drops the image; `NSSegmentedControl` carries both, which is what lets
/// options whose meaning is a shape be recognised without reading.
struct IconSegmentedControl: NSViewRepresentable {
    struct Segment {
        let value: String
        let label: String
        let image: NSImage?
    }

    let segments: [Segment]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.segmentCount = segments.count
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(to: control)
    }

    private func apply(to control: NSSegmentedControl) {
        for (index, segment) in segments.enumerated() {
            control.setLabel(segment.label, forSegment: index)
            guard let image = segment.image else { continue }
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
        }

        let index = segments.firstIndex { $0.value == selection }
        control.selectedSegment = index ?? -1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: IconSegmentedControl

        init(_ parent: IconSegmentedControl) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.segments.indices.contains(index) else { return }
            parent.selection = parent.segments[index].value
        }
    }
}
