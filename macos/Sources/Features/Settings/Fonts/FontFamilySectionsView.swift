//
//  FontFamilySectionsView.swift
//  Ghostty
//
//  Created by luca on 19.10.2025.
//

import SwiftUI

struct FontFamilySectionsView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    @EnvironmentObject var viewModel: FontSettingsViewModel

    var body: some View {
        ForEach($viewModel.fontSettings) { setting in
            Section {
                Picker(selection: setting.family) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) {
                        Text($0).font(.custom($0, size: 0))
                            .tag($0)
                    }
                } label: {
                    Text("Family Name")
                }

                CollapsedSettingsRow(help: "Explicitly specify this for selected styles") {
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

            } header: {
                HStack {
                    Text(setting.family.wrappedValue)

                    Spacer()
                    Menu("Delete") {
                        Button("Delete \(setting.family.wrappedValue) and all its code points") {
                            viewModel.removeFontFamily(setting.wrappedValue)
                        }
                    }
                    .menuStyle(.borderedButton)
                    .menuIndicator(.hidden)
                    .tint(.red)
                }
            }
        }
        .transition(.slide)
    }
}
