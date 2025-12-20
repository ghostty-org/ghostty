@testable import Ghostty
import Testing

struct CustomIconTests {
    @Test func migration() {
        #expect(Ghostty.CustomAppIcon.blueprint == Ghostty.CustomAppIcon(string: "blueprint"))

        #expect(nil == Ghostty.CustomAppIcon(string: "~/downloads/some/file.png"))

        #expect(nil == Ghostty.CustomAppIcon(string: "#B0260C"))

        #expect(nil == Ghostty.CustomAppIcon(string: "plastic"))

        #expect(Ghostty.CustomAppIcon.customStyle(ghostColorHex: "#B0260C", screenColorHexes: [], iconFrame: .plastic) == Ghostty.CustomAppIcon(string: "#B0260C_plastic"))

        #expect(Ghostty.CustomAppIcon.customStyle(ghostColorHex: "#B0260C", screenColorHexes: ["#4F2C27"], iconFrame: .plastic) == Ghostty.CustomAppIcon(string: "#B0260C_#4F2C27_plastic"))

        #expect(Ghostty.CustomAppIcon.customStyle(ghostColorHex: "#B0260C", screenColorHexes: ["#4F2C27", "#B0260C"], iconFrame: .plastic) == Ghostty.CustomAppIcon(string: "#B0260C_#4F2C27_#B0260C_plastic"))
    }
}
