import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TabSidebarSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "TabSidebarSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaults() {
        let settings = TabSidebarSettings(defaults: makeDefaults())
        #expect(settings.isVisible == true)
        #expect(settings.width == TabSidebarLogic.defaultWidth)
    }

    @Test func setWidthPersistsOnlyWhenAsked() {
        let defaults = makeDefaults()
        let settings = TabSidebarSettings(defaults: defaults)

        settings.setWidth(300, persist: false)
        #expect(settings.width == 300)
        #expect(defaults.object(forKey: TabSidebarSettings.widthKey) == nil)

        settings.setWidth(320, persist: true)
        #expect(settings.width == 320)
        #expect(TabSidebarSettings(defaults: defaults).width == 320)
    }

    @Test func setWidthClamps() {
        let settings = TabSidebarSettings(defaults: makeDefaults())
        settings.setWidth(1, persist: false)
        #expect(settings.width == TabSidebarLogic.minWidth)
        settings.setWidth(10_000, persist: false)
        #expect(settings.width == TabSidebarLogic.maxWidth)
    }

    @Test func storedGarbageWidthIsClamped() {
        let defaults = makeDefaults()
        defaults.set(Double(5), forKey: TabSidebarSettings.widthKey)
        #expect(TabSidebarSettings(defaults: defaults).width == TabSidebarLogic.minWidth)
    }

    @Test func toggleVisiblePersists() {
        let defaults = makeDefaults()
        let settings = TabSidebarSettings(defaults: defaults)
        settings.toggleVisible()
        #expect(settings.isVisible == false)
        #expect(TabSidebarSettings(defaults: defaults).isVisible == false)
        settings.toggleVisible()
        #expect(TabSidebarSettings(defaults: defaults).isVisible == true)
    }
}
