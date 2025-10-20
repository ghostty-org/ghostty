import SwiftUI

struct SettingsView: View {
    @State var currentCategory: SettingsCategory = .themes
    @State var isPreviewVisible: Bool = false
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $currentCategory) { category in
                NavigationLink(value: category) {
                    Label(category.rawValue, systemImage: category.symbol)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ZStack {
                SurfacePreviewView()
                    .opacity(isPreviewVisible ? 1 : 0)
                    .disabled(!isPreviewVisible)
                Group {
                    switch currentCategory {
                    case .general:
                        GeneralContentView()
                    case .themes:
                        ThemeContentView()
                    case .fonts:
                        FontsContentView(config: config)
                    }
                }
                .navigationTitle(currentCategory.rawValue)
                .opacity(isPreviewVisible ? 0 : 1)
                .disabled(isPreviewVisible)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.smooth) {
                        isPreviewVisible.toggle()
                    }
                } label: {
                    Image(systemName: isPreviewVisible ? "eyes.inverse" : "eyes")
                }
                .help("Show Preview")
            }
            #if DEBUG
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Open Original Config") {
                    Ghostty.App.openConfig()
                }

                Button("Open Settings Config") {
                    NSWorkspace.shared.open(Ghostty.ConfigFile.configFile)
                }
            }
            #endif
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case themes = "Themes"
    case fonts = "Fonts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:
            return "gearshape"
        case .themes:
            return "paintbrush"
        case .fonts:
            return "character.magnify"
        }
    }
}
