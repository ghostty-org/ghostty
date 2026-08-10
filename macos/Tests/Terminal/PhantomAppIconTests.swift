import AppKit
@testable import Ghostty
import Testing

/// The app icon set, its families, and its names.
struct PhantomAppIconTests {
    /// Every icon must have artwork. A missing asset is a build mistake that
    /// would otherwise show up as an empty square in the picker.
    @Test @MainActor func everyIconHasArtwork() {
        for icon in PhantomAppIcon.allCases {
            #expect(icon.image() != nil, "\(icon.rawValue) has no asset")
        }
    }

    /// The raw value *is* the asset name — that is what makes adding an icon
    /// two steps instead of three.
    @Test func theRawValueIsTheAssetName() {
        for icon in PhantomAppIcon.allCases {
            #expect(icon.assetName == icon.rawValue)
        }
    }

    /// Families are read from the name, so a new tribute icon needs no extra
    /// wiring.
    @Test func familyComesFromTheName() {
        #expect(PhantomAppIcon.phantom.family == .phantom)
        #expect(PhantomAppIcon.pcbDark.family == .phantom)
        #expect(PhantomAppIcon.tribute.family == .ghosttyTribute)
        #expect(PhantomAppIcon.tributePCBLight.family == .ghosttyTribute)
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

    /// Titles drop the product prefix and the family suffix: inside a section
    /// both repeat on every row and carry no information.
    @Test func titlesDropWhatEveryRowRepeats() {
        #expect(PhantomAppIcon.phantom.title == "Default")
        #expect(PhantomAppIcon.tribute.title == "Default")
        #expect(PhantomAppIcon.pcbDark.title == "PCB Dark")
        #expect(PhantomAppIcon.tributePCBDark.title == "PCB Dark")
        #expect(PhantomAppIcon.bullsEye.title == "Bulls Eye")
    }

    /// Two icons must never present as the same thing in the same section.
    @Test func titlesAreUniqueWithinAFamily() {
        for family in PhantomAppIcon.Family.allCases {
            let titles = PhantomAppIcon.all(in: family).map(\.title)
            #expect(Set(titles).count == titles.count, "\(family.title) repeats a title")
        }
    }

    @Test func theDefaultIsAPhantomIcon() {
        #expect(PhantomAppIcon.default.family == .phantom)
        #expect(PhantomAppIcon.default == .phantom)
    }

    /// Persistence round-trips through the raw value, so a stored choice keeps
    /// working when cases are added or reordered.
    @Test func everyIconRoundTripsThroughItsRawValue() {
        for icon in PhantomAppIcon.allCases {
            #expect(PhantomAppIcon(rawValue: icon.rawValue) == icon)
        }
    }
}
