//
//  FontFamilySetting.swift
//  Ghostty
//
//  Created by luca on 04.10.2025.
//

import SwiftUI

struct FontFamilySetting: Identifiable, Hashable {
    typealias UnicodeRange = ClosedRange<Unicode.Scalar>
    let id = UUID()

    var family: String
    var codePoints: [UnicodeRange] = []
    var isForBold = false
    var isForItalic = false
    var isForBoldItalic = false
}

extension Unicode.Scalar {
    init?(hexValue: String) {
        let hex = hexValue.replacingOccurrences(of: "U+", with: "")
            .replacingOccurrences(of: "u+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt32(hex, radix: 16) else { return nil }
        self.init(value)
    }

    var hexValue: String {
        String(format: "U+%04X", value)
    }
}

extension ClosedRange where Bound == Unicode.Scalar {
    init?(hexRange: String) {
        let parts = hexRange.split(separator: "-")
        guard
            parts.count == 2,
            let lower = Unicode.Scalar(hexValue: String(parts[0])),
            let upper = Unicode.Scalar(hexValue: String(parts[1]))
        else {
            return nil
        }
        self = lower ... upper
    }

    var description: String {
        [lowerBound.description, upperBound.description].joined(separator: " - ")
    }

    var representedString: String {
        [lowerBound.hexValue, upperBound.hexValue].joined(separator: "-")
    }
}
