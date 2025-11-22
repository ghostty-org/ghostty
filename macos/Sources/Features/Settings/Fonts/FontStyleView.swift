//
//  FontStyleView.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct FontStyleView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        Section {
            Picker("Regular", selection: $config.regularFontStyle) {
                availableFontFacesView
            }
            Picker("Bold", selection: $config.boldFontStyle) {
                availableFontFacesView
            }
            Picker("Italic", selection: $config.italicFontStyle) {
                availableFontFacesView
            }
            Picker("Bold Italic", selection: $config.boldItalicFontStyle) {
                availableFontFacesView
            }
        }
    }

    @ViewBuilder
    var availableFontFacesView: some View {
        Text("---").tag(String?.none) // unset
        Text("Disable").tag("false") // disable
        Divider()
        ForEach(config.availableFontFaces, id: \.self) { fontFace in
            Text(fontFace)
                .tag(fontFace)
        }
    }
}
