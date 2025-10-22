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
                Picker(selection: setting.family) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) {
                        Text($0).font(.custom($0, size: 0))
                            .tag($0)
                    }
                } label: {
                    Text("Family Name")
                }

                PopoverSettingsRow(help: "Explicitly specify this for selected styles") {
                    Text("Styles")
                } popoverAnchor: {
                    Text("Select")
                } popoverContent: {
                    Form {
                        Toggle("Bold", isOn: setting.isForBold)
                        Toggle("Italic", isOn: setting.isForItalic)
                        Toggle("Bold Italic", isOn: setting.isForBoldItalic)
                    }
                    .formStyle(.grouped)
                    .frame(width: 200)
                }

                SettingsRow {
                    HStack {
                        Text("Code Points")
                        CodePointsView(codeRanges: setting.codePoints)
                    }
                }
                .tip("You can specify multiple ranges for this font separated by commas, such as U+ABCD-U+DEFG,U+1234-U+5678.\nOr just leave it empty")

                if !setting.variationSettings.isEmpty {
                    PopoverSettingsRow {
                        Text("Variations")
                    } popoverAnchor: {
                        Text("Set")
                    } popoverContent: {
                        Form {
                            ForEach(setting.variationSettings) { variation in
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
