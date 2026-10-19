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
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return Ghostty.Shell.escape(fileURL.path)
            } else {
                return item.string(forType: .string)
            }
        }

        guard !strings.isEmpty else {
            return nil
        }
        return strings.joined(separator: " ")
    }

    /// The file URLs on the pasteboard, e.g. files copied in Finder.
    private var ghosttyFileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                  url.isFileURL else { return nil }
            return url
        }
    }

    /// The data for the given MIME type, if the pasteboard can serve it.
    ///
    /// The canonical "text/plain" type uses the opinionated string
    /// contents so that e.g. copying a file yields its escaped path;
    /// this matches what pasting into the terminal produces. Copied
    /// files are additionally served as "text/uri-list" (RFC 2483, the
    /// type X11/Wayland clipboards carry file copies under). All other
    /// types are mapped through UTType.
    func ghosttyData(forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            guard let str = getOpinionatedStringContents() else { return nil }
            return Data(str.utf8)

        case "text/uri-list":
            let urls = ghosttyFileURLs
            guard !urls.isEmpty else { return nil }
            return Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)

        default:
            guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { return nil }
            return data(forType: type)
        }
    }

    /// The MIME types available on the pasteboard, best-effort mapped
    /// from the pasteboard types. Types without a MIME mapping are not
    /// reported. This only inspects declared types and never reads data,
    /// since mode 5522 paste events must remain metadata-only.
    func ghosttyAvailableMimes() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let availableTypes = types ?? []
        let mimeType: (NSPasteboard.PasteboardType) -> String? = { type in
            guard let mime = UTType(type.rawValue)?.preferredMIMEType else { return nil }
            return mime == "text/plain;charset=utf-8" ? "text/plain" : mime
        }

        // Plain text and copied files can both be served as the canonical
        // text representation. Infer this from declared types so lazy
        // pasteboard providers are not asked for their contents.
        let hasFileURL = availableTypes.contains(.fileURL)
        let hasPlainText = hasFileURL || availableTypes.contains { type in
            mimeType(type) == "text/plain"
        }
        if hasPlainText {
            result.append("text/plain")
            seen.insert("text/plain")
        }

        // Copied files are additionally served as a URI list. The
        // generic mapping below never reports this since file URL
        // pasteboard types have no MIME type.
        if hasFileURL {
            result.append("text/uri-list")
            seen.insert("text/uri-list")
        }

        for type in availableTypes {
            guard let mime = mimeType(type),
                  !seen.contains(mime) else { continue }
            seen.insert(mime)
            result.append(mime)
        }

        return result
    }

    /// The pasteboard for the Ghostty enum type. Returns nil for locations
    /// macOS can't serve; callers report those as unsupported.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        case GHOSTTY_CLIPBOARD_PRIMARY:
            // macOS has no primary selection.
            return nil

        default:
            return nil
        }
    }
}
