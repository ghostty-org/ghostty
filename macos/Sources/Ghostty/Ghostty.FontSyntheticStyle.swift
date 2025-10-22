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

extension Ghostty.FontSyntheticStyle: GhosttyConfigValueConvertible, GhosttyConfigValueBridgeable {
    typealias GhosttyValue = String

    init(ghosttyValue: String?) {
        guard let ghosttyValue else {
            self.init()
            return
        }
        let parts = ghosttyValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var style = Ghostty.FontSyntheticStyle()
        if parts.contains("no-bold") || parts.contains("false") {
            style.bold = false
        }
        if parts.contains("no-italic") || parts.contains("false") {
            style.italic = false
        }
        if parts.contains("no-bold-italic") || parts.contains("false") {
            style.boldItalic = false
        }
        self = style
    }

    var representedValue: String {
        if bold, italic, boldItalic {
            return "true"
        } else if !bold, !italic, !boldItalic {
            return "false"
        } else {
            var result: [String] = []
            if !bold {
                result.append("no-bold")
            }
            if !italic {
                result.append("no-italic")
            }
            if !boldItalic {
                result.append("no-bold-italic")
            }
            return result.joined(separator: ",")
        }
    }

    func representedValues(for key: String) -> [String] {
        [representedValue]
    }
}
