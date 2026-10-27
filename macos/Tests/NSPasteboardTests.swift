//
//  NSPasteboardTests.swift
//  GhosttyTests
//
//  Tests for NSPasteboard.PasteboardType MIME type conversion and
//  NSPasteboard.getOpinionatedStringContents.
//

import Testing
import AppKit
@testable import Ghostty
import GhosttyKit

struct NSPasteboardTests {
    // MARK: - Test Helpers

    /// Creates a uniquely-named pasteboard so tests never touch the user's
    /// general pasteboard and can run concurrently.
    static func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// Builds an item carrying a plain string (public.utf8-plain-text).
    static func stringItem(_ string: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        return item
    }

    /// Builds an item carrying a file URL (public.file-url). The string stored on
    /// the pasteboard is the URL string form, e.g. "file:///Users/test%20file.txt",
    /// which is exactly what AppKit registers when a file URL is copied.
    static func fileURLItem(_ urlString: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(urlString, forType: .fileURL)
        return item
    }

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

    /// Tests for `NSPasteboard.getOpinionatedStringContents`, which per its documented
    /// semantics must, for each pasteboard item:
    /// - prefer the absolute filesystem path of a file URL, shell-escaped,
    /// - otherwise fall back to any plain string on the item,
    /// and return nil when nothing usable is found. Multiple results join with a space.
    struct NSPasteboardOpinionatedContentsTests {
        let pasteboard = makePasteboard()

        // MARK: - Plain String Contents

        @Test func testSingleStringItem() {
            pasteboard.writeObjects([stringItem("hello world")])

            #expect(pasteboard.getOpinionatedStringContents() == "hello world")
        }

        @Test func testMultipleStringItemsJoinedWithSpace() {
            pasteboard.writeObjects([stringItem("first"), stringItem("second")])

            #expect(pasteboard.getOpinionatedStringContents() == "first second")
        }

        /// A remote URL that is present as plain text is returned verbatim, not
        /// treated as a file.
        @Test func testStringContainingRemoteURL() {
            pasteboard.writeObjects([stringItem("https://example.com/page")])

            #expect(pasteboard.getOpinionatedStringContents() == "https://example.com/page")
        }

        // MARK: - File URL Contents

        /// A file URL must produce the absolute filesystem path, not the URL string.
        @Test func testSingleFileURL() {
            pasteboard.writeObjects([fileURLItem("file:///Users/test/document.txt")])

            #expect(pasteboard.getOpinionatedStringContents() == "/Users/test/document.txt")
        }

        /// Percent-encoded characters must be decoded to the real path, and
        /// shell-sensitive characters escaped for insertion into a terminal buffer.
        @Test func testFileURLWithCharactersNeedingEscaping() {
            pasteboard.writeObjects([fileURLItem("file:///Users/test/my%20file%20(1).txt")])

            #expect(pasteboard.getOpinionatedStringContents() == #"/Users/test/my\ file\ \(1\).txt"#)
        }

