//
//  Ghostty.ThemeOption.swift
//  Ghostty
//
//  Created by luca on 04.10.2025.
//

import GhosttyKit
import SwiftUI

extension Ghostty {
    struct ThemeOption: Identifiable, Hashable {
        let name: String
        let path: String
        let location: ghostty_surface_theme_location_e

        var id: String {
            "\(location)" + path
        }

        init?(_ theme: ghostty_surface_theme_s) {
            guard
                let path = String(bytes: UnsafeBufferPointer(start: theme.path, count: theme.path_len).map(UInt8.init(_:)), encoding: .utf8),
                let name = String(bytes: UnsafeBufferPointer(start: theme.theme, count: theme.theme_len).map(UInt8.init(_:)), encoding: .utf8)
            else {
                return nil
            }
            location = theme.location
            self.path = path
            self.name = name
        }
    }

    /// Swift type for `ghostty_config_theme_s`, only supports name for now
    struct Theme: GhosttyConfigValueConvertible {
        static let defaultValue = Self(light: "Ghostty Default Style Dark", dark: "Ghostty Default Style Dark")

        var light: String = ""
        var dark: String = ""

        subscript(scheme: ColorScheme) -> String {
            get {
                switch scheme {
                case .light:
                    return light
                case .dark:
                    return dark
                @unknown default:
                    assertionFailure("New cases for colorScheme should be added here")
                    return ""
                }
            }
            set {
                switch scheme {
                case .light:
                    light = newValue
                    if dark.isEmpty {
                        dark = newValue
                    }
                case .dark:
                    dark = newValue
                    if light.isEmpty {
                        dark = newValue
                    }
                @unknown default:
                    assertionFailure("New cases for colorScheme should be added here")
                }
            }
        }

        typealias GhosttyValue = ghostty_config_theme_s

        init(ghosttyValue: GhosttyValue?) {
            if let theme = ghosttyValue {
                light = String(bytes: UnsafeBufferPointer(start: theme.light, count: theme.light_len).map(UInt8.init(_:)), encoding: .utf8) ?? ""
                dark = String(bytes: UnsafeBufferPointer(start: theme.dark, count: theme.dark_len).map(UInt8.init(_:)), encoding: .utf8) ?? ""
            }
        }

        init(light: String = "", dark: String = "") {
            self.light = light
            self.dark = dark
        }

        var representedValue: [String] {
            guard light != dark, !light.isEmpty, !dark.isEmpty else {
                return [light.isEmpty ? dark : light]
            }
            return ["light:\(light),dark:\(dark)"]
        }
    }
}
