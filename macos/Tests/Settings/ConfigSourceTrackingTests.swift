import Testing
import Foundation
@testable import Ghostty

struct ConfigSourceTrackingTests {
    /// Create a settings store backed by an isolated UserDefaults suite.
    private func makeStore() -> (UserDefaultsSettingsStore, UserDefaults) {
        let suite = "com.mitchellh.ghostty.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = UserDefaultsSettingsStore(defaults: defaults)
        return (store, defaults)
    }

    @Test func settingsStoreSourceWhenKeyPresent() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set("16", forKey: "font-size")

        // Without a real Ghostty config (nil), the method should still
        // detect the settings store source since that check comes first.
        let config = Ghostty.Config(config: nil)
        let source = config.resolvedSource(
            forKey: "font-size",
            settingsStore: store,
            defaultConfig: nil
        )
        #expect(source == .settingsStore)
    }

    @Test func defaultSourceWhenNoStoreAndNoConfig() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        // No value in store, no config to compare -> default
        let config = Ghostty.Config(config: nil)
        let source = config.resolvedSource(
            forKey: "font-size",
            settingsStore: store,
            defaultConfig: nil
        )
        #expect(source == .default)
    }

    @Test func defaultSourceWithNilStore() {
        let config = Ghostty.Config(config: nil)
        let source = config.resolvedSource(
            forKey: "font-size",
            settingsStore: nil,
            defaultConfig: nil
        )
        #expect(source == .default)
    }

    @Test func settingsStoreCheckTakesPrecedence() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        // Even with nil configs (so file vs default can't be determined),
        // a settings store value should return .settingsStore
        store.set("JetBrains Mono", forKey: "font-family")

        let config = Ghostty.Config(config: nil)
        let source = config.resolvedSource(
            forKey: "font-family",
            settingsStore: store,
            defaultConfig: nil
        )
        #expect(source == .settingsStore)
    }
}