        @Test func testMultipleFileURLsJoinedWithSpace() {
            pasteboard.writeObjects([
                fileURLItem("file:///Users/test/a.txt"),
                fileURLItem("file:///Users/test/b.txt"),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == "/Users/test/a.txt /Users/test/b.txt")
        }

        /// When an item carries both a file URL and a string, the file path wins.
        @Test func testFileURLTakesPrecedenceOverString() {
            let item = NSPasteboardItem()
            item.setString("file:///Users/test/document.txt", forType: .fileURL)
            item.setString("document.txt", forType: .string)
            pasteboard.writeObjects([item])

            #expect(pasteboard.getOpinionatedStringContents() == "/Users/test/document.txt")
        }

        @Test func testMixedFileURLAndStringItems() {
            pasteboard.writeObjects([
                fileURLItem("file:///Users/test/a.txt"),
                stringItem("plain text"),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == "/Users/test/a.txt plain text")
        }

        /// A mailto URL present as plain text is returned verbatim, like any string.
        @Test func testMailtoStringReturnedVerbatim() {
            pasteboard.writeObjects([stringItem("mailto:exam@ple.com")])

            #expect(pasteboard.getOpinionatedStringContents() == "mailto:exam@ple.com")
        }

        /// A non-file URL stored under the file-URL type must not be treated as a
        /// filesystem path (its path would be empty); the string fallback wins.
        @Test func testMailtoUnderFileURLTypeFallsBackToString() {
            let item = NSPasteboardItem()
            item.setString("mailto:exam@ple.com", forType: .fileURL)
            item.setString("exam@ple.com", forType: .string)
            pasteboard.writeObjects([item])

            #expect(pasteboard.getOpinionatedStringContents() == "exam@ple.com")
        }

        // MARK: - Remote File Promises

        /// Builds an item mimicking a remote-file drag (e.g. Panic Transmit/Nova):
        /// file-promise metadata plus a remote public.url, but no public.file-url.
        private func remoteFilePromiseItem(url urlString: String, string: String?) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString("file.txt", forType: .init("com.apple.pasteboard.promised-file-name"))
            item.setString("public.data", forType: .init("com.apple.pasteboard.promised-file-content-type"))
            item.setData(Data([0x00]), forType: .init("com.apple.NSFilePromiseItemMetaData"))
            item.setData(Data([0x00]), forType: .init("com.apple.pasteboard.NSFilePromiseID"))
            item.setString(urlString, forType: .init("public.url"))
            if let string {
                item.setString(string, forType: .string)
            }
            return item
        }

        /// A remote file promise has no local filesystem path, so the item's plain
        /// string is returned as-is: no file-path treatment, no shell escaping.
        @Test func testRemoteFilePromiseFallsBackToString() {
            pasteboard.writeObjects([
                remoteFilePromiseItem(
                    url: "sftp://example.com/remote%20dir/file.txt",
                    string: "sftp://example.com/remote%20dir/file.txt"
                ),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == "sftp://example.com/remote%20dir/file.txt")
        }

        @Test func testMultipleRemoteFilePromisesJoinedWithSpace() {
            pasteboard.writeObjects([
                remoteFilePromiseItem(url: "sftp://example.com/a.txt", string: "sftp://example.com/a.txt"),
                remoteFilePromiseItem(url: "sftp://example.com/b.txt", string: "sftp://example.com/b.txt"),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == "sftp://example.com/a.txt sftp://example.com/b.txt")
        }

        /// A promise item that offers no plain string (only promise metadata and a
        /// remote URL) contributes nothing.
        @Test func testRemoteFilePromiseWithoutStringReturnsNil() {
            pasteboard.writeObjects([
                remoteFilePromiseItem(url: "sftp://example.com/file.txt", string: nil),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == nil)
        }

        /// A local file drag next to a remote promise: the local item yields its
        /// escaped path, the remote one its string.
        @Test func testMixedLocalFileAndRemoteFilePromise() {
            pasteboard.writeObjects([
                fileURLItem("file:///Users/test/local.txt"),
                remoteFilePromiseItem(url: "sftp://example.com/remote.txt", string: "sftp://example.com/remote.txt"),
            ])

            #expect(pasteboard.getOpinionatedStringContents() == "/Users/test/local.txt sftp://example.com/remote.txt")
        }

        // MARK: - Nothing Usable

        @Test func testEmptyPasteboardReturnsNil() {
            #expect(pasteboard.getOpinionatedStringContents() == nil)
        }

        /// An item with only a binary type has no string or file path to offer.
        @Test func testNonStringItemReturnsNil() {
            let item = NSPasteboardItem()
            item.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
            pasteboard.writeObjects([item])

            #expect(pasteboard.getOpinionatedStringContents() == nil)
        }

        /// A remote URL item (public.url, no file URL and no string rep) is dropped:
        /// only file URLs are read from the clipboard.
        @Test func testRemoteURLOnlyItemReturnsNil() {
            let item = NSPasteboardItem()
            item.setString("https://example.com/page", forType: .init("public.url"))
            pasteboard.writeObjects([item])

            #expect(pasteboard.getOpinionatedStringContents() == nil)
        }
    }

    struct NSPasteboardGhosttyDataTests {
        let pasteboard = makePasteboard()

        // MARK: - Plain Texts

        @Test func testTextPlainMimeTypeNoStringReturnsNil() {
            #expect(pasteboard.ghosttyData(forMime: "text/plain") == nil)
        }

        @Test func testTextPlainMimeTypeReturnsData() {
            let text = "hello world"
            pasteboard.writeObjects([stringItem(text)])

            #expect(pasteboard.ghosttyData(forMime: "text/plain") == text.data(using: .utf8))
        }

        // MARK: - Text URI List

        @Test func testTextURIListNoFileURLsReturnsNil() {
            #expect(pasteboard.ghosttyData(forMime: "text/uri-list") == nil)
        }

        @Test func testTextURIListReturnsData() {
            let fileURLs = "file:///Users/test/a.txt\r\nfile:///Users/test/b.txt\r\n"
            pasteboard.writeObjects([
                fileURLItem("file:///Users/test/a.txt"),
                fileURLItem("file:///Users/test/b.txt"),
            ])

            #expect(pasteboard.ghosttyData(forMime: "text/uri-list") == fileURLs.data(using: .utf8))
        }

        // MARK: - Other MIME types

        @Test func testImagePNGMIMETypeReturnsData() {
            let imageData = Data([0x89, 0x50, 0x4e, 0x47])
            let item = NSPasteboardItem()
            item.setData(imageData, forType: .png)
            pasteboard.writeObjects([item])

            #expect(pasteboard.ghosttyData(forMime: "image/png") == imageData)
        }
    }

    struct NSPasteboardGhosttyAvailableMimesTests {
        let pasteboard = makePasteboard()

        @Test func testWithMultipleTypesReturnsAvailableTypes() {
            let imageData = Data([0x89, 0x50, 0x4e, 0x47])
            let item = NSPasteboardItem()
            item.setData(imageData, forType: .png)

            pasteboard.writeObjects([
                fileURLItem("file:///Users/test/a.txt"),
                fileURLItem("file:///Users/test/b.txt"),
                item
            ])

            #expect(pasteboard.ghosttyAvailableMimes() == ["text/plain", "text/uri-list", "image/png", "image/tiff"])
        }
    }

    struct NSPasteboardGhosttyTests {
        @Test func testStandardClipboardReturnsGeneralPasteboard() {
            #expect(NSPasteboard.ghostty(GHOSTTY_CLIPBOARD_STANDARD) === NSPasteboard.general)
        }

        @Test func testSelectionClipboardReturnsGhosttySelectionPasteboard() {
            #expect(NSPasteboard.ghostty(GHOSTTY_CLIPBOARD_SELECTION) === NSPasteboard.ghosttySelection)
        }

        @Test func testPrimaryClipboardReturnsNil() {
            #expect(NSPasteboard.ghostty(GHOSTTY_CLIPBOARD_PRIMARY) == nil)
        }

        @Test func testUnknownClipboardReturnsNil() {
            let unknown = ghostty_clipboard_e(rawValue: 999)
            #expect(NSPasteboard.ghostty(unknown) == nil)
        }
    }
}
