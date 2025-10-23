import Combine
import GhosttyKit
import SwiftUI

extension Ghostty {
    /// Maps to a ghostty config file and the various operations on that. This is mainly used in Settings.
    class ConfigFile: ObservableObject, GhosttyConfigObject {
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

        let configFile: URL
        nonisolated static func defaultConfigFile() -> URL {
            try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ghostty-settings")
        }

        private let reloadSignal = PassthroughSubject<ghostty_app_t?, Never>()
        private var observers = Set<AnyCancellable>()

        var isExportingFontSettings = false

        @Published var saveError: Swift.Error? = nil
        @Published var themes = [Ghostty.ThemeOption]()
        @Published var selectedLightTheme: Ghostty.ThemeOption?
        @Published var selectedDarkTheme: Ghostty.ThemeOption?

        @Published var fontSettings: [FontFamilySetting] = [] {
            didSet {
                guard fontSettings != oldValue else {
                    return
                }
                reflectFontFamilySettingChanges()
            }
        }

        @Ghostty.ConfigEntry("theme") var theme: Ghostty.Theme
        @Ghostty.ConfigEntry("font-family") var fontFamilies: [RepeatableItem] {
            didSet {
                guard fontFamilies != oldValue else { return }
                updateFontFamilySettings()
            }
        }
        @Ghostty.ConfigEntry("font-family-bold", readDefaultValue: false)
        var boldFontFamilies: [RepeatableItem] {
            didSet {
                guard boldFontFamilies != oldValue else { return }
                updateFontFamilySettings()
            }
        }
        @Ghostty.ConfigEntry("font-family-italic", readDefaultValue: false)
        var italicFontFamilies: [RepeatableItem] {
            didSet {
                guard italicFontFamilies != oldValue else { return }
                updateFontFamilySettings()
            }
        }
        @Ghostty.ConfigEntry("font-family-bold-italic", readDefaultValue: false)
        var boldItalicFontFamilies: [RepeatableItem] {
            didSet {
                guard boldItalicFontFamilies != oldValue else { return }
                updateFontFamilySettings()
            }
        }

        // bridge from float
        @Ghostty.ConfigEntry(parsing: "font-size") var fontSize: Double
        @Ghostty.ConfigEntry("font-style") var regularFontStyle: String?
        @Ghostty.ConfigEntry("font-style-bold", readDefaultValue: false)
        var boldFontStyle: String?
        @Ghostty.ConfigEntry("font-style-italic", readDefaultValue: false)
        var italicFontStyle: String?
        @Ghostty.ConfigEntry("font-style-bold-italic", readDefaultValue: false)
        var boldItalicFontStyle: String?
        // bridge from [RepeatableItem]
        @Ghostty.ConfigEntry(parsing: "font-codepoint-map") var fontCodePointMap: FontCodePointArray {
            didSet {
                guard fontCodePointMap != oldValue else { return }
                updateFontFamilySettings()
            }
        }

        @Ghostty.ConfigEntry("font-synthetic-style") var fontSyntheticStyle: FontSyntheticStyle
        @Ghostty.ConfigEntry("font-feature") var fontFeatures: [RepeatableItem]
        @Ghostty.ConfigEntry("font-variation") var fontVariations: [RepeatableItem] {
            didSet {
                guard fontVariations != oldValue else { return }
                updateFontFamilySettings()
            }
        }

        @Ghostty.ConfigEntry("auto-update-channel") var updateChannel: AutoUpdateChannel

        deinit {
            self.config = nil
        }

        fileprivate init(config: ghostty_config_t?, configFile: URL) {
            self.config = config
            self.configFile = configFile
        }

        convenience init(configFile: URL? = nil, loadUsersConfig: Bool = false) {
            let configFile = configFile ?? Self.defaultConfigFile()
            guard
                let cfg = ghostty_config_new()
            else {
                self.init(config: nil, configFile: configFile)
                return
            }

            let initialFile: URL
            if !FileManager.default.fileExists(atPath: configFile.path), loadUsersConfig {
                initialFile = URL(filePath: Ghostty.AllocatedString(ghostty_config_open_path()).string)
            } else {
                initialFile = configFile
            }
            let path = initialFile.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                ghostty_config_load_file(cfg, path)
            }
            if !isRunningInXcode() {
                ghostty_config_load_cli_args(cfg)
            }
            ghostty_config_load_recursive_files(cfg)
            self.init(config: cfg, configFile: configFile)
            setupObservers()
            updateFontFamilySettings()
        }

