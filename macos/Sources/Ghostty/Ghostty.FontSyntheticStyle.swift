//
//  Ghostty.FontSyntheticStyle.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import Foundation

extension Ghostty {
    struct FontSyntheticStyle: Hashable {
        init(bold: Bool = true, italic: Bool = true, boldItalic: Bool = true) {
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
        }

        var bold = true
        var italic = true
        var boldItalic = true
    }
}
