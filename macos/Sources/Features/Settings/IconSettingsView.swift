import SwiftUI

/// Choosing the app's icon.
///
/// A grid of the real artwork rather than a list of names: the thing being
/// chosen is a picture, and a picker that describes pictures in words makes the
/// reader open each one to find out what it is.
struct IconSettingsView: View {
    @State private var selection: PhantomAppIcon = PhantomAppIconStore.current

    /// Held as the raw name because `IconSegmentedControl` binds to a string,
    /// the same way the cursor-style control in Appearance does.
    @State private var variantName: String = PhantomAppIconVariantStore.current.rawValue

    private var variant: PhantomAppIconVariant {
        PhantomAppIconVariant(rawValue: variantName) ?? .default
    }

    /// Set when `NSWorkspace` refuses to write the icon, which it does when the
    /// bundle is somewhere unwritable. Silence there would read as the picker
    /// being broken.
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                style

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
                                        variant: variant,
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

    /// The style control.
    ///
    /// A segmented control, which is the standard macOS control for a handful
    /// of exclusive options — and the same shape System Settings uses for this
    /// very choice under Appearance. Worth knowing: that system control is
    /// where Apple expects this to be set, for every app at once. This one
    /// applies to Phantom alone and overrides it.
    ///
    /// `IconSegmentedControl` rather than a segmented `Picker` for the reason
    /// that type already documents: it paints the selected segment with the
    /// terminal theme's accent, like the rest of these panes.
    private var style: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Style") {
                IconSegmentedControl(
                    segments: PhantomAppIconVariant.allCases.map {
                        .init(value: $0.rawValue, label: $0.title, image: nil)
                    },
                    selection: $variantName
                )
                .frame(height: 24)
                .onChange(of: variantName) { name in
                    choose(PhantomAppIconVariant(rawValue: name) ?? .default)
                }
            }

            Text("Clear follows light and dark mode; Default and Dark don't.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func choose(_ icon: PhantomAppIcon) {
        selection = icon
        report(PhantomAppIconStore.apply(icon))
    }

    private func choose(_ variant: PhantomAppIconVariant) {
        report(PhantomAppIconStore.apply(variant))
    }

    private func report(_ applied: Bool) {
        guard !applied else { return }
        failure = "The icon couldn't be applied. Phantom needs to be able to write to its own bundle."
    }
}

/// One icon in the grid: the artwork, its name, and whether it is the one.
private struct IconOption: View {
    let icon: PhantomAppIcon

    /// Passed in rather than read from the store, so switching style redraws
    /// the whole grid — the point of the control is seeing every icon in it.
    let variant: PhantomAppIconVariant
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var artwork: NSImage? {
        icon.image(variant: variant, isDark: PhantomAppIconVariantStore.isDarkAppearance)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    if let image = artwork {
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
