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

    enum FontCodePointBridge: GhosttyConfigValueConvertibleBridge {
        typealias Value = Ghostty.FontCodePointArray
        typealias UnderlyingValue = [Ghostty.RepeatableItem]

        static func convert(value: Ghostty.FontCodePointArray) -> [Ghostty.RepeatableItem] {
            value.values.map { range in
                Ghostty.RepeatableItem(key: range.range.representedString, value: range.fontFamily)
            }
        }

        static func convert(underlying: [Ghostty.RepeatableItem]) -> Ghostty.FontCodePointArray {
            var result = [Ghostty.FontCodePointRange]()
            for item in underlying {
                guard let range = ClosedRange<Unicode.Scalar>(hexRange: item.key) else {
                    continue
                }
                let newRange = Ghostty.FontCodePointRange.init(fontFamily: item.value, range: range)
                if !result.contains(newRange) {
                    result.append(newRange)
                }
            }
            return FontCodePointArray(values: result)
        }
    }
}


extension Ghostty.ConfigEntry where Bridge == Ghostty.FontCodePointBridge {
    init(_ key: String, reload: Bool = true, readDefaultValue: Bool = true) {
        self.init(key, reload: reload, readDefaultValue: readDefaultValue, bridge: Bridge.self)
    }
}
