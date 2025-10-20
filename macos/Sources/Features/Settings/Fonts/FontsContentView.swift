//
//  FontsContentView.swift
//  Ghostty
//
//  Created by luca on 19.10.2025.
//

import SwiftUI

struct FontsContentView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    @StateObject var viewModel: FontSettingsViewModel
    init(config: Ghostty.ConfigFile) {
        _viewModel = .init(wrappedValue: FontSettingsViewModel(config: config))
    }
    var body: some View {
        Form {
            FontSettingView()
            FontFamilySectionsView()
        }
        .animation(.bouncy, value: viewModel.fontSettings)
        .formStyle(.grouped)
        .environmentObject(viewModel)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.addNewFontFamily()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a font family")
            }
        }
    }
}
