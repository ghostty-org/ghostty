//
//  FontsContentView.swift
//  Ghostty
//
//  Created by luca on 19.10.2025.
//

import SwiftUI

struct FontsContentView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        Form {
            FontSettingView()
            FontFamilySectionsView()
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    config.addNewFontFamily()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a font family")
            }
        }
    }
}
