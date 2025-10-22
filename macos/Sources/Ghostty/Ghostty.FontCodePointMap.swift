//
//  Ghostty.FontCodePointMap.swift
//  Ghostty
//
//  Created by luca on 21.10.2025.
//

import Foundation

extension Ghostty {
    struct FontCodePointArray: Hashable {
        var values = [FontCodePointRange]()
    }

    struct FontCodePointRange: Hashable {
        typealias UnicodeRange = ClosedRange<Unicode.Scalar>
        let fontFamily: String
        let range: UnicodeRange
    }
}

extension Ghostty.FontCodePointArray: GhosttyConfigValueBridgeable {
    typealias UnderlyingValue = [Ghostty.RepeatableItem]

    init(underlyingValue: [Ghostty.RepeatableItem]) {
        var result = [Ghostty.FontCodePointRange]()
        for item in underlyingValue {
            guard let range = ClosedRange<Unicode.Scalar>(hexRange: item.key) else {
                continue
            }
            let newRange = Ghostty.FontCodePointRange.init(fontFamily: item.value, range: range)
            if !result.contains(newRange) {
                result.append(newRange)
            }
        }
        self.values = result
    }

    var underlyingValue: [Ghostty.RepeatableItem] {
        values.map { range in
            Ghostty.RepeatableItem(key: range.range.representedString, value: range.fontFamily)
        }
    }
}
