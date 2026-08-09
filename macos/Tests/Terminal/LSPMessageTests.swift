import Foundation
@testable import Ghostty
import Testing

/// `LSPMessageDecoder` against the way a pipe actually delivers bytes.
///
/// Every fixture here is framed by hand rather than by the encoder, because
/// the bugs this guards against are all in the arithmetic between two
/// messages — a header split across reads, a length counted in characters
/// instead of bytes — and a test that encoded with the same code it decodes
/// with would agree with itself about all of them.
struct LSPMessageTests {
    // MARK: Helpers

    /// Frames a body the long way round, so the header is written by the
    /// test rather than by the code under test.
    private func framed(_ json: String) -> Data {
        let body = Data(json.utf8)
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private func messages(_ results: [Result<LSPMessage, LSPFramingError>]) -> [LSPMessage] {
        results.compactMap { try? $0.get() }
    }

    private func methods(_ results: [Result<LSPMessage, LSPFramingError>]) -> [String] {
        messages(results).map { message in
            switch message {
            case .request(let request): return request.method
            case .notification(let notification): return notification.method
            case .response: return "response"
            }
        }
    }

    private func failures(_ results: [Result<LSPMessage, LSPFramingError>]) -> [LSPFramingError] {
        results.compactMap { result in
            guard case .failure(let error) = result else { return nil }
            return error
        }
    }

    // MARK: Whole messages

    @Test func decodesASingleCompleteMessage() throws {
        let decoder = LSPMessageDecoder()
        let results = decoder.append(framed(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))

        #expect(results.count == 1)
        let message = try #require(messages(results).first)
        guard case .request(let request) = message else {
            Issue.record("expected a request, got \(message)")
            return
        }
        #expect(request.method == "initialize")
        #expect(request.id == LSPRequestID.number(1))
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func aMessageWithNoIdIsANotification() throws {
        let decoder = LSPMessageDecoder()
        let results = decoder.append(framed(
            #"{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"uri":"file:///a.ts"}}"#
        ))

        let message = try #require(messages(results).first)
        guard case .notification(let notification) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }
        #expect(notification.method == "textDocument/didOpen")
        #expect(notification.params?["uri"]?.stringValue == "file:///a.ts")
    }

    @Test func aMessageWithAResultIsAResponse() throws {
        let decoder = LSPMessageDecoder()
        let results = decoder.append(framed(#"{"jsonrpc":"2.0","id":7,"result":{"capabilities":{}}}"#))

        let message = try #require(messages(results).first)
        guard case .response(let response) = message else {
            Issue.record("expected a response, got \(message)")
            return
        }
        #expect(response.id == LSPRequestID.number(7))
        #expect(response.isSuccess)
    }

    @Test func anErrorResponseKeepsCodeAndMessage() throws {
        let decoder = LSPMessageDecoder()
        let results = decoder.append(framed(
            #"{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"Unhandled method: foo"}}"#
        ))

        let message = try #require(messages(results).first)
        guard case .response(let response) = message else {
            Issue.record("expected a response, got \(message)")
            return
        }
        #expect(!response.isSuccess)
        #expect(response.error?.code == -32601)
        #expect(response.error?.message == "Unhandled method: foo")
    }

    /// A server may answer with a string id, and the pending-request table
    /// keys on the id exactly as it arrived — coercing `"7"` to `7` would
    /// hand one caller another's reply.
    @Test func stringIdsStayStrings() throws {
        let decoder = LSPMessageDecoder()
        let results = decoder.append(framed(#"{"jsonrpc":"2.0","id":"7","result":null}"#))

        let message = try #require(messages(results).first)
        guard case .response(let response) = message else {
            Issue.record("expected a response, got \(message)")
            return
        }
        #expect(response.id == LSPRequestID.string("7"))
        #expect(response.result == LSPValue.null)
    }

    // MARK: Chunking

    /// The whole reason the decoder exists: one message can arrive as any
    /// number of reads, and nothing may be emitted until the last byte of
    /// it has.
    @Test func aMessageSplitAcrossManyChunksReassembles() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":null}}"#)

        var emitted: [Result<LSPMessage, LSPFramingError>] = []
        for byte in whole {
            emitted += decoder.append(Data([byte]))
        }

        #expect(emitted.count == 1)
        #expect(methods(emitted) == ["initialize"])
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func nothingIsEmittedUntilTheBodyIsComplete() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","method":"a"}"#)

        let head = decoder.append(whole.prefix(whole.count - 1))
        #expect(head.isEmpty)
        #expect(decoder.pendingByteCount == whole.count - 1)

        let tail = decoder.append(whole.suffix(1))
        #expect(methods(tail) == ["a"])
        #expect(decoder.pendingByteCount == 0)
    }

    /// The split that is easiest to miss: the header is not a unit either,
    /// and `Content-Le` followed by `ngth: 30` is an ordinary pair of reads.
    @Test func aHeaderSplitMidContentLengthReassembles() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","method":"b"}"#)

        let cut = 10
        #expect(String(bytes: whole.prefix(cut), encoding: .utf8) == "Content-Le")

        #expect(decoder.append(whole.prefix(cut)).isEmpty)
        #expect(methods(decoder.append(whole.dropFirst(cut))) == ["b"])
        #expect(decoder.pendingByteCount == 0)
    }

    /// And the split inside the number itself, which silently changes the
    /// declared length if the two halves are ever parsed independently.
    @Test func aHeaderSplitInsideTheNumberReassembles() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","method":"cc"}"#)

        let cut = 17
        #expect(String(bytes: whole.prefix(cut), encoding: .utf8) == "Content-Length: 3")

        #expect(decoder.append(whole.prefix(cut)).isEmpty)
        #expect(methods(decoder.append(whole.dropFirst(cut))) == ["cc"])
    }

    @Test func aChunkSplitInsideTheHeaderTerminatorReassembles() throws {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","method":"d"}"#)
        let terminator = try #require(whole.range(of: Data("\r\n\r\n".utf8)))

        let cut = terminator.lowerBound + 2
        #expect(decoder.append(whole.prefix(cut)).isEmpty)
        #expect(methods(decoder.append(whole.dropFirst(cut))) == ["d"])
    }

    // MARK: Several messages per chunk

    @Test func severalMessagesInOneChunkAllEmitInOrder() {
        let decoder = LSPMessageDecoder()
        var chunk = Data()
        chunk.append(framed(#"{"jsonrpc":"2.0","method":"first"}"#))
        chunk.append(framed(#"{"jsonrpc":"2.0","method":"second"}"#))
        chunk.append(framed(#"{"jsonrpc":"2.0","method":"third"}"#))

        let results = decoder.append(chunk)

        #expect(methods(results) == ["first", "second", "third"])
        #expect(decoder.pendingByteCount == 0)
    }

    /// The realistic shape of a busy read: whole messages followed by the
    /// beginning of one more. The partial one has to be held, not dropped,
    /// and must not be emitted twice when its tail arrives.
    @Test func completeMessagesEmitAndTheTrailingPartialIsHeld() {
        let decoder = LSPMessageDecoder()
        var stream = Data()
        stream.append(framed(#"{"jsonrpc":"2.0","method":"one"}"#))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"two"}"#))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"three"}"#))
        let fourth = framed(#"{"jsonrpc":"2.0","method":"four"}"#)
        stream.append(fourth.prefix(11))

        let first = decoder.append(stream)
        #expect(methods(first) == ["one", "two", "three"])
        #expect(decoder.pendingByteCount == 11)

        let rest = decoder.append(fourth.dropFirst(11))
        #expect(methods(rest) == ["four"])
        #expect(decoder.pendingByteCount == 0)
    }

    /// Arbitrary chunking of an arbitrary number of messages: nothing lost,
    /// nothing duplicated, order preserved.
    @Test func chunkingAtEveryBoundaryNeverLosesOrDuplicatesAMessage() {
        var stream = Data()
        let expected = (0..<12).map { "method\($0)" }
        for method in expected {
            stream.append(framed(#"{"jsonrpc":"2.0","method":"\#(method)"}"#))
        }

        for size in [1, 3, 7, 16, 64, 4096] {
            let decoder = LSPMessageDecoder()
            var emitted: [Result<LSPMessage, LSPFramingError>] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + size, stream.count)
                emitted += decoder.append(stream[stream.startIndex + offset..<stream.startIndex + end])
                offset = end
            }

            #expect(methods(emitted) == expected, "chunk size \(size)")
            #expect(decoder.pendingByteCount == 0, "chunk size \(size)")
        }
    }

    // MARK: Bytes versus characters

    /// `Content-Length` is a byte count. A decoder that buffers into a
    /// `String` and slices by `Index` reads one byte too few for every
    /// non-ASCII character, and from that point on every message is offset
    /// by a little more than the last.
    @Test func multiByteUTF8ContentSurvivesIntact() throws {
        let decoder = LSPMessageDecoder()
        let text = "configuração não pôde ser lida — ação inválida"
        let json = #"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"\#(text)"}}"#

        #expect(Data(json.utf8).count > json.count)

        let results = decoder.append(framed(json))

        let message = try #require(messages(results).first)
        guard case .notification(let notification) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }
        #expect(notification.params?["message"]?.stringValue == text)
        #expect(decoder.pendingByteCount == 0)
    }

    /// The same, with a second message behind it — the offset a character
    /// count introduces only becomes visible as corruption of whatever came
    /// next.
    @Test func aMessageAfterMultiByteContentIsStillAligned() {
        let decoder = LSPMessageDecoder()
        var stream = Data()
        stream.append(framed(#"{"jsonrpc":"2.0","method":"log","params":{"message":"ação — 日本語 🇧🇷"}}"#))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"after"}"#))

        let results = decoder.append(stream)

        #expect(methods(results) == ["log", "after"])
        #expect(decoder.pendingByteCount == 0)
    }

    /// A multi-byte character split across two reads is the same problem
    /// one level down: the halves are not valid UTF-8 on their own, so
    /// anything that turns bytes into text before it has the whole body
    /// corrupts it.
    @Test func aMultiByteCharacterSplitAcrossChunksIsNotCorrupted() throws {
        let decoder = LSPMessageDecoder()
        let text = "ação"
        let whole = framed(#"{"jsonrpc":"2.0","method":"log","params":{"message":"\#(text)"}}"#)
        let marker = try #require(whole.range(of: Data("ç".utf8)))

        let cut = marker.lowerBound + 1
        #expect(decoder.append(whole.prefix(cut)).isEmpty)

        let results = decoder.append(whole.dropFirst(cut))
        let message = try #require(messages(results).first)
        guard case .notification(let notification) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }
        #expect(notification.params?["message"]?.stringValue == text)
    }

    // MARK: Bad framing

    /// A length shorter than the body leaves the tail of that body in the
    /// stream. The message is lost — it has to be — but the decoder has to
    /// find the next header rather than spend the rest of the session
    /// reading one message's body as another's header.
    @Test func aContentLengthShorterThanTheBodyDoesNotDesyncTheStream() {
        let decoder = LSPMessageDecoder()

        var stream = Data("Content-Length: 10\r\n\r\n".utf8)
        stream.append(Data(#"{"jsonrpc":"2.0","method":"lied-about"}"#.utf8))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"recovered"}"#))

        let results = decoder.append(stream)

        #expect(methods(results) == ["recovered"])
        #expect(failures(results).count == 1)
        #expect(decoder.pendingByteCount == 0)
    }

    /// A length longer than the body swallows whatever follows it, so
    /// recovery can only happen once enough bytes have arrived for the
    /// decoder to look at the claim at all. It has to happen then, and the
    /// messages sitting past the bad slice have to survive it.
    @Test func aContentLengthLongerThanTheBodyRecoversOnceMoreBytesArrive() {
        let decoder = LSPMessageDecoder()
        let padding = String(repeating: "x", count: 400)

        var stream = Data("Content-Length: 300\r\n\r\n".utf8)
        stream.append(Data(#"{"jsonrpc":"2.0","method":"truncated"}"#.utf8))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"recovered","params":{"pad":"\#(padding)"}}"#))

        let results = decoder.append(stream)

        #expect(methods(results) == ["recovered"])
        #expect(failures(results).count == 1)
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func aHeaderWithoutContentLengthIsReportedAndSkipped() throws {
        let decoder = LSPMessageDecoder()
        var stream = Data("Content-Type: application/vscode-jsonrpc\r\n\r\n".utf8)
        stream.append(framed(#"{"jsonrpc":"2.0","method":"after"}"#))

        let results = decoder.append(stream)

        #expect(methods(results) == ["after"])
        let failure = try #require(failures(results).first)
        guard case .missingContentLength = failure else {
            Issue.record("expected a missing Content-Length failure, got \(failure)")
            return
        }
    }

    @Test func aBodyThatIsNotJSONIsReportedAndTheNextMessageStillArrives() throws {
        let decoder = LSPMessageDecoder()
        var stream = Data("Content-Length: 12\r\n\r\n".utf8)
        stream.append(Data("not json at!".utf8))
        stream.append(framed(#"{"jsonrpc":"2.0","method":"after"}"#))

        let results = decoder.append(stream)

        #expect(methods(results) == ["after"])
        let failure = try #require(failures(results).first)
        guard case .invalidBody = failure else {
            Issue.record("expected an invalid body failure, got \(failure)")
            return
        }
    }

    /// Servers print things to stdout that were meant for a log. That is
    /// noise, not the end of the session.
    @Test func garbageBeforeAValidMessageIsSkipped() {
        let decoder = LSPMessageDecoder()
        var stream = Data("[Info  - 10:02:11] Connection established\r\n".utf8)
        stream.append(framed(#"{"jsonrpc":"2.0","method":"after"}"#))

        #expect(methods(decoder.append(stream)) == ["after"])
    }

    @Test func extraHeadersAndOddCasingAreTolerated() {
        let decoder = LSPMessageDecoder()
        let body = Data(#"{"jsonrpc":"2.0","method":"tolerated"}"#.utf8)
        var stream = Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n".utf8)
        stream.append(Data("content-length: \(body.count)\r\n\r\n".utf8))
        stream.append(body)

        #expect(methods(decoder.append(stream)) == ["tolerated"])
    }

    @Test func anEmptyChunkChangesNothing() {
        let decoder = LSPMessageDecoder()
        #expect(decoder.append(Data()).isEmpty)
        #expect(decoder.pendingByteCount == 0)
        #expect(methods(decoder.append(framed(#"{"jsonrpc":"2.0","method":"a"}"#))) == ["a"])
    }

    @Test func resetDropsAnIncompleteMessage() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","method":"a"}"#)

        #expect(decoder.append(whole.prefix(whole.count - 3)).isEmpty)
        decoder.reset()
        #expect(decoder.pendingByteCount == 0)
        #expect(decoder.append(whole.suffix(3)).isEmpty)
    }

    // MARK: Encoding

    @Test func encodingFramesTheBodyWithItsByteCount() throws {
        let message = LSPMessage.notification(LSPNotification(
            method: "window/logMessage",
            params: ["message": "ação"]
        ))

        let data = try message.encoded()
        let body = try message.encodedBody()
        let terminator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        let header = try #require(String(bytes: data[data.startIndex..<terminator.lowerBound], encoding: .utf8))

        #expect(header == "Content-Length: \(body.count)")
        #expect(data.count == header.utf8.count + 4 + body.count)
        #expect(body.count > #"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"ação"}}"#.count)
    }

    @Test func encodeThenDecodeRoundTripsARequest() throws {
        let decoder = LSPMessageDecoder()
        let original = LSPMessage.request(LSPRequest(
            id: .number(42),
            method: "textDocument/completion",
            params: [
                "textDocument": ["uri": "file:///Users/someone/Projeto/índice.ts"],
                "position": ["line": 12, "character": 4],
                "context": ["triggerKind": 1, "triggerCharacter": "."]
            ]
        ))

        let results = decoder.append(try original.encoded())

        #expect(results.count == 1)
        #expect(messages(results) == [original])
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func encodeThenDecodeRoundTripsANotificationAndAResponse() throws {
        let decoder = LSPMessageDecoder()
        let notification = LSPMessage.notification(LSPNotification(
            method: "textDocument/didChange",
            params: ["contentChanges": [["text": "let x = \"olá\"\n"]]]
        ))
        let response = LSPMessage.response(LSPResponse(
            id: .string("req-1"),
            result: ["items": [], "isIncomplete": false]
        ))

        var stream = Data()
        stream.append(try notification.encoded())
        stream.append(try response.encoded())

        #expect(messages(decoder.append(stream)) == [notification, response])
    }

    /// `"result": null` is a successful answer — it is what `shutdown`
    /// returns — and must not come back as an absent result, which is what
    /// an error response looks like.
    @Test func aNullResultRoundTripsAsNullRatherThanAbsent() throws {
        let decoder = LSPMessageDecoder()
        let original = LSPMessage.response(LSPResponse(id: .number(3), result: .null))

        let results = decoder.append(try original.encoded())
        let message = try #require(messages(results).first)
        guard case .response(let decoded) = message else {
            Issue.record("expected a response, got \(message)")
            return
        }

        #expect(decoded.result == LSPValue.null)
        #expect(decoded.isSuccess)
        #expect(message == original)
    }

    @Test func encodingAlwaysStampsTheProtocolVersion() throws {
        let body = try LSPMessage.notification(LSPNotification(method: "exit")).encodedBody()
        let text = try #require(String(bytes: body, encoding: .utf8))

        #expect(text.contains(#""jsonrpc":"2.0""#))
    }

    /// Integers must not come back as floats: every position, offset and id
    /// in LSP is an integer, and a server sent `12.0` where the
    /// specification says `12` is within its rights to reject the call.
    @Test func integersSurviveARoundTripAsIntegers() throws {
        let decoder = LSPMessageDecoder()
        let original = LSPMessage.notification(LSPNotification(
            method: "n",
            params: ["line": 12, "ratio": 0.5, "big": .integer(Int(Int32.max))]
        ))

        let results = decoder.append(try original.encoded())
        let message = try #require(messages(results).first)
        guard case .notification(let decoded) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }

        #expect(decoded.params?["line"] == LSPValue.integer(12))
        #expect(decoded.params?["ratio"] == LSPValue.double(0.5))
        #expect(decoded.params?["big"] == LSPValue.integer(Int(Int32.max)))
    }

    @Test func nestedValuesAreReadableThroughSubscripts() {
        let value: LSPValue = ["a": ["b": [1, 2, 3]]]

        #expect(value["a"]?["b"]?[1] == LSPValue.integer(2))
        #expect(value["a"]?["b"]?.arrayValue?.count == 3)
        #expect(value["missing"] == nil)
    }
}
