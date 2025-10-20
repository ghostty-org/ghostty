//
//  FontSettingView.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct FontSettingView: View {
    @EnvironmentObject var vm: FontSettingsViewModel
    @EnvironmentObject var config: Ghostty.ConfigFile
    @State private var isSyntheticStylePopoverOpen = false
    var body: some View {
        Section {
            CollapsedSettingsRow(help: """
                If synthetic styles are disabled, then the regular style will be used instead if the requested style is not available. If the font has the requested style, then the font will be used as-is since the style is not synthetic.
                """, attachmentAnchor: .point(.bottomTrailing)) {
                Text("Synthesize Styles")
            } popoverAnchor: {
                Text(config.fontSyntheticStyle.representedValue[0])
            } popoverContent: {
                Form {
                    Toggle("Synthesize Bold Sytle", isOn: $config.fontSyntheticStyle.bold)
                        .padding(.vertical, 3)
                    Toggle("Synthesize Italic Sytle", isOn: $config.fontSyntheticStyle.italic)
                        .padding(.vertical, 3)
                    Toggle("Synthesize Bold Italic Sytle", isOn: $config.fontSyntheticStyle.boldItalic)
                        .padding(.vertical, 3)
                }
                .formStyle(.grouped)
                .frame(width: 200)
            }

            CollapsedSettingsRow(help: "The named font style to use for each of the requested font styles") {
                Text("Style Overrides")
            } popoverAnchor: {
                Text("Set")
            } popoverContent: {
                Form {
                    FontStyleView()
                        .environmentObject(vm)
                }
                .formStyle(.grouped)
                .frame(width: 300)
            }

            SettingsRow(help: "Apply a font feature. To enable multiple font features you can repeat this multiple times or use a comma-separated list of feature settings.") {
                HStack {
                    Text("Features")
                    FontFeatureView()
                }
            }

            SettingsRow(help: config.fontSize.formatted(.number.precision(.fractionLength(1)))) {
                Slider(value: $config.fontSize, in: 8...80, step: 0.5, minimumValueLabel: Text("8"), maximumValueLabel: Text("80")) {
                    Text("Font Size")
                }
            }
        } header: {
            Text("Settings")
        }
    }
}
