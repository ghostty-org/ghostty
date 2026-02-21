//
//  NSPasteboardTests.swift
//  GhosttyTests
//
//  Tests for NSPasteboard.PasteboardType MIME type conversion.
//

import Testing
import AppKit
@testable import Ghostty

struct NSPasteboardTypeExtensionTests {
    /// Test text/plain MIME type converts to .string
    @Test func testTextPlainMimeType() async throws {
        let pasteboardType = NSPasteboard.PasteboardType(mimeType: "text/plain")
        #expect(pasteboardType != nil)
        #expect(pasteboardType == .string)
    }
    
    /// Test text/html MIME type converts to .html
    @Test func testTextHtmlMimeType() async throws {
        let pasteboardType = NSPasteboard.PasteboardType(mimeType: "text/html")
        #expect(pasteboardType != nil)
        #expect(pasteboardType == .html)
    }
    
    /// Test image/png MIME type
    @Test func testImagePngMimeType() async throws {
        let pasteboardType = NSPasteboard.PasteboardType(mimeType: "image/png")
        #expect(pasteboardType != nil)
        #expect(pasteboardType == .png)
    }
}

struct NSPasteboardExtensionTests {
    @Test func hasTextContentReturnsTrueForString() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        #expect(pasteboard.hasTextContent())
    }

    @Test func hasTextContentReturnsTrueForURL() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([NSURL(string: "https://example.com")!])
        #expect(ok)

        #expect(pasteboard.hasTextContent())
    }

    @Test func hasTextContentReturnsFalseForImageOnly() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let ok = pasteboard.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
        #expect(ok)

        #expect(!pasteboard.hasTextContent())
    }

    @Test func hasTextContentMatchesOpinionatedStringAvailabilityForSupportedTypes() {
        func assertSync(_ pasteboard: NSPasteboard) {
            #expect(pasteboard.hasTextContent() == (pasteboard.getOpinionatedStringContents() != nil))
        }

        let stringPasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        stringPasteboard.clearContents()
        let stringSet = stringPasteboard.setString("hello", forType: .string)
        #expect(stringSet)
        assertSync(stringPasteboard)

        let urlPasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        urlPasteboard.clearContents()
        let urlSet = urlPasteboard.writeObjects([NSURL(string: "https://example.com")!])
        #expect(urlSet)
        assertSync(urlPasteboard)

        let fileURLPasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        fileURLPasteboard.clearContents()
        let fileURLSet = fileURLPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/ghostty test.txt")])
        #expect(fileURLSet)
        assertSync(fileURLPasteboard)
    }
}