        @concurrent func save() async {
            do {
                let content = await MainActor.run { export() }
                try content.write(to: configFile, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run {
                    saveError = error
                }
            }
        }

        func reload(for preferredApp: ghostty_app_t?) {
            reloadSignal.send(preferredApp)
        }

        private func setupObservers() {
            reloadSignal
                .throttle(for: 0.5, scheduler: DispatchQueue.global(), latest: true)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] app in
                    self?._reload(for: app)
                }
                .store(in: &observers)
        }

        private func _reload(for preferredApp: ghostty_app_t?) {
            guard let cfg = config else {
                return
            }

            // we only finalise config temporarily = hard reload
            let newCfg = ghostty_config_clone(cfg)
            if let app = preferredApp ?? (NSApp.delegate as? AppDelegate)?.ghostty.app {
                ghostty_config_finalize(newCfg)
                ghostty_app_update_config(app, newCfg)
                Task {
                    await save()
                }
            }
        }
    }
}

extension FontFamilySetting {
    static func availableFontFaces(for family: String) -> [String] {
        guard
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family)
        else {
            return [String]()
        }
        return members.compactMap { array in
            guard array.count >= 4 else { return nil }
            // face
            return array[1] as? String
        }
    }

    var availableFontFaces: [String] {
        Self.availableFontFaces(for: family)
    }
}
extension Ghostty.ConfigFile {
    var availableFontFaces: [String] {
        let allFaces = fontSettings.flatMap(\.availableFontFaces)
        return Set(allFaces).sorted()
    }

    func addNewFontFamily() {
        if let family = NSFontManager.shared.availableFontFamilies.first {
            fontSettings.insert(FontFamilySetting(family: family), at: 0)
        }
    }

    func removeFontFamily(_ setting: FontFamilySetting) {
        fontSettings.removeAll(where: { $0.id == setting.id })
    }

    // update from config
    func updateFontFamilySettings() {
        guard !isExportingFontSettings else { return }
        var fontSettings = fontSettings

        for family in fontFamilies {
            if !fontSettings.contains(where: { $0.family == family.value }) {
                fontSettings.append(FontFamilySetting(family: family.value))
            }
        }

        for codePoint in fontCodePointMap.values {
            let range = codePoint.range
            if let index = fontSettings.firstIndex(where: { $0.family == codePoint.fontFamily }) {
                if !fontSettings[index].codePoints.contains(range) {
                    fontSettings[index].codePoints.append(range)
                }
            } else {
                fontSettings.append(FontFamilySetting(family: codePoint.fontFamily, codePoints: [range]))
            }
        }

        for idx in fontSettings.indices {
            let supportedVariation = fontSettings[idx].variationSettings
            for variation in fontVariations {
                if let vIdx = supportedVariation.firstIndex(where: { $0.tag == variation.key }), let value = Double(variation.value) {
                    fontSettings[idx].variationSettings[vIdx].value = value
                }
            }
        }

        for setting in boldFontFamilies {
            if let idx = fontSettings.firstIndex(where: { $0.family == setting.value }) {
                fontSettings[idx].isForBold = true
            } else {
                var newValue = FontFamilySetting(family: setting.value)
                newValue.isForBold = true
                fontSettings.append(newValue)
            }
        }

        for setting in italicFontFamilies {
            if let idx = fontSettings.firstIndex(where: { $0.family == setting.value }) {
                fontSettings[idx].isForItalic = true
            } else {
                var newValue = FontFamilySetting(family: setting.value)
                newValue.isForItalic = true
                fontSettings.append(newValue)
            }
        }

        for setting in boldItalicFontFamilies {
            if let idx = fontSettings.firstIndex(where: { $0.family == setting.value }) {
                fontSettings[idx].isForBoldItalic = true
            } else {
                var newValue = FontFamilySetting(family: setting.value)
                newValue.isForBoldItalic = true
                fontSettings.append(newValue)
            }
        }

        self.fontSettings = fontSettings
    }

    /// write back to config
    func reflectFontFamilySettingChanges() {
        isExportingFontSettings = true
        fontFamilies = fontSettings.filter(\.isForFallback).map {
            Ghostty.RepeatableItem(key: _fontFamilies.key, value: $0.family)
        }
        fontCodePointMap.values = fontSettings.flatMap { setting in
            setting.codePoints.map { range in
                Ghostty.FontCodePointRange(fontFamily: setting.family, range: range)
            }
        }
        fontVariations = fontSettings.flatMap { setting in
            setting.variationSettings.map { variation in
                Ghostty.RepeatableItem(key: variation.tag, value: variation.valueString)
            }
        }

        boldFontFamilies = fontSettings.filter(\.isForBold).map {
            Ghostty.RepeatableItem(key: _boldFontFamilies.key, value: $0.family)
        }
        italicFontFamilies = fontSettings.filter(\.isForItalic).map {
            Ghostty.RepeatableItem(key: _italicFontFamilies.key, value: $0.family)
        }
        boldItalicFontFamilies = fontSettings.filter(\.isForBoldItalic).map {
            Ghostty.RepeatableItem(key: _boldItalicFontFamilies.key, value: $0.family)
        }
        isExportingFontSettings = false
    }
}
