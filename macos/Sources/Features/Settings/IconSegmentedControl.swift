import AppKit
import SwiftUI

/// A segmented control that shows an icon beside each label.
///
/// SwiftUI's segmented `Picker` renders a `Label` as its title alone and
/// drops the image, which is why this exists at all — but a plain SwiftUI
/// track (not `NSSegmentedControl`) so the selected segment paints with the
/// terminal theme's accent like every other control here, rather than the
/// system accent color `NSSegmentedControl.selectedSegmentBezelColor`
/// (itself only honored in the `.separated` style, not `.automatic`) would
/// have been stuck on regardless of theme.
struct IconSegmentedControl: View {
    struct Segment {
        let value: String
        let label: String
        let image: NSImage?
    }

    let segments: [Segment]
    @Binding var selection: String

    @ObservedObject private var palette: ThemePalette = .shared

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 4) {
                        if let image = segment.image {
                            Image(nsImage: image)
                        }
                        Text(segment.label)
                            .font(palette.font(size: 11, weight: isSelected ? .medium : .regular))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        )
    }
}
