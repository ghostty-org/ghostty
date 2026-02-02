import Testing
import Foundation
@testable import Ghostty

struct UserDefaultsSettingsStoreTests {
    /// Create a store backed by an isolated UserDefaults suite.
    private func makeStore() -> (UserDefaultsSettingsStore, UserDefaults) {
        let suite = "com.mitchellh.ghostty.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = UserDefaultsSettingsStore(defaults: defaults)
        return (store, defaults)
    }

    @Test func setAndGetSingleValue() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set("14", forKey: "font-size")
        #expect(store.string(forKey: "font-size") == "14")
        #expect(store.strings(forKey: "font-size") == ["14"])
    }

    @Test func setAndGetMultipleValues() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set(["JetBrains Mono", "Noto Color Emoji"], forKey: "font-family")
        #expect(store.strings(forKey: "font-family") == ["JetBrains Mono", "Noto Color Emoji"])
        // string(forKey:) returns the first value
        #expect(store.string(forKey: "font-family") == "JetBrains Mono")
    }

    @Test func nilForUnsetKey() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        #expect(store.string(forKey: "nonexistent") == nil)
        #expect(store.strings(forKey: "nonexistent") == nil)
    }

    @Test func nilForEmptyArray() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set([], forKey: "font-family")
        #expect(store.strings(forKey: "font-family") == nil)
    }

    @Test func allKeysReturnsOnlyPrefixedKeys() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        // Set an unrelated key directly on the same defaults suite
        defaults.set("unrelated", forKey: "SomeOtherKey")
        store.set("14", forKey: "font-size")
        store.set("true", forKey: "font-thicken")

        #expect(store.allKeys.count == 2)
        #expect(store.allKeys.contains("font-size"))
        #expect(store.allKeys.contains("font-thicken"))
    }

    @Test func removeValue() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set("14", forKey: "font-size")
        store.removeValue(forKey: "font-size")
        #expect(store.string(forKey: "font-size") == nil)
    }

    @Test func resetAllClearsOnlyPrefixedKeys() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        // Set a non-prefixed key that should survive resetAll
        defaults.set("keep-this", forKey: "SecureInput")
        store.set("14", forKey: "font-size")
        store.set("true", forKey: "font-thicken")

        store.resetAll()

        #expect(store.allKeys.isEmpty)
        #expect(defaults.string(forKey: "SecureInput") == "keep-this")
    }

    @Test func overwriteExistingValue() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set("14", forKey: "font-size")
        store.set("16", forKey: "font-size")
        #expect(store.string(forKey: "font-size") == "16")
    }

    @Test func keyPrefixIsApplied() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        store.set("14", forKey: "font-size")

        // The underlying UserDefaults key should be prefixed
        #expect(defaults.array(forKey: "ghostty.config.font-size") as? [String] == ["14"])
        // And the unprefixed key should not exist
        #expect(defaults.object(forKey: "font-size") == nil)
    }

    @Test func legacySingleStringMigration() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

        // Simulate a plain string stored directly (e.g. from `defaults write`)
        defaults.set("14", forKey: "ghostty.config.font-size")

        // strings(forKey:) should still work, wrapping it in an array
        #expect(store.strings(forKey: "font-size") == ["14"])
        #expect(store.string(forKey: "font-size") == "14")
    }
}
