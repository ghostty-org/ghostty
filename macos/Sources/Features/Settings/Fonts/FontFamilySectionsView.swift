//
//  FontFamilySectionsView.swift
//  Ghostty
//
//  Created by luca on 19.10.2025.
//

import SwiftUI

struct FontFamilySectionsView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile

    var body: some View {
        let _ = Self._printChanges()
        ForEach($config.fontSettings) { setting in
            Section {
                FontFamilyPickerView(setting: setting)

                FontStyleOverrideView(setting: setting)

                SettingsRow {
                    HStack {
                        Text("Code Points")
                        CodePointsView(codeRanges: setting.codePoints)
                    }
                }
                .tip("You can specify multiple ranges for this font separated by commas, such as U+ABCD-U+DEFG,U+1234-U+5678.\nOr just leave it empty")

                FontVariationView(setting: setting)
            } header: {
                HStack {
                    Text(setting.family.wrappedValue)

                    Spacer()
                    Menu {
                        Button("Delete \(setting.family.wrappedValue) and all its code points") {
                            config.removeFontFamily(setting.wrappedValue)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
        .transition(.slide)
    }
}

private struct FontFamilyPickerView: View {
    @Binding var setting: FontFamilySetting
    var body: some View {
        Picker(selection: $setting.family) {
            ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { fam in
                Text(fam)
                    .font(.custom(fam, size: 0))
            }
        } label: {
            Text("Family Name")
        }
    }
}

private struct FontVariationView: View {
    @Binding var setting: FontFamilySetting

    var body: some View {
        if !setting.variationSettings.isEmpty {
            PopoverSettingsRow {
                Text("Variations")
            } popoverAnchor: {
                Text("Set")
            } popoverContent: {
                Form {
                    ForEach($setting.variationSettings) { variation in
                        let wrapped = variation.wrappedValue
                        // using step with Liquid glass will add dots under the slider
                        // which is really expensive to render
                        // so we let the system decide the step
                        // without explicitly setting them
                        SettingsRow(help: wrapped.valueString) {
                            Slider(
                                value: variation.value,
                                in: wrapped.valueRange,
                                minimumValueLabel: Text(wrapped.minimumValueString).frame(width: 50, alignment: .trailing),
                                maximumValueLabel: Text(wrapped.maximumValueString).frame(width: 50, alignment: .leading)
                            ) {
                                Text(wrapped.name)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 500)
            }
        }
    }
}


private struct FontStyleOverrideView: View {
    @Binding var setting: FontFamilySetting
    @State private var supportedFaces: [String] = []
    var body: some View {
        PopoverSettingsRow(help: "Explicitly specify this for selected styles") {
            Text("Styles")
        } popoverAnchor: {
            Text("Select")
        } popoverContent: {
            Form {
                SettingsRow(help: isBoldEnabled ? nil : "Not supported") {
                    Toggle("Bold", isOn: $setting.isForBold)
                        .disabled(!isBoldEnabled)
                }
                SettingsRow(help: isItalicEnabled ? nil : "Not supported") {
                    Toggle("Italic", isOn: $setting.isForItalic)
                        .disabled(!isItalicEnabled)
                }
                SettingsRow(help: isBoldItalicEnabled ? nil : "Not supported") {
                    Toggle("Bold Italic", isOn: $setting.isForBoldItalic)
                        .disabled(!isBoldItalicEnabled)
                }
            }
            .formStyle(.grouped)
            .frame(width: 200)
        }
        .task {
            supportedFaces = setting.availableFontFaces
        }
        .onChange(of: setting.family) { newFamily in
            supportedFaces = FontFamilySetting.availableFontFaces(for: newFamily)
        }
    }

    var isBoldEnabled: Bool {
        supportedFaces.contains(where: { $0.lowercased().contains("bold") })
    }

    var isItalicEnabled: Bool {
        supportedFaces.contains(where: { $0.lowercased().contains("italic") })
    }

    var isBoldItalicEnabled: Bool {
        supportedFaces.contains(where: { $0.lowercased().contains("bold italic") })
    }
}
