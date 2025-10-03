import Combine
import GhosttyKit
import SwiftUI

extension Ghostty {
    struct ThemePreviewSection: View {
        let surfaceView: SurfaceView
        let textAnchor: Character = "👻"
        @State private var isLoading: Bool = true
        @State private var previewHeight: CGFloat = 300
        @State private var bottomSpace: CGFloat = 0
        @State private var themes = [GhosttyTheme]()
        @State private var selectedTheme: GhosttyTheme?
        @Environment(\.ghosttyConfig) var config
        @Environment(\.colorScheme) var colorScheme
        var body: some View {
            VStack(alignment: .leading) {
                ScrollView {
                    GeometryReader { geo in
                        SurfaceRepresentable(view: surfaceView, size: .init(width: geo.size.width, height: geo.size.height + bottomSpace))
                            .disabled(true) // Disable interaction for preview
                            .cornerRadius(8)
                    }
                    .frame(height: previewHeight - bottomSpace, alignment: .top)
                }
                .backport.scrollEdgeEffectStyle(.soft, for: .vertical)
                .frame(height: 200)
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView("Loading theme preview...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude)
            .animation(.smooth, value: isLoading)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Select theme", selection: $selectedTheme) {
                        ForEach(themes) { theme in
                            Text(theme.name).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .onChange(of: selectedTheme) { newValue in
                // somehow we need to create a new config in order to take effect
//                let newConfig = Ghostty.Config(file: nil, finalize: false)
                if let newValue, newValue.name != config.theme[colorScheme] {
                    config.theme[colorScheme] = newValue.name
                    config.reload()
                }
            }
            .onChange(of: themes) { newValue in
                selectedTheme = newValue.first(where: { $0.name == config.theme[colorScheme] })
            }
            .onChange(of: colorScheme) { newValue in
                selectedTheme = themes.first(where: { $0.name == config.theme[newValue] })
            }
            .task {
                await createPreviewSurface()
            }
        }

        @MainActor
        private func updateSizes() {
            guard let surface = surfaceView.surface else {
                return
            }
            let size = ghostty_surface_size(surface)
            let rows = ghostty_surface_total_content_rows(surface)
            let scaleFactorY = Double(ghostty_surface_scale_factor_y(surface))
            let newHeight = Double(rows + 1) * Double(size.cell_height_px) / scaleFactorY // add one more row so that contents are not clipped
            guard newHeight != previewHeight else {
                return
            }
            previewHeight = newHeight
            bottomSpace = 2 * Double(size.cell_height_px) / scaleFactorY // one for cursor, one for additional space
        }

        @MainActor
        private func createPreviewSurface() async {
            // only loading when not executed our script
            isLoading = surfaceView.cachedScreenContents.get().trimmingCharacters(in: .whitespacesAndNewlines).last != textAnchor
            // Use the internal C API to run the theme preview
            await runThemePreview(surface: surfaceView)

            if isLoading {
                for await size in surfaceView.$cellSize.removeDuplicates().values {
                    if size != .zero {
                        // send once properly setup
                        surfaceView.surfaceModel?.sendText("clear && cat settings-theme-preview.txt\n\(textAnchor)")
                        // give it some time to get proper size
                        try? await Task.sleep(for: .seconds(0.5))
                        break
                    }
                }
            }

            // run indefinitely
            for await _ in surfaceView.$surfaceSize.values {
                isLoading = false
                updateSizes()
            }
        }

        @MainActor
        private func runThemePreview(surface: SurfaceView) async {
            var theme_list = ghostty_surface_theme_list_s()
            _ = ghostty_surface_get_themes(surface.surface, &theme_list)
            let buffer = UnsafeBufferPointer(start: theme_list.themes, count: theme_list.len)

            let themes = buffer.compactMap(GhosttyTheme.init(_:))
            self.themes = themes
        }
    }
}

struct GhosttyTheme: Identifiable, Hashable {
    let name: String
    let path: String
    let location: ghostty_surface_theme_location_e

    var id: String {
        "\(location)" + path
    }

    init?(_ theme: ghostty_surface_theme_s) {
        guard
            let path = String(bytes: UnsafeBufferPointer(start: theme.path, count: theme.path_len).map(UInt8.init(_:)), encoding: .utf8),
            let name = String(bytes: UnsafeBufferPointer(start: theme.theme, count: theme.theme_len).map(UInt8.init(_:)), encoding: .utf8)
        else {
            return nil
        }
        location = theme.location
        self.path = path
        self.name = name
    }
}
