import Foundation
import UniformTypeIdentifiers

/// A URL supplied by a source that should not be allowed to dispatch directly
/// to the operating system, such as terminal output.
struct UntrustedURL: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        var message: String {
            switch self {
            case .malformedURL:
                "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                "The target contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web target does not contain a valid host."
            case .inaccessibleFile:
                "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                "Opening this local target could execute code."
            }
        }
    }

    enum Decision: Equatable {
        /// Open schemes with non-executing, well-understood behavior directly.
        case allow(URL)

        /// Ask before dispatching a custom scheme to its registered handler.
        case confirm(URL)

        /// Never dispatch malformed targets or executable local files.
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation accepts many Unicode control and formatting characters in
        // a URL. UI frameworks can render those same characters as line breaks,
        // zero-width text, or bidirectional overrides, so reject them before
        // parsing changes their representation.
        guard !string.unicodeScalars.contains(where: Self.isUnsafeCharacter) else {
            return .deny(.unsafeCharacters)
        }

        // URL(string:) also accepts relative references. An untrusted target
        // must include an explicit scheme so it cannot be reinterpreted as a
        // local path by a later layer.
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            // Reject values such as "https:relative". They have a scheme, but
            // no authority, and different consumers may resolve them against a
            // base URL differently.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)

        case "mailto":
            // URLComponents places the address portion of a mailto URL in the
            // path. Require one so a bare "mailto:" cannot dispatch an empty
            // request to the user's mail application.
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)

        case "file":
            return fileDecision(for: url)

        default:
            // A custom scheme can invoke any application registered with
            // Launch Services. The caller must show the target and handler
            // before allowing that dispatch.
            return .confirm(url)
        }
    }

    /// A single-line representation of the effective target. Paths are
    /// standardized before display so traversal and repeated separators cannot
    /// cause the visible and opened targets to differ.
    var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            // File URLs are standardized exactly as they are before opening,
            // including symlink resolution. Keep non-file URLs byte-for-byte
            // equivalent because repeated separators can be meaningful to a
            // web or custom-scheme handler.
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            // Scheme-less values are never allowed to open, but they still
            // appear in the blocked-target UI. Standardizing them prevents
            // slash padding and dot traversal from hiding the effective path.
            normalized = URL(filePath: string).standardizedFileURL.path
        }

        // Escaping happens after normalization so any unsafe scalar that
        // remains is visible as text and cannot create a second display line.
        var result = String()
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }
}

private extension UntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        // Only local file URLs are meaningful here. Queries and fragments do
        // not identify part of a filesystem object and may be interpreted
        // inconsistently by Launch Services handlers.
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }

        // An empty host and localhost both refer to this machine. Do not allow
        // file URLs that name a remote host and could trigger network access.
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }

        // Classify the effective object, not the spelling supplied by terminal
        // output. This collapses dot traversal and prevents a harmless-looking
        // symlink name from hiding an executable target.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues: URLResourceValues
        do {
            // Reading all relevant resource keys together also proves that the
            // canonical target exists and is accessible.
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }

        // Exclude devices, sockets, and other special filesystem objects. A
        // directory is safe to reveal in Finder unless its extension or UTI
        // identifies it as an application bundle.
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: resourceValues) else {
            return .deny(.unsafeFile)
        }

        return .allow(canonicalURL)
    }

    static func isUnsafeFile(
        _ url: URL,
        resourceValues: URLResourceValues
    ) -> Bool {
        // Launch Services uses extensions when choosing a handler. Block known
        // executable containers even when their POSIX executable bit is clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        // UTIs cover files whose extension is missing or intentionally
        // misleading. Use broad system-declared types so subclasses such as
        // shell scripts and application bundles are included automatically.
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }

        // Finally, reject any regular file the filesystem marks executable,
        // regardless of its name or detected content type.
        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0/C1 controls include CR, LF, NEL, and other non-printing bytes.
        case 0x00...0x1F, 0x7F...0x9F:
            return true

        // Directional marks and zero-width characters can reorder or conceal
        // portions of the target without changing what the handler receives.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true

        // Unicode line/paragraph separators create additional visual lines in
        // SwiftUI and AppKit text even though OSC accepts their UTF-8 bytes.
        case 0x2028...0x2029:
            return true

        // Word Joiner and BOM are invisible formatting characters that can be
        // used as padding or to disguise otherwise identical-looking targets.
        case 0x2060, 0xFEFF:
            return true

        default:
            return false
        }
    }

    // Keep the large policy tables after the behavior so the primary type and
    // its decision flow remain easy to scan.
    static let unsafePathExtensions: Set<String> = [
        "action",
        "app",
        "applescript",
        "class",
        "command",
        "desktop",
        "inetloc",
        "jar",
        "mobileconfig",
        "mpkg",
        "pkg",
        "scpt",
        "terminal",
        "tool",
        "url",
        "webloc",
        "workflow",
    ]

    static let unsafeContentTypes: [UTType] = [
        .application,
        .executable,
        .script,
    ]
}
