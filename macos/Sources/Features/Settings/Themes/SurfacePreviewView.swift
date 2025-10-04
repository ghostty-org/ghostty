import Combine
import GhosttyKit
import SwiftUI

struct SurfacePreviewView: View {
    @Environment(\.ghosttySurfaceView) var surfaceView
    let textAnchor: Character = "👻"
    @State private var isLoading: Bool = true
    @State private var previewHeight: CGFloat = 300
    @State private var bottomSpace: CGFloat = 0
    private let previewSectionHeight: CGFloat = 200
    @State private var themes = [Ghostty.ThemeOption]()
    @State private var selectedLightTheme: Ghostty.ThemeOption?
    @State private var selectedDarkTheme: Ghostty.ThemeOption?
    @Environment(\.ghosttyConfig) var config
    var body: some View {
        Form {
            // We separate this for now, since ghostty theme will affect appearance, if system is in light mode but ghostty is using dark theme, things start to become tricky...
            Section {
                Picker("Light", selection: $selectedLightTheme) {
                    ForEach(themes) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                Picker("Dark", selection: $selectedDarkTheme) {
                    ForEach(themes) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                ScrollView {
                    GeometryReader { geo in
                        if let surfaceView {
                            Ghostty.SurfaceRepresentable(view: surfaceView, size: .init(width: geo.size.width, height: geo.size.height + bottomSpace))
                                .disabled(true) // Disable interaction for preview
                                .cornerRadius(8)
                        }
                    }
                    .frame(height: previewHeight - bottomSpace, alignment: .top)
                }
                .frame(height: previewSectionHeight)
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView("Loading theme preview...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // topPadding + themeSelect + sectionPadding + preview + sectionPadding + bottomPadding
        .frame(height: 20 + (75 + 10 + 5 + previewSectionHeight + 5) + 20)
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: .greatestFiniteMagnitude)
        .animation(.smooth, value: isLoading)
        .task(id: selectedLightTheme) {
            await updateTheme(for: .light, selectedTheme: selectedLightTheme)
        }
        .task(id: selectedDarkTheme) {
            await updateTheme(for: .dark, selectedTheme: selectedDarkTheme)
        }
        .onChange(of: themes) { newValue in
            updateSelectedTheme(newThemes: newValue)
        }
        .task {
            await observeSurfaceView()
        }
    }

    @MainActor
    private func updateSizes() {
        guard let surface = surfaceView?.surface else {
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
    private func observeSurfaceView() async {
        guard let surfaceView else { return }
        // only loading when not executed our script
        isLoading = surfaceView.cachedScreenContents.get().trimmingCharacters(in: .whitespacesAndNewlines).last != textAnchor
        // Use the internal C API to run the theme preview
        await updateThemeList()

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
    private func updateThemeList() async {
        self.themes = (try? surfaceView?.surfaceModel?.themeOptions()) ?? []
    }

    private func updateTheme(for colorScheme: ColorScheme, selectedTheme: Ghostty.ThemeOption?) async {
        if config.theme[colorScheme].isEmpty, selectedTheme?.name == Ghostty.Theme.defaultValue[colorScheme] {
            // using default value, no need to reload
        } else if let newValue = selectedTheme, newValue.name != config.theme[colorScheme] {
            config.theme[colorScheme] = newValue.name
            config.reload()
            await config.save()
        }
    }

    private func updateSelectedTheme(newThemes: [Ghostty.ThemeOption]? = nil) {
        let themes = newThemes ?? self.themes
        let defaultTheme = Ghostty.Theme.defaultValue
        selectedLightTheme = themes.first(where: { $0.name == config.theme[.light] }) ?? themes.first(where: { $0.name == defaultTheme[.light] }) ?? themes.first
        selectedDarkTheme = themes.first(where: { $0.name == config.theme[.dark] }) ?? themes.first(where: { $0.name == defaultTheme[.dark] }) ?? themes.first
    }
}

