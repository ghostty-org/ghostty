import GhosttyKit
import SwiftUI

struct ThemeContentView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        Form {
            // We separate this for now, since ghostty theme will affect appearance, if system is in light mode but ghostty is using dark theme, things start to become tricky...
            Section {
                Picker("Light", selection: $config.selectedLightTheme) {
                    ForEach(config.themes) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                Picker("Dark", selection: $config.selectedDarkTheme) {
                    ForEach(config.themes) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }
}
