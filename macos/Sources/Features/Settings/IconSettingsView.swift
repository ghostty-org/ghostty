import SwiftUI

/// Choosing the app's icon.
///
/// A grid of the real artwork rather than a list of names: the thing being
/// chosen is a picture, and a picker that describes pictures in words makes the
/// reader open each one to find out what it is.
struct IconSettingsView: View {
    @State private var selection: PhantomAppIcon = PhantomAppIconStore.current

    /// Set when `NSWorkspace` refuses to write the icon, which it does when the
    /// bundle is somewhere unwritable. Silence there would read as the picker
    /// being broken.
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Grouped by family, and driven by `Family.allCases` so a new
                // group is a new case rather than another block of this view.
                ForEach(PhantomAppIcon.Family.allCases) { family in
                    let icons = PhantomAppIcon.all(in: family)
                    if !icons.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(family.title)
                                .font(.headline)

                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(icons) { icon in
                                    IconOption(
                                        icon: icon,
                                        isSelected: icon == selection,
                                        onSelect: { choose(icon) }
                                    )
                                }
                            }
                        }
                    }
                }

                Text(
                    """
                    The icon is applied to the app on disk, so the Dock and the \
                    app switcher follow immediately. A rebuild from source \
                    resets it, and Phantom puts your choice back on the next \
                    launch.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .alert(
            failure ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        }
    }

    private func choose(_ icon: PhantomAppIcon) {
        selection = icon
        guard PhantomAppIconStore.apply(icon) else {
            failure = "The icon couldn't be applied. Phantom needs to be able to write to its own bundle."
            return
        }
    }
}

/// One icon in the grid: the artwork, its name, and whether it is the one.
private struct IconOption: View {
    let icon: PhantomAppIcon
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    if let image = icon.image() {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        // A missing asset is a build mistake, and saying so
                        // beats an empty square that looks like a design.
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                Image(systemName: "questionmark")
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 76, height: 76)
                .scaleEffect(isHovered ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            isSelected ? Color.accentColor : .clear,
                            lineWidth: 2.5
                        )
                        .padding(-4)
                )

                Text(icon.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(icon.rawValue)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
