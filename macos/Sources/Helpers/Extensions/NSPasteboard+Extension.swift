import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }
        
        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }
        
        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            return urls
                .map { $0.isFileURL ? Ghostty.Shell.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let str = self.string(forType: .string) {
            return str
        }

        // Try image data — save to temp file, return path
        return self.getImageAsTemporaryFilePath()
    }

    /// Checks if the clipboard contains image data (PNG, TIFF).
    /// If so, saves to a temp file and returns the shell-escaped file path.
    func getImageAsTemporaryFilePath() -> String? {
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (.tiff, "tiff"),
        ]

        for (pbType, _) in imageTypes {
            if let data = self.data(forType: pbType) {
                // Convert TIFF to PNG for universal compatibility
                let pngData: Data
                if pbType == .tiff {
                    guard let imageRep = NSBitmapImageRep(data: data),
                          let converted = imageRep.representation(using: .png, properties: [:]) else {
                        continue
                    }
                    pngData = converted
                } else {
                    pngData = data
                }

                let tempDir = FileManager.default.temporaryDirectory
                let filename = "ghostty-paste-\(UUID().uuidString).png"
                let fileURL = tempDir.appendingPathComponent(filename)

                do {
                    try pngData.write(to: fileURL)
                    return Ghostty.Shell.escape(fileURL.path)
                } catch {
                    continue
                }
            }
        }

        return nil
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch (clipboard) {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}
