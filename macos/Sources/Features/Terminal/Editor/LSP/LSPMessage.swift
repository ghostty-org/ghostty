import Foundation

/// The framing LSP wraps around every JSON-RPC body.
///
/// It is HTTP-ish but not HTTP: a header block, a blank line, then exactly
/// `Content-Length` bytes of JSON, with no terminator afterwards. The next
/// message's header begins on the very next byte, which is why a decoder
/// can't look for a delimiter and has to trust the count.
enum LSPWireFormat {
    static let jsonrpcVersion = "2.0"
    static let contentLengthHeader = "Content-Length"

    /// Only `\r\n` is legal per the spec, so the terminator is a fixed
    /// four-byte pattern rather than anything line-ending-tolerant.
    static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Wraps an encoded JSON body in its header block.
    ///
    /// The length is the body's *byte* count. Measuring a `String`'s `count`
    /// instead understates it by one for every non-ASCII character in the
    /// payload — a single accented identifier in a completion request is
    /// enough — and the server then reads the following message's first
    /// bytes as the tail of this one and never recovers.
    static func frame(_ body: Data) -> Data {
        var framed = Data("\(contentLengthHeader): \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }
}

/// A JSON-RPC request id.
///
/// Both shapes are legal and a response has to echo the id it was given
/// *unchanged*. Normalizing `"7"` to `7` on the way in would make the two
/// collide in the pending-request table and hand one call another's reply.
enum LSPRequestID: Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    var description: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }

    /// The id as it travels inside `$/cancelRequest` params, where it is a
    /// value rather than the envelope's own field.
    var value: LSPValue {
        switch self {
        case .number(let value): return .integer(value)
        case .string(let value): return .string(value)
        }
    }
}

extension LSPRequestID: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// An arbitrary JSON value.
///
/// The transport deliberately stops here instead of decoding into concrete
/// types. `params` and `result` have a different shape per method, and the
/// shape also differs per server and per server *version* — a transport
/// that decoded them would have to know every method LSP has, and would
/// throw away a payload it merely failed to recognize. Callers decode the
/// subtree they understand.
enum LSPValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([LSPValue])
    case object([String: LSPValue])
}

extension LSPValue: Codable {
    /// Order matters: `Bool` is tried before the numbers because a JSON
    /// `true` will happily decode as neither, but a JSON `1` must not be
    /// allowed to answer to `Bool`; and `Int` before `Double` so that ids,
    /// line numbers and character offsets survive a round trip as integers
    /// rather than coming back as `3.0`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LSPValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: LSPValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension LSPValue {
    var isNull: Bool { self == .null }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Accepts a whole `Double` too: a server is free to send `1` as `1.0`,
    /// and every position and offset in LSP is conceptually an integer.
    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [LSPValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: LSPValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> LSPValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    subscript(index: Int) -> LSPValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

/// Literal conformances exist so that building `initialize` params reads
/// like the JSON in the specification instead of like six nested enum
/// constructors.
extension LSPValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension LSPValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension LSPValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .integer(value) }
}

extension LSPValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension LSPValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension LSPValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: LSPValue...) { self = .array(elements) }
}

extension LSPValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, LSPValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// The error object a server puts in place of a result.
struct LSPResponseError: Error, Hashable, Sendable, Codable {
    let code: Int
    let message: String
    let data: LSPValue?

