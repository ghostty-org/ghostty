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

        @Ghostty.ConfigEntry("theme") var theme: Ghostty.Theme
        @Ghostty.ConfigEntry("font-family") var fontFamily: [RepeatableItem]

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
