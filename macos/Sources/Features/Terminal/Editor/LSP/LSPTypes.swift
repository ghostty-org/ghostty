import Foundation

/// A position in a document, as the protocol counts them.
///
/// **Zero-based lines, and columns in UTF-16 code units** — not characters,
/// not bytes. Getting this wrong is the classic LSP bug: everything works
/// until a line contains an emoji or an accent, and from there every
/// position on that line is off by one per character, so diagnostics
/// underline the wrong word and go-to-definition lands in the wrong place.
/// `NSString` is also UTF-16, which is what makes the conversion below a
/// direct one rather than a re-encoding.
struct LSPPosition: Equatable, Hashable {
    var line: Int
    var character: Int

    var value: LSPValue {
        ["line": .integer(line), "character": .integer(character)]
    }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ value: LSPValue?) {
        guard let line = value?["line"]?.intValue,
              let character = value?["character"]?.intValue
        else { return nil }
        self.line = line
        self.character = character
    }
}

struct LSPRange: Equatable, Hashable {
    var start: LSPPosition
    var end: LSPPosition

    var value: LSPValue { ["start": start.value, "end": end.value] }

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(_ value: LSPValue?) {
        guard let start = LSPPosition(value?["start"]),
              let end = LSPPosition(value?["end"])
        else { return nil }
        self.start = start
        self.end = end
    }
}

/// Converting between the protocol's coordinates and `NSRange`.
///
/// Kept as free functions over an `NSString` so both directions are pure
/// and testable — this is the piece most worth being sure about, since a
/// mistake here misplaces every feature at once rather than breaking one.
enum LSPTextCoordinates {
    /// Byte-free line starts: each entry is the UTF-16 offset where that
    /// zero-based line begins.
    ///
    /// Walking the whole document, so anything converting more than one
    /// position should build an `LSPLineIndex` once instead of calling the
    /// helpers below in a loop.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, enclosing, _ in
            let next = enclosing.location + enclosing.length
            if next < text.length { starts.append(next) }
        }
        return starts
    }

    static func offset(of position: LSPPosition, in text: NSString) -> Int? {
        LSPLineIndex(text).offset(of: position)
    }

    static func position(at offset: Int, in text: NSString) -> LSPPosition {
        LSPLineIndex(text).position(at: offset)
    }

    static func range(of range: LSPRange, in text: NSString) -> NSRange? {
        LSPLineIndex(text).range(of: range)
    }
}

/// The line starts of one document, computed once.
///
/// The helpers above each walk the whole document to answer a single
/// question, which is fine for one conversion and quadratic for a batch —
/// and a batch is the normal case: a file with sixty diagnostics was
/// scanning itself sixty times, on the main thread, every time SwiftUI
/// re-evaluated the view. Build this once and ask it repeatedly.
struct LSPLineIndex {
    private let starts: [Int]
    private let length: Int

    init(_ text: NSString) {
        self.starts = LSPTextCoordinates.lineStarts(in: text)
        self.length = text.length
    }

    func offset(of position: LSPPosition) -> Int? {
        guard position.line >= 0, position.line < starts.count else { return nil }
        return min(starts[position.line] + position.character, length)
    }

    func position(at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, length))

        // Binary search rather than a scan: this is asked once per hover and
        // once per click, but on a document with a hundred thousand lines a
        // linear walk is felt.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= clamped { low = middle } else { high = middle - 1 }
        }
        return LSPPosition(line: low, character: clamped - starts[low])
    }

    func range(of range: LSPRange) -> NSRange? {
        guard let start = offset(of: range.start),
              let end = offset(of: range.end),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// One problem the server reported.
struct LSPDiagnostic: Identifiable, Equatable {
    enum Severity: Int, Equatable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    let range: LSPRange
    let severity: Severity
    let message: String
    let source: String?

    var id: String { "\(range.start.line):\(range.start.character):\(message)" }

    init?(_ value: LSPValue) {
        guard let range = LSPRange(value["range"]),
              let message = value["message"]?.stringValue
        else { return nil }

        self.range = range
        self.message = message
        self.source = value["source"]?.stringValue
        // Absent severity means "the server didn't say", and the
        // specification's advice is for the client to decide. Error is the
        // safe reading: a problem shown too loudly gets noticed, one shown
        // too quietly does not.
        self.severity = Severity(rawValue: value["severity"]?.intValue ?? 1) ?? .error
    }
}

/// A place in a file, for go-to-definition and references.
struct LSPLocation: Identifiable, Equatable {
    let uri: String
    let range: LSPRange

    var id: String { "\(uri):\(range.start.line):\(range.start.character)" }

    var path: String {
        URL(string: uri)?.path ?? uri.replacingOccurrences(of: "file://", with: "")
    }

    init?(_ value: LSPValue) {
        // A server may answer with `Location`, `LocationLink`, or an array
        // of either. The link form names the target differently, and a
        // client that only understands one of them silently does nothing
        // for half the servers out there.
        if let uri = value["uri"]?.stringValue, let range = LSPRange(value["range"]) {
            self.uri = uri
            self.range = range
            return
        }
        if let uri = value["targetUri"]?.stringValue,
           let range = LSPRange(value["targetSelectionRange"]) ?? LSPRange(value["targetRange"]) {
            self.uri = uri
            self.range = range
            return
        }
        return nil
    }
}

/// One edit the server wants applied.
struct LSPTextEdit: Equatable {
    let range: LSPRange
    let newText: String

    init?(_ value: LSPValue) {
        guard let range = LSPRange(value["range"]),
              let newText = value["newText"]?.stringValue
        else { return nil }
        self.range = range
        self.newText = newText
    }

    /// Applies edits to a string.
    ///
    /// **Back to front.** Every edit's range refers to the *original* text,
    /// so applying them in order invalidates every position after the first
    /// one. Sorting descending means each edit lands before anything that
    /// could have moved it — which is why servers are allowed to return
    /// them in any order at all.
    static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        // One index for the whole batch: the ranges all refer to the
        // original text, so they can share it.
        let index = LSPLineIndex(ns)
        let ordered = edits.compactMap { edit -> (NSRange, String)? in
            guard let range = index.range(of: edit.range) else { return nil }
            return (range, edit.newText)
        }
        .sorted { $0.0.location > $1.0.location }

        for (range, replacement) in ordered {
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }
}
