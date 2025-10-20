import GhosttyKit
import SwiftUI

extension Ghostty {
    /// Maps to a ghostty config file and the various operations on that. This is mainly used in Settings.
    class ConfigFile: ObservableObject, GhosttyConfigObject {
        static let empty = Ghostty.ConfigFile(config: nil)
        // The underlying C pointer to the Ghostty config structure. This
        // should never be accessed directly. Any operations on this should
        // be called from the functions on this or another class.
        private(set) var config: ghostty_config_t? {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        static var configFile: URL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ghostty-settings")

        @Published var saveError: Swift.Error? = nil
        @Published var themes = [Ghostty.ThemeOption]()
        @Published var selectedLightTheme: Ghostty.ThemeOption?
        @Published var selectedDarkTheme: Ghostty.ThemeOption?

        @Ghostty.ConfigEntry("theme") var theme: Ghostty.Theme
        @Ghostty.ConfigEntry("font-family") var fontFamily: [RepeatableItem]
        @Ghostty.ConfigEntry("font-size", from: Float.self) var fontSize: Double
        @Ghostty.ConfigEntry("font-style") var fontStyle: String?
        @Ghostty.ConfigEntry("font-style-bold") var fontStyleBold: String?
        @Ghostty.ConfigEntry("font-style-italic") var fontStyleItalic: String?
        @Ghostty.ConfigEntry("font-style-bold-italic") var fontStyleBoldItalic: String?
        @Ghostty.ConfigEntry("font-codepoint-map") var fontCodePointMap: [RepeatableItem]
        @Ghostty.ConfigEntry("auto-update-channel") var updateChannel: AutoUpdateChannel
        @Ghostty.ConfigEntry("font-synthetic-style") var fontSyntheticStyle: FontSyntheticStyle
        @Ghostty.ConfigEntry("font-feature") var fontFeatures: [RepeatableItem]

        deinit {
            self.config = nil
        }

        fileprivate init(config: ghostty_config_t?) {
            self.config = config
        }

        convenience init() {
            guard
                let cfg = ghostty_config_new()
            else {
                self.init(config: nil)
                return
            }

            let initialFile: URL
            if !FileManager.default.fileExists(atPath: Self.configFile.path(percentEncoded: false)) {
                initialFile = URL(filePath: Ghostty.AllocatedString(ghostty_config_open_path()).string)
            } else {
                initialFile = Self.configFile
            }
            let path = initialFile.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                ghostty_config_load_file(cfg, path)
            }
            if !isRunningInXcode() {
                ghostty_config_load_cli_args(cfg)
            }
            ghostty_config_load_recursive_files(cfg)
            self.init(config: cfg)
        }

        @concurrent func save() async {
            do {
                let content = await MainActor.run { export() }
                try content.write(to: Self.configFile, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run {
                    saveError = error
                }
            }
        }
    }
}

// MARK: - Mutating ghostty_config_t
