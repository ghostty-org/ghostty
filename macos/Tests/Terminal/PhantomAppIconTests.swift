import AppKit
@testable import Ghostty
import Testing

/// The app icon set, its families, and its names.
struct PhantomAppIconTests {
    /// Every icon must have artwork in every style, at both appearances. A
    /// missing export is a build mistake that would otherwise show up as an
    /// empty square in the picker — and only for the one combination whose
    /// file was forgotten, which is exactly the kind of gap a spot check
    /// misses.
    @Test @MainActor func everyIconHasArtworkInEveryStyle() {
        for icon in PhantomAppIcon.allCases {
            for variant in PhantomAppIconVariant.allCases {
                for isDark in [false, true] {
                    #expect(
                        icon.image(variant: variant, isDark: isDark) != nil,
                        "\(icon.rawValue) has no \(variant.fileSuffix(isDark: isDark)) export"
                    )
                }
            }
        }
    }

    /// The style that is a material follows the system; the two that name an
    /// appearance override it. Getting this backwards would make "Dark" flip
    /// to light artwork whenever the system did.
    @Test func onlyTheMaterialStyleFollowsTheSystem() {
        #expect(!PhantomAppIconVariant.standard.followsSystemAppearance)
        #expect(!PhantomAppIconVariant.dark.followsSystemAppearance)
        #expect(PhantomAppIconVariant.clear.followsSystemAppearance)
    }

    /// Tinted is deliberately absent — it washed the ghost out. Asserted so
    /// that re-adding it is a decision rather than a silent side effect of
    /// dropping an export back into the folder.
    @Test func tintedIsNotOffered() {
        #expect(PhantomAppIconVariant(rawValue: "Tinted") == nil)
        #expect(PhantomAppIconVariant.allCases.count == 3)
    }

    /// A style that follows the system resolves to a different file per
    /// appearance; one that doesn't resolves to the same file either way.
    @Test func suffixesResolvePerAppearanceOnlyWhereThatMeansSomething() {
        for variant in PhantomAppIconVariant.allCases {
            let light = variant.fileSuffix(isDark: false)
            let dark = variant.fileSuffix(isDark: true)
            #expect(
                (light != dark) == variant.followsSystemAppearance,
                "\(variant.rawValue) resolves appearances inconsistently with what it claims"
            )
        }
    }

    /// Families are read from the name, so a new tribute icon needs no extra
    /// wiring.
    @Test func familyComesFromTheName() {
        #expect(PhantomAppIcon.purpleHaze.family == .phantom)
        #expect(PhantomAppIcon.circuits.family == .phantom)
        #expect(PhantomAppIcon.tributePurpleHaze.family == .ghosttyTribute)
        #expect(PhantomAppIcon.tributeCircuits.family == .ghosttyTribute)
    }

    /// The two sections hold the same number of icons, which is the parity
    /// asked for — a tribute for every Phantom icon.
    @Test func bothFamiliesHaveTheSameCount() {
        let phantom = PhantomAppIcon.all(in: .phantom)
        let tribute = PhantomAppIcon.all(in: .ghosttyTribute)

        #expect(phantom.count == tribute.count)
        #expect(!phantom.isEmpty)
    }

    /// And they line up name for name, so the sections read as a pair rather
    /// than as two unrelated lists.
    @Test func theFamiliesMirrorEachOther() {
        let phantom = PhantomAppIcon.all(in: .phantom).map(\.title).sorted()
        let tribute = PhantomAppIcon.all(in: .ghosttyTribute).map(\.title).sorted()
        #expect(phantom == tribute)
    }

    /// Titles drop the family prefix: inside a section it repeats on every
    /// row and carries no information.
    @Test func titlesDropWhatEveryRowRepeats() {
        #expect(PhantomAppIcon.purpleHaze.title == "Purple Haze")
        #expect(PhantomAppIcon.tributePurpleHaze.title == "Purple Haze")
        #expect(PhantomAppIcon.circuits.title == "Circuits")
        #expect(PhantomAppIcon.tributeCircuits.title == "Circuits")
        #expect(PhantomAppIcon.standard.title == "Default")
    }

    /// Two icons must never present as the same thing in the same section.
    @Test func titlesAreUniqueWithinAFamily() {
        for family in PhantomAppIcon.Family.allCases {
            let titles = PhantomAppIcon.all(in: family).map(\.title)
            #expect(Set(titles).count == titles.count, "\(family.title) repeats a title")
        }
    }

    /// The one actually compiled into the bundle — a stable fact, unlike
    /// `default`, which is dev/release-aware.
    @Test func theProductionDefaultIsTheStandardIcon() {
        #expect(PhantomAppIcon.productionDefault.family == .phantom)
        #expect(PhantomAppIcon.productionDefault == .standard)
    }

    /// A local build's fallback is the Development icon, not what a release
    /// would wear.
    ///
    /// The test host's own bundle lives under DerivedData, which
    /// `DevelopmentBuild.isActive` reads the same way it reads a `zig-out`
    /// copy — so this exercises the exact branch a dev build takes, not a
    /// stand-in for it.
    @Test func theFallbackIsTheDevelopmentIconUnderADevBuild() {
        #expect(DevelopmentBuild.isActive)
        #expect(PhantomAppIcon.default == .development)
    }

    /// Persistence round-trips through the raw value, so a stored choice keeps
    /// working when cases are added or reordered.
    @Test func everyIconRoundTripsThroughItsRawValue() {
        for icon in PhantomAppIcon.allCases {
            #expect(PhantomAppIcon(rawValue: icon.rawValue) == icon)
        }
    }
}

