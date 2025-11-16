////
////  FontSettingsViewModel.swift
////  Ghostty
////
////  Created by luca on 20.10.2025.
////
//
//import AppKit
//
//class FontSettingsViewModel: ObservableObject {
//    @Published var fontSettings: [FontFamilySetting] = []
//
//    var availableFontFaces: [String] {
//        let allFaces = fontSettings.flatMap {
//            guard
//                let members = NSFontManager.shared.availableMembers(ofFontFamily: $0.family)
//            else {
//                return [String]()
//            }
//            return members.compactMap { array in
//                guard array.count >= 4 else { return nil }
//                // face
//                return array[1] as? String
//            }
//        }
//        return Set(allFaces).sorted()
//    }
//
//    init(config: Ghostty.ConfigFile) {
//        fontSettings = config.fontFamilies.map { cfg in
//            FontFamilySetting(family: cfg.value, variations: config.fontVariations)
//        }
//        for codePoint in config.fontCodePointMap {
//            guard let range = ClosedRange<Unicode.Scalar>(hexRange: codePoint.value) else {
//                continue
//            }
//            if let index = fontSettings.firstIndex(where: { $0.family == codePoint.key }) {
//                fontSettings[index].codePoints.append(range)
//            } else {
//                fontSettings.append(FontFamilySetting(family: codePoint.key, codePoints: [range], variations: config.fontVariations))
//            }
//        }
//    }
//
//    func addNewFontFamily() {
//        if let family = NSFontManager.shared.availableFontFamilies.first {
//            fontSettings.insert(FontFamilySetting(family: family), at: 0)
//        }
//    }
//
//    func removeFontFamily(_ setting: FontFamilySetting) {
//        fontSettings.removeAll(where: { $0.id == setting.id })
//    }
//}
