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
        let starts = lineStarts(in: text)
        guard position.line >= 0, position.line < starts.count else { return nil }
        let offset = starts[position.line] + position.character
        return min(offset, text.length)
    }

    static func position(at offset: Int, in text: NSString) -> LSPPosition {
        let starts = lineStarts(in: text)
        let clamped = max(0, min(offset, text.length))

        var line = 0
        for (index, start) in starts.enumerated() where start <= clamped {
            line = index
        }
        return LSPPosition(line: line, character: clamped - starts[line])
    }

    static func range(of range: LSPRange, in text: NSString) -> NSRange? {
        guard let start = offset(of: range.start, in: text),
              let end = offset(of: range.end, in: text),
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
        let ordered = edits.compactMap { edit -> (NSRange, String)? in
            guard let range = LSPTextCoordinates.range(of: edit.range, in: ns) else { return nil }
            return (range, edit.newText)
        }
        .sorted { $0.0.location > $1.0.location }

        for (range, replacement) in ordered {
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }
}
