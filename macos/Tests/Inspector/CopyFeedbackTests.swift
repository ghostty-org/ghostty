import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct CopyFeedbackTests {
    private func pasteboard(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test func buttonConfirmsInPlaceAndRestoresItsLabel() async throws {
        let pasteboard = pasteboard("omg.copy-feedback.button")
        let button = CopyFeedbackButton(frame: NSRect(x: 0, y: 0, width: 160, height: 18))
        button.pasteboard = pasteboard
        button.configure(display: "deadbeef", value: "deadbeef")
        #expect(button.title == "deadbeef")

        button.performClick(nil)
        #expect(pasteboard.string(forType: .string) == "deadbeef")
        #expect(button.title == CopyFeedback.confirmationLabel())

        try await Task.sleep(for: .seconds(CopyFeedback.duration + 0.4))
        #expect(button.title == "deadbeef")
    }

    @Test func disabledButtonDoesNotCopy() throws {
        let pasteboard = pasteboard("omg.copy-feedback.disabled")
        let button = CopyFeedbackButton(frame: NSRect(x: 0, y: 0, width: 160, height: 18))
        button.pasteboard = pasteboard
        button.configure(display: "unavailable", value: nil)
        #expect(!button.isEnabled)
        button.performClick(nil)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func metadataCopyUsesTheSharedConfirmation() async throws {
        let pasteboard = pasteboard("omg.copy-feedback.metadata")
        let field = InspectorMetadataText(frame: NSRect(x: 0, y: 0, width: 160, height: 18))
        field.pasteboard = pasteboard
        field.configure(text: "abc123", value: "abc123", label: "Copy hash")

        field.copy(nil)
        #expect(pasteboard.string(forType: .string) == "abc123")
        #expect(field.title == CopyFeedback.confirmationLabel())

        try await Task.sleep(for: .seconds(CopyFeedback.duration + 0.4))
        #expect(field.title == "abc123")
    }

    @Test func temporaryPastedImagesAreRecognizedAsNoise() {
        #expect(TransientAttachmentNoise.isNoise(line:
            "/var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-paste/omg-paste-72C0E55E-5A19-4963-8B86-FBE0A4276DE4.png"))
        #expect(TransientAttachmentNoise.isNoise(line: "Image attachment: true"))
        #expect(!TransientAttachmentNoise.isNoise(line:
            "这个 /var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-paste/x.png 打不开，帮我看下原因"))
        #expect(!TransientAttachmentNoise.isNoise(line: "Keep this explanation."))
    }
}
