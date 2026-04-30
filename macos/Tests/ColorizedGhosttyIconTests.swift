import AppKit
import Foundation
import Testing
@testable import Ghostty

struct ColorizedGhosttyIconTests {
    private func makeIcon(
        screenColors: [NSColor] = [
            NSColor(hex: "#112233")!,
            NSColor(hex: "#AABBCC")!,
        ],
        ghostColor: NSColor = NSColor(hex: "#445566")!,
        frame: Ghostty.MacOSIconFrame = .aluminum
    ) -> ColorizedGhosttyIcon {
        .init(screenColors: screenColors, ghostColor: ghostColor, frame: frame)
    }

    // MARK: - Codable

    @Test func codableRoundTripPreservesIcon() throws {
        let icon = makeIcon(frame: .chrome)
        let data = try JSONEncoder().encode(icon)
        let decoded = try JSONDecoder().decode(ColorizedGhosttyIcon.self, from: data)

        #expect(decoded == icon)
        #expect(decoded.screenColors.compactMap(\.hexString) == ["#112233", "#AABBCC"])
        #expect(decoded.ghostColor.hexString == "#445566")
        #expect(decoded.frame == .chrome)
    }

    @Test func encodingWritesVersionAndHexColors() throws {
        let icon = makeIcon(frame: .plastic)
        let data = try JSONEncoder().encode(icon)

        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["version"] as? Int == 1)
        #expect(payload["screenColors"] as? [String] == ["#112233", "#AABBCC"])
        #expect(payload["ghostColor"] as? String == "#445566")
        #expect(payload["frame"] as? String == "plastic")
    }

    @Test func decodesLegacyV0PayloadWithoutVersion() throws {
        let data = Data("""
        {
            "screenColors": ["#112233", "#AABBCC"],
            "ghostColor": "#445566",
            "frame": "beige"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ColorizedGhosttyIcon.self, from: data)
        #expect(decoded.screenColors.compactMap(\.hexString) == ["#112233", "#AABBCC"])
        #expect(decoded.ghostColor.hexString == "#445566")
        #expect(decoded.frame == .beige)
    }

    @Test func decodingUnsupportedVersionThrowsDataCorrupted() {
        let data = Data("""
        {
            "version": 99,
            "screenColors": ["#112233", "#AABBCC"],
            "ghostColor": "#445566",
            "frame": "chrome"
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(ColorizedGhosttyIcon.self, from: data)
            Issue.record("Expected decode to fail for unsupported version")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("Unsupported ColorizedGhosttyIcon version"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got: \(error)")
        }
    }

    @Test func decodingInvalidGhostColorThrows() {
        let data = Data("""
        {
            "version": 1,
            "screenColors": ["#112233", "#AABBCC"],
            "ghostColor": "not-a-color",
            "frame": "chrome"
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(ColorizedGhosttyIcon.self, from: data)
            Issue.record("Expected decode to fail for invalid ghost color")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("Failed to decode ghost color"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got: \(error)")
        }
    }

    @Test func decodingInvalidScreenColorsDropsInvalidEntries() throws {
        let data = Data("""
        {
            "version": 1,
            "screenColors": ["#112233", "invalid", "#AABBCC"],
            "ghostColor": "#445566",
            "frame": "chrome"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ColorizedGhosttyIcon.self, from: data)
        #expect(decoded.screenColors.compactMap(\.hexString) == ["#112233", "#AABBCC"])
    }

    // MARK: - Equatable

    @Test func equatableUsesHexColorAndFrameValues() {
        let lhs = makeIcon(
            screenColors: [
                NSColor(red: 0x11 / 255.0, green: 0x22 / 255.0, blue: 0x33 / 255.0, alpha: 1.0),
                NSColor(red: 0xAA / 255.0, green: 0xBB / 255.0, blue: 0xCC / 255.0, alpha: 1.0),
            ],
            ghostColor: NSColor(red: 0x44 / 255.0, green: 0x55 / 255.0, blue: 0x66 / 255.0, alpha: 1.0),
            frame: .chrome
        )
        let rhs = makeIcon(frame: .chrome)

        #expect(lhs == rhs)
    }

    @Test func equatableReturnsFalseForDifferentFrame() {
        let lhs = makeIcon(frame: .aluminum)
        let rhs = makeIcon(frame: .chrome)
        #expect(lhs != rhs)
    }

    @Test func equatableReturnsFalseForDifferentScreenColors() {
        let lhs = makeIcon(screenColors: [NSColor(hex: "#112233")!, NSColor(hex: "#AABBCC")!])
        let rhs = makeIcon(screenColors: [NSColor(hex: "#112233")!, NSColor(hex: "#CCBBAA")!])
        #expect(lhs != rhs)
    }

    @Test func equatableReturnsFalseForDifferentGhostColor() {
        let lhs = makeIcon(ghostColor: NSColor(hex: "#445566")!)
        let rhs = makeIcon(ghostColor: NSColor(hex: "#665544")!)
        #expect(lhs != rhs)
    }
}
