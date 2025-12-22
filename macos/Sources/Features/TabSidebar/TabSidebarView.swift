import SwiftUI

/// Represents a tab item in the sidebar with its associated surface information.
struct SidebarTabItem: Identifiable {
    let id: UUID
    let surfaceID: UUID
    let title: String
    let tabIndex: Int

    init(surface: Ghostty.SurfaceView, index: Int) {
        self.id = surface.id
        self.surfaceID = surface.id
        self.title = surface.title
        self.tabIndex = index
    }
}

/// The main tab sidebar view that displays tabs in a vertical column with live previews.
struct TabSidebarView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var previewManager: TabPreviewManager

    /// All tab items to display in the sidebar
    let tabItems: [SidebarTabItem]

    /// Currently selected surface ID
    @Binding var selectedSurfaceID: UUID?

    /// Sidebar width
    let sidebarWidth: CGFloat

    /// Sidebar height (for calculating optimal column count)
    let sidebarHeight: CGFloat

    /// Callbacks for tab actions
    let onNewTab: () -> Void
    let onCloseTab: (UUID) -> Void
    let onSelectTab: (UUID) -> Void

    /// Fixed column count based on number of tabs
    private var columnCount: Int {
        let count = tabItems.count
        if count <= 4 {
            return 2
        } else if count <= 9 {
            return 3
        } else {
            return 4
        }
    }

    /// Calculate the optimal item height to fill available space without scrolling
    private var itemSize: CGSize {
        let cols = columnCount
        let rows = Int(ceil(Double(tabItems.count) / Double(cols)))

        let horizontalPadding: CGFloat = 16 // 8 on each side
        let verticalPadding: CGFloat = 24   // 12 on top and bottom
        let spacing: CGFloat = 8
        let buttonHeight: CGFloat = 50      // New Tab button area
        let titleHeight: CGFloat = 24       // Title + spacing
        let itemPadding: CGFloat = 12       // 6 on each side

        // Calculate available width per item
        let totalHSpacing = spacing * CGFloat(cols - 1)
        let availableWidth = sidebarWidth - horizontalPadding - totalHSpacing
        let itemWidth = availableWidth / CGFloat(cols)

        // Calculate available height per item
        let totalVSpacing = spacing * CGFloat(rows - 1)
        let availableHeight = sidebarHeight - verticalPadding - buttonHeight - totalVSpacing
        let itemHeight = availableHeight / CGFloat(rows)

        // Preview height is item height minus title and padding
        let previewHeight = itemHeight - titleHeight - itemPadding
        let previewWidth = itemWidth - itemPadding

        return CGSize(width: previewWidth, height: previewHeight)
    }

    private var columns: [GridItem] {
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab grid (no scroll - items sized to fit)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tabItems) { item in
                    TabSidebarItemView(
                        item: item,
                        preview: previewManager.previews[item.surfaceID],
                        previewSize: itemSize,
                        isSelected: item.surfaceID == selectedSurfaceID,
                        onSelect: { onSelectTab(item.surfaceID) },
                        onClose: { onCloseTab(item.surfaceID) },
                        onNewTab: onNewTab
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)

            Spacer()

            Divider()

            // New tab button at the bottom
            Button(action: onNewTab) {
                HStack {
                    Image(systemName: "plus")
                    Text("New Tab")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: sidebarWidth)
        .background(
            ghostty.config.backgroundColor
                // Make sidebar 50% less transparent than terminal
                // If terminal opacity is 0.8, sidebar will be 0.9
                .opacity(ghostty.config.backgroundOpacity + (1 - ghostty.config.backgroundOpacity) * 0.5)
        )
    }
}

/// Individual tab item view with preview thumbnail, title, and hover actions.
struct TabSidebarItemView: View {
    let item: SidebarTabItem
    let preview: NSImage?
    let previewSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onNewTab: () -> Void

    @State private var isHovering = false
    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Preview thumbnail
            ZStack(alignment: .topTrailing) {
                previewImage
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipped()
                    .cornerRadius(6)

                // Tab number badge (top right) - only show for tabs 1-9
                if item.tabIndex < 9 {
                    Text("\(item.tabIndex + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                        .padding(4)
                        .opacity(isHovering ? 0 : 1) // Hide when close button is shown
                }

                // Close button shown on hover
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }

            // Tab title
            Text(displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isSelected ? .primary : .secondary)
        }
        .padding(6)
        .background(selectionBackground)
        .overlay(selectionBorder)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Close Tab", action: onClose)
            Divider()
            Button("New Tab", action: onNewTab)
        }
        .onAppear {
            if !isSelected {
                startPulsingAnimation()
            }
        }
        .onChange(of: isSelected) { selected in
            if !selected {
                startPulsingAnimation()
            } else {
                isPulsing = false
            }
        }
    }

    private func startPulsingAnimation() {
        withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }

    // MARK: - Private Views

    @ViewBuilder
    private var previewImage: some View {
        if let preview = preview {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    ProgressView()
                        .scaleEffect(0.6)
                )
        }
    }

    private var displayTitle: String {
        item.title.isEmpty ? "Terminal" : item.title
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                isSelected
                    ? Color.accentColor  // Selected: solid accent color
                    : Color.accentColor.opacity(isPulsing ? 0.6 : 0.2),  // Unselected: pulsing blue
                lineWidth: isSelected ? 2.5 : (isPulsing ? 1.5 : 1.0)
            )
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)
    }
}

// MARK: - Preview Provider

#if DEBUG
struct TabSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview requires mock data - this is just for development
        EmptyView()
    }
}
#endif