/// The variant store, which is a second, independent choice alongside the
/// icon.
///
/// Serialized for the same reason as the icon store's own tests: these save
/// and restore the real `UserDefaults` entry a locally-running Phantom reads,
/// and interleaved save/restore pairs can put back the wrong snapshot.
@Suite(.serialized)
@MainActor
struct PhantomAppIconVariantStoreTests {
    private func withCleanDefaults(_ body: () -> Void) {
        let key = PhantomAppIconVariantStore.defaultsKey
        let stored = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func withNothingPersistedTheStyleIsTheDefault() {
        withCleanDefaults {
            #expect(PhantomAppIconVariantStore.current == .standard)
        }
    }

    @Test func aPersistedStyleIsReadBackAsIs() {
        withCleanDefaults {
            PhantomAppIconVariantStore.set(.clear)
            #expect(PhantomAppIconVariantStore.current == .clear)
        }
    }

    /// A name left behind by a renamed or removed case reads as "nothing
    /// chosen" rather than crashing or sticking.
    @Test func anUnknownPersistedStyleFallsBack() {
        withCleanDefaults {
            UserDefaults.standard.set("Holographic", forKey: PhantomAppIconVariantStore.defaultsKey)
            #expect(PhantomAppIconVariantStore.current == .standard)
        }
    }

    /// The icon and the style are separate keys, so changing one must not
    /// disturb the other — the whole reason they aren't a single value.
    @Test func theStyleAndTheIconAreIndependent() {
        withCleanDefaults {
            let storedIcon = UserDefaults.standard.string(forKey: PhantomAppIconStore.defaultsKey)
            defer {
                if let storedIcon {
                    UserDefaults.standard.set(storedIcon, forKey: PhantomAppIconStore.defaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: PhantomAppIconStore.defaultsKey)
                }
            }

            UserDefaults.standard.set(PhantomAppIcon.nebula.rawValue, forKey: PhantomAppIconStore.defaultsKey)
            PhantomAppIconVariantStore.set(.clear)

            #expect(PhantomAppIconStore.current == .nebula)
            #expect(PhantomAppIconVariantStore.current == .clear)
        }
    }
}
