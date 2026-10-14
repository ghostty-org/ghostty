import Foundation
import UniformTypeIdentifiers

/// A file or directory listed in the file explorer.
struct FileExplorerEntry: Equatable {
    let url: URL
    let name: String

    /// True for directories we can expand. Packages (e.g. `.app`) are treated as files.
    let isDirectory: Bool
    let isHidden: Bool
}

/// Pure logic used by the file explorer and the file preview. This is kept free of
/// AppKit state so it can be unit tested.
enum FileExplorerLogic {
    /// The minimum width the user can resize the file preview to.
    static let previewMinWidth: CGFloat = 240

    /// The maximum width the user can resize the file preview to.
    static let previewMaxWidth: CGFloat = 1200

    /// The width of the file preview if the user never resized it.
    static let previewDefaultWidth: CGFloat = 480

    /// Text files larger than this are not previewed as text.
    static let maxTextPreviewBytes = 2 * 1024 * 1024

    /// How many bytes we look at to decide if a file is binary.
    static let sniffBytes = 8 * 1024

    // MARK: Listing

    /// Lists the entries of a directory, directories first. Returns an empty list if the
    /// directory can't be read.
    static func listDirectory(_ url: URL, showHidden: Bool) -> [FileExplorerEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }

        let entries = urls.compactMap { url -> FileExplorerEntry? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            let isHidden = values?.isHidden ?? name.hasPrefix(".")
            if isHidden && !showHidden { return nil }
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return FileExplorerEntry(url: url, name: name, isDirectory: isDirectory, isHidden: isHidden)
        }

        return sort(entries)
    }

    /// Sorts entries like Finder: directories first, then by name.
    static func sort(_ entries: [FileExplorerEntry]) -> [FileExplorerEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Preview

    /// How a file is shown in the file preview.
    enum PreviewKind: Equatable {
        /// Shown as plain text.
        case text

        /// Shown with Quick Look (images, PDFs, binaries, ...).
        case quickLook

        /// A text file that is too large to show.
        case tooLarge
    }

    /// Decides how to preview the file at the given URL.
    static func previewKind(for url: URL, maxTextBytes: Int = maxTextPreviewBytes) -> PreviewKind {
        if let type = UTType(filenameExtension: url.pathExtension),
           [.image, .pdf, .audiovisualContent, .font].contains(where: { type.conforms(to: $0) }) {
            return .quickLook
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return .quickLook }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sniffBytes)) ?? Data()
        if head.contains(0) { return .quickLook }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > maxTextBytes ? .tooLarge : .text
    }

    /// Reads a text file, guessing the encoding if it isn't UTF-8.
    static func readText(_ url: URL) -> String? {
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            return text
        }

        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    // MARK: Layout

    /// Clamps a stored (user-chosen) preview width into the valid range.
    static func clampPreviewWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return previewDefaultWidth }
        return min(max(width, previewMinWidth), previewMaxWidth)
    }

    /// The width actually laid out for the preview, given the width available for both the
    /// terminal and the preview. The terminal keeps at least its minimum width.
    static func effectivePreviewWidth(stored: CGFloat, available: CGFloat) -> CGFloat {
        let width = clampPreviewWidth(stored)
        let room = available - TabSidebarLogic.minTerminalWidth
        return max(0, min(width, room))
    }
}
