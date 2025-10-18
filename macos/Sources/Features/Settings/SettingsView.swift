import SwiftUI

struct SettingsView: View {
    @State var currentCategory: SettingsCategory = .general
    @State var presentedCategories: [SettingsCategory] = [.general]
    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $currentCategory) { category in
                NavigationLink(value: category) {
                    Label(category.rawValue, systemImage: category.symbol)
                }
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar {
                #if DEBUG
                Button("Open Original Config") {
                    Ghostty.App.openConfig()
                }

                Button("Open Settings Config") {
                    NSWorkspace.shared.open(Ghostty.ConfigFile.configFile)
                }
                #endif
            }
        } detail: {
            switch currentCategory {
            case .general:
                GeneralContentView()
                    .navigationTitle(currentCategory.rawValue)
            case .themes:
                ThemeContentView()
                    .navigationTitle(currentCategory.rawValue)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case themes = "Themes"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:
            return "gearshape"
        case .themes:
            return "paintbrush"
        }
    }
}
