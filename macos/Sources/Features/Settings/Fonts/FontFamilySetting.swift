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

    var family: String {
        didSet {
            variationSettings = Self.supportedVariations(for: family)
        }
    }

    init(family: String, codePoints: [UnicodeRange] = [], variations: [Ghostty.RepeatableItem] = []) {
        self.family = family
        self.codePoints = codePoints
        var supportedVariations = Self.supportedVariations(for: family)
        for variation in variations.map(\.value) {
            let parts = variation.split(separator: "=").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            if parts.count >= 2, let value = Double(parts[1]) {
                let id = parts[0]
                if let idx = supportedVariations.firstIndex(where: { $0.tag == id }), supportedVariations[idx].valueRange.contains(value) {
                    supportedVariations[idx].value = value
                }
            }
        }
        self.variationSettings = supportedVariations
    }

    var codePoints: [UnicodeRange] = []
    var isForBold = false
    var isForItalic = false
    var isForBoldItalic = false
    var variationSettings: [Variation]

    private static func supportedVariations(for family: String) -> [Variation] {
        guard
            let font = NSFont(name: family, size: 0),
            let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]]
        else {
            return []
        }
        return axes.compactMap(Variation.init(_:))
    }

    /// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6fvar.html#sfntVariationAxis
    struct Variation: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let tag: String
        let defaultValue: Double
        var value: Double
        let minimumValue: Double
        let maximumValue: Double
        var valueRange: ClosedRange<Double> {
            minimumValue ... maximumValue
        }

        var valueString: String {
            value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
        }

        var minimumValueString: String {
            minimumValue.formatted(.number.precision(.fractionLength(1)).grouping(.never))
        }

        var maximumValueString: String {
            maximumValue.formatted(.number.precision(.fractionLength(1)).grouping(.never))
        }
    }
}

extension FontFamilySetting.Variation {
    init?(_ dictionary: [CFString: Any]) {
        guard
            let name = dictionary[kCTFontVariationAxisNameKey] as? String,
            let identifierValue = dictionary[kCTFontVariationAxisIdentifierKey] as? UInt32,
            let identifier = identifierValue.convertToOpenTypeAxisTag(),
            let defaultValue = dictionary[kCTFontVariationAxisDefaultValueKey] as? Double,
            let minimumValue = dictionary[kCTFontVariationAxisMinimumValueKey] as? Double,
            let maximumValue = dictionary[kCTFontVariationAxisMaximumValueKey] as? Double
        else {
            return nil
        }

        self.name = name
        self.tag = identifier
        self.defaultValue = defaultValue
        self.value = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
    }
}

private extension UInt32 {
    // The identifiers are encoded as big-endian 4-byte (UInt32) values representing the ASCII codes of the tags.
    func convertToOpenTypeAxisTag() -> String? {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)
    }
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
