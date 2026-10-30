import AppKit
import Carbon
import ObjectiveC
import Testing
@testable import Ghostty

@MainActor
struct SurfaceInputContextTests {
    @Test func documentAccessIsDisabledOnlyForTerminalContext() throws {
        let previous = NSTextInputContext.current
        let editorView = NSTextView()
        let terminalView = NSTextView()
        let editorContext = NSTextInputContext(client: editorView)
        editorContext.activate()
        let editorDocument = try #require(TSMGetActiveDocument())
        let terminalContext = Ghostty.SurfaceInputContext(client: terminalView)
        defer {
            terminalContext.deactivate()
            editorContext.deactivate()
            previous?.activate()
            withExtendedLifetime((editorView, terminalView)) {}
        }

        // Creating a terminal context must neither activate it nor change the editor.
        #expect(TSMGetActiveDocument() == editorDocument)
        #expect(try supportsDocumentAccess(editorDocument))
        // An IME selected before opening a new terminal reads this during activate().
        // Checking only after activate() misses the first-consonant regression.
        #expect(try !supportsDocumentAccess(document(of: terminalContext)))

        terminalContext.activate()
        #expect(try !supportsDocumentAccess(try #require(TSMGetActiveDocument())))

        terminalContext.deactivate()
        editorContext.activate()
        #expect(try supportsDocumentAccess(try #require(TSMGetActiveDocument())))

        terminalContext.activate()
        #expect(try !supportsDocumentAccess(try #require(TSMGetActiveDocument())))
    }

    private func document(of context: NSTextInputContext) throws -> TSMDocumentID {
        let ivar = try #require(class_getInstanceVariable(NSTextInputContext.self, "_documentID"))
        let encoding = try #require(ivar_getTypeEncoding(ivar))
        try #require(String(cString: encoding) == "^v")
        return try #require(Unmanaged.passUnretained(context).toOpaque()
            .advanced(by: ivar_getOffset(ivar)).load(as: TSMDocumentID?.self))
    }

    private func supportsDocumentAccess(_ document: TSMDocumentID) throws -> Bool {
        var size: UInt32 = 0
        var value: UInt32 = 0
        let status = TSMGetDocumentProperty(
            document,
            TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag),
            UInt32(MemoryLayout.size(ofValue: value)),
            &size,
            &value)
        #expect(status == noErr || status == tsmDocPropertyNotFoundErr)
        return status == noErr
    }
}
