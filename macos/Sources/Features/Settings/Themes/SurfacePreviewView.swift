import Combine
import GhosttyKit
import SwiftUI

struct SurfacePreviewView: View {
    @Environment(\.ghosttySurfaceView) var surfaceView
    let textAnchor: Character = "👻"
    @State private var isLoading: Bool = true
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        GeometryReader { geo in
            if let surfaceView {
                Ghostty.SurfaceRepresentable(view: surfaceView, size: geo.size)
            }
        }
        .opacity(isLoading ? 0 : 1)
        .overlay {
            if isLoading {
                ProgressView("Loading theme preview...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude)
        .animation(.smooth, value: isLoading)
        .task(id: config.selectedLightTheme) {
            await updateTheme(for: .light, selectedTheme: config.selectedLightTheme)
        }
        .task(id: config.selectedDarkTheme) {
            await updateTheme(for: .dark, selectedTheme: config.selectedDarkTheme)
        }
        .onChange(of: config.themes) { newValue in
            updateSelectedTheme(newThemes: newValue)
        }
        .task {
            await observeSurfaceView()
        }
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
        }
    }

    @MainActor
    private func updateThemeList() async {
        config.themes = (try? surfaceView?.surfaceModel?.themeOptions()) ?? []
    }

    private func updateTheme(for colorScheme: ColorScheme, selectedTheme: Ghostty.ThemeOption?) async {
        if config.theme[colorScheme].isEmpty, selectedTheme?.name == Ghostty.Theme.defaultValue[colorScheme] {
            // using default value, no need to reload
        } else if let newValue = selectedTheme/*, newValue.name != config.theme[colorScheme]*/ {
            config.theme[colorScheme] = newValue.name
        }
    }

    private func updateSelectedTheme(newThemes: [Ghostty.ThemeOption]? = nil) {
        let themes = newThemes ?? config.themes
        let defaultTheme = Ghostty.Theme.defaultValue
        config.selectedLightTheme = themes.first(where: { $0.name == config.theme[.light] }) ?? themes.first(where: { $0.name == defaultTheme[.light] }) ?? themes.first
        config.selectedDarkTheme = themes.first(where: { $0.name == config.theme[.dark] }) ?? themes.first(where: { $0.name == defaultTheme[.dark] }) ?? themes.first
    }
}

