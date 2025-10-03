import SwiftUI

struct SettingsView: View {
    @State var currentCategory: SettingsCategory = .general
    let surfaceView: Ghostty.SurfaceView
    @State var presentedCategories: [SettingsCategory] = [.general]
    @State var config: Ghostty.Config?
    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $currentCategory) { category in
                NavigationLink(value: category) {
                    Label(category.rawValue, systemImage: category.symbol)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            switch currentCategory {
            case .general:
                ScrollView {
                    Text(currentCategory.rawValue)
                }.navigationTitle(currentCategory.rawValue)
            case .themes:
                ThemePreviewContentView(surfaceView: surfaceView)
                    .navigationTitle(currentCategory.rawValue)
                    .environment(\.ghosttyConfig, config)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .task {
            let testFile = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("test-ghostty-config")
            if !FileManager.default.fileExists(atPath: testFile.path(percentEncoded: false)) {
                try! "".write(to: testFile, atomically: true, encoding: .utf8)
            }
            config = .init(file: testFile, finalize: false)
        }
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
