//
//  FontPicker.swift
//  Ghostty
//
//  Created by luca on 04.10.2025.
//

import SwiftUI

struct FontPicker: View {
    @State var font: NSFont = .systemFont(ofSize: 10)
    @State private var fontPickerDelegate: FontPickerDelegate?
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        HStack {
            Text("Font")
            Spacer()
            Text(config.fontFamily.map(\.value).joined(separator: ", "))
            Button(action: {
                if NSFontPanel.shared.isVisible {
                    NSFontPanel.shared.orderOut(nil)
                    return
                }

                fontPickerDelegate = FontPickerDelegate(self)
                NSFontManager.shared.target = fontPickerDelegate
                NSFontManager.shared.setSelectedFont(font, isMultiple: false)
                NSFontPanel.shared.makeKeyAndOrderFront(nil)
            }) {
                Image(systemName: "macwindow")
            }
        }
        .task {
            if let firstFont = config.fontFamily.first, let queriedFont = NSFontManager.shared.font(withFamily: firstFont.value, traits: [], weight: 100, size: 10) {
                self.font = queriedFont
            }
        }
    }

    func fontSelected() {
        font = NSFontPanel.shared.convert(font)
        guard let familyName = font.familyName else {
            return
        }
        if config.fontFamily.isEmpty {
            config.fontFamily = [.init(key: "font-family", value: familyName)]
        } else {
            config.fontFamily[0].value = familyName
        }
    }
}

class FontPickerDelegate {
    var parent: FontPicker

    init(_ parent: FontPicker) {
        self.parent = parent
    }

    @objc func changeFont(_ sender: Any) {
        parent.fontSelected()
    }
}
