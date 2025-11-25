//
//  FontFeatureView.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct FontFeatureView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    @State var features = ""
    var body: some View {
        TextField("", text: $features)
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .onSubmit(updateFeatures)
            .focusable()
            .task {
                features = config.fontFeatures.map(\.value).joined(separator: ",")
            }
    }

    func updateFeatures() {
        let parts = features.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        config.fontFeatures = parts.filter({ !$0.isEmpty }).map {
            Ghostty.RepeatableItem(key: "font-feature", value: $0)
        }
    }
}
