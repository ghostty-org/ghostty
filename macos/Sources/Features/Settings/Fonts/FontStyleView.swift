//
//  FontStyleView.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct FontStyleView: View {
    @EnvironmentObject var viewModel: FontSettingsViewModel
    var body: some View {
        Section {
            Picker("Regular", selection: $viewModel.selectedRegularStyle) {
                availableFontFacesView
            }
            Picker("Bold", selection: $viewModel.selectedBoldStyle) {
                availableFontFacesView
            }
            Picker("Italic", selection: $viewModel.selectedItalicStyle) {
                availableFontFacesView
            }
            Picker("Bold Italic", selection: $viewModel.selectedBoldItalicStyle) {
                availableFontFacesView
            }
        }
    }

    @ViewBuilder
    var availableFontFacesView: some View {
        Text("---").tag(String?.none) // unset
        Text("Disable").tag("false") // disable
        Divider()
        ForEach(viewModel.availableFontFaces, id: \.self) { fontFace in
            Text(fontFace)
                .tag(fontFace)
        }
    }
}