    init(code: Int, message: String, data: LSPValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

extension LSPResponseError {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    /// What to answer a server request nobody handles. Silence is not an
    /// option: a server that asked a question blocks until it gets an
    /// answer, so an unhandled request has to be refused, out loud.
    static func unhandled(_ method: String) -> LSPResponseError {
        LSPResponseError(code: methodNotFound, message: "Unhandled method: \(method)")
    }
}

/// A call that expects an answer.
struct LSPRequest: Hashable, Sendable {
    let id: LSPRequestID
    let method: String
    let params: LSPValue?

    init(id: LSPRequestID, method: String, params: LSPValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A call that expects nothing back. Answering one is a protocol error, so
/// the absence of an id is load-bearing rather than an optimization.
struct LSPNotification: Hashable, Sendable {
    let method: String
    let params: LSPValue?

    init(method: String, params: LSPValue? = nil) {
        self.method = method
        self.params = params
    }
}

/// The answer to a request.
struct LSPResponse: Hashable, Sendable {
    /// Null when the request was so malformed the server could not read its
    /// id — the one case where a response can't be correlated with anything
    /// and can only be logged.
    let id: LSPRequestID?
    let result: LSPValue?
    let error: LSPResponseError?

    init(id: LSPRequestID?, result: LSPValue? = nil, error: LSPResponseError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    var isSuccess: Bool { error == nil }
}

/// One JSON-RPC message, in either direction.
///
/// Servers send requests too — `client/registerCapability` and
/// `workspace/configuration` arrive as questions the client must answer —
/// so this is not a "response only" inbound type.
enum LSPMessage: Hashable, Sendable {
    case request(LSPRequest)
    case response(LSPResponse)
    case notification(LSPNotification)
}

extension LSPMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    /// JSON-RPC has no type tag; the shape *is* the tag. `method` plus `id`
    /// is a request, `method` alone is a notification, and anything else is
    /// a response — including one whose id is null.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try Self.requestID(in: container)

        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try Self.value(in: container, forKey: .params)
            if let id {
                self = .request(LSPRequest(id: id, method: method, params: params))
            } else {
                self = .notification(LSPNotification(method: method, params: params))
            }
            return
        }

        self = .response(LSPResponse(
            id: id,
            result: try Self.value(in: container, forKey: .result),
            error: try container.decodeIfPresent(LSPResponseError.self, forKey: .error)
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(LSPWireFormat.jsonrpcVersion, forKey: .jsonrpc)

        switch self {
        case .request(let request):
            try container.encode(request.id, forKey: .id)
            try container.encode(request.method, forKey: .method)
            try container.encodeIfPresent(request.params, forKey: .params)

        case .notification(let notification):
            try container.encode(notification.method, forKey: .method)
            try container.encodeIfPresent(notification.params, forKey: .params)

        case .response(let response):
            if let id = response.id {
                try container.encode(id, forKey: .id)
            } else {
                try container.encodeNil(forKey: .id)
            }
            if let error = response.error {
                try container.encode(error, forKey: .error)
            } else {
                try container.encode(response.result ?? .null, forKey: .result)
            }
        }
    }

    /// `decodeIfPresent` collapses "absent" and "null" into nil, which is
    /// wrong here twice over: `"result": null` is a *successful* answer (it
    /// is what `shutdown` returns), and an absent result with an error is a
    /// different message entirely.
    private static func value(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> LSPValue? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return .null }
        return try container.decode(LSPValue.self, forKey: key)
    }

    private static func requestID(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LSPRequestID? {
        guard container.contains(.id) else { return nil }
        if try container.decodeNil(forKey: .id) { return nil }
        return try container.decode(LSPRequestID.self, forKey: .id)
    }
}

extension LSPMessage {
    /// Slashes are left alone because `rootUri` and every `textDocument.uri`
    /// is a `file://` URL, and `file:\/\/\/Users\/…` — legal JSON, and what
    /// the encoder does by default — makes every log line unreadable. Keys
    /// are sorted for the same reason: so two encodings of the same message
    /// are diffable.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The JSON body, unframed.
    func encodedBody() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// The bytes to write to a server's stdin: header block and body.
    func encoded() throws -> Data {
        LSPWireFormat.frame(try encodedBody())
    }

    /// Decodes one complete body. The framing is `LSPMessageDecoder`'s job.
    static func decode(body: Data) throws -> LSPMessage {
        try JSONDecoder().decode(LSPMessage.self, from: body)
    }
}

/// What went wrong between two well-formed messages.
enum LSPFramingError: Error, Hashable, Sendable {
    /// A header block arrived without the one header that matters.
    case missingContentLength(header: String)

    /// The declared number of bytes did not contain a JSON-RPC message.
    case invalidBody(byteCount: Int, reason: String)

    /// Bytes accumulated with no header terminator anywhere in them.
    case headerTooLong(byteCount: Int)

    /// A `Content-Length` large enough that honouring it would be a way to
    /// exhaust memory rather than a way to read a message.
    case messageTooLarge(declared: Int)
}

/// Reassembles a language server's stdout into whole messages.
///
/// A pipe hands over whatever happened to be written when the reader woke
/// up. One `read` can be half a header, or three complete messages plus the
/// first eleven bytes of a fourth, and the split lands in a different place
/// every run. So everything is held in one byte buffer and consumed only
/// when a whole message is provably present.
///
/// Two traps shaped this:
///
/// `Content-Length` counts bytes, not characters. Buffering into a `String`
/// and slicing by `Index` looks correct until the first hover response
/// containing "configuração", at which point every subsequent message is
/// offset and the session is dead. Nothing here ever converts the payload
/// to text; the body is sliced as `Data` and handed to `JSONDecoder`, which
/// does its own UTF-8.
///
/// `Data` indices are not guaranteed to start at zero — a `Data` that has
/// had its prefix removed can keep a non-zero `startIndex`, and a slice
/// always does. Every offset here is therefore computed from
/// `buffer.startIndex` rather than written as a bare integer.
///
/// Not thread-safe: feed it from one queue.
final class LSPMessageDecoder {
    /// Generous for a header block that is realistically under 60 bytes,
    /// small enough that a server writing raw text to stdout is caught
    /// within a few reads instead of buffering forever.
    private static let maxHeaderBytes = 8 * 1024

    /// Semantic tokens for a large file are megabytes, so the ceiling has
    /// to be high; it exists only to stop a corrupt length from being
    /// treated as an allocation request.
    private static let maxBodyBytes = 64 * 1024 * 1024

    private var buffer = Data()

    /// How many bytes are held waiting for the rest of their message. Zero
    /// after a clean run of complete messages.
    var pendingByteCount: Int { buffer.count }

    /// Feeds a chunk and returns every message that became complete because
    /// of it, in arrival order.
    ///
    /// Failures are returned inline rather than thrown, because one corrupt
    /// message is not a reason to stop reading the ones after it — see
    /// `resynchronize`.
    @discardableResult
    func append(_ chunk: Data) -> [Result<LSPMessage, LSPFramingError>] {
        buffer.append(chunk)

        var results: [Result<LSPMessage, LSPFramingError>] = []
        while let result = takeNext() {
            results.append(result)
        }
        return results
    }

    /// Drops everything buffered. For a server that has exited: whatever is
    /// left is a truncated message that will never be completed.
    func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// One pass. Returns nil when the buffer needs more bytes before
    /// anything more can be said about it.
    ///
    /// Every non-nil path consumes at least one byte, which is what keeps
    /// the caller's loop from spinning on a buffer it can't make progress
    /// on.
    private func takeNext() -> Result<LSPMessage, LSPFramingError>? {
        guard let terminator = buffer.range(of: LSPWireFormat.headerTerminator) else {
            guard buffer.count > Self.maxHeaderBytes else { return nil }
            let count = buffer.count
            resynchronize(from: 1)
            return .failure(.headerTooLong(byteCount: count))
        }

        let header = Self.headerText(buffer[buffer.startIndex..<terminator.lowerBound])
        let bodyStart = terminator.upperBound

        guard let declared = Self.contentLength(in: header) else {
            buffer.removeSubrange(buffer.startIndex..<bodyStart)
            resynchronize(from: 0)
            return .failure(.missingContentLength(header: header))
        }

        guard declared <= Self.maxBodyBytes else {
            buffer.removeSubrange(buffer.startIndex..<bodyStart)
            resynchronize(from: 0)
            return .failure(.messageTooLarge(declared: declared))
        }

        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= declared else { return nil }

        let bodyEnd = buffer.index(bodyStart, offsetBy: declared)
        let body = Data(buffer[bodyStart..<bodyEnd])

        do {
            let message = try LSPMessage.decode(body: body)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            return .success(message)
        } catch {
            buffer.removeSubrange(buffer.startIndex..<bodyStart)
            resynchronize(from: 0)
            return .failure(.invalidBody(byteCount: declared, reason: "\(error)"))
        }
    }

    /// Finds the next plausible message boundary and throws away everything
    /// before it.
    ///
    /// This is what stops one wrong `Content-Length` from killing the
    /// session. A count that is too small leaves the tail of its own body in
    /// the buffer; one that is too large swallows the messages that follow.
    /// Either way the fix is the same: the body that failed is *not*
    /// consumed, only the header is, and the search then re-anchors on the
    /// next `Content-Length` — which, for a too-large count, is still
    /// sitting in the buffer untouched.
    ///
    /// The cost is a false positive if a payload happens to contain the
    /// literal text `Content-Length` — a log message quoting an HTTP header
    /// would do it. That only ever happens on a stream already known to be
    /// corrupt, so a wrong guess costs one more discarded message rather
    /// than correctness on a healthy stream.
    ///
    /// When no marker is found the last few bytes are still kept: a header
    /// can be split across reads, and the next chunk may complete the very
    /// marker this pass couldn't see.
    private func resynchronize(from offset: Int) {
        let marker = Data(LSPWireFormat.contentLengthHeader.utf8)
        let searchStart = buffer.index(buffer.startIndex, offsetBy: min(offset, buffer.count))

        if let next = buffer.range(of: marker, in: searchStart..<buffer.endIndex) {
            buffer.removeSubrange(buffer.startIndex..<next.lowerBound)
            return
        }

        let keep = max(0, marker.count - 1)
        guard buffer.count > keep else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.endIndex, offsetBy: -keep))
    }

    /// A header block is ASCII by definition, so bytes that aren't valid
    /// text are already evidence that this isn't a header — reading them as
    /// an empty string sends the block down the `missingContentLength` path
    /// and resynchronizes, which is exactly where it belongs.
    private static func headerText(_ bytes: Data.SubSequence) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Header names are matched case-insensitively and extra headers are
    /// ignored. The spec says `Content-Length` and permits `Content-Type`,
    /// but servers have shipped both other casings and headers of their own
    /// invention, and none of that is a reason to drop a valid message.
    private static func contentLength(in header: String) -> Int? {
        for line in header.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                == LSPWireFormat.contentLengthHeader.lowercased() else { continue }

            guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), length >= 0 else {
                return nil
            }
            return length
        }
        return nil
    }
}
