import Darwin
import Foundation

/// A streaming converter: partial multibyte characters survive read boundaries.
final class SSHEncodingConverter {
    private let descriptor: iconv_t
    private let sourceIsUTF8: Bool
    private let destinationIsUTF8: Bool
    private var pending = Data()

    init(from source: String, to destination: String) throws {
        let converter = iconv_open(destination, source)
        guard converter != iconv_t(bitPattern: -1), let converter else {
            throw SSHError.message("Character conversion from \(source) to \(destination) is not available on this Mac.")
        }
        descriptor = converter
        sourceIsUTF8 = source == "UTF-8"
        destinationIsUTF8 = destination == "UTF-8"
    }

    deinit { iconv_close(descriptor) }

    func finish() -> Data {
        guard !pending.isEmpty else { return Data() }
        pending.removeAll()
        return Data(destinationIsUTF8 ? [0xEF, 0xBF, 0xBD] : [0x3F])
    }

    func convert(_ data: Data) -> Data {
        pending.append(data)
        var result = Data()
        var consumed = 0
        pending.withUnsafeBytes { inputBytes in
            guard let base = inputBytes.baseAddress else { return }
            var input: UnsafeMutablePointer<CChar>? = UnsafeMutableRawPointer(mutating: base).assumingMemoryBound(to: CChar.self)
            var remaining = inputBytes.count
            while remaining > 0 {
                var output = [UInt8](repeating: 0, count: 8192)
                var available = output.count
                let conversion = output.withUnsafeMutableBytes { bytes -> (status: Int, error: Int32) in
                    var pointer: UnsafeMutablePointer<CChar>? = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                    let status = iconv(descriptor, &input, &remaining, &pointer, &available)
                    return (status, errno)
                }
                result.append(contentsOf: output.prefix(output.count - available))
                if conversion.status != -1 { break }
                if conversion.error == E2BIG { continue }
                // A read can end in the middle of a character. Keep it for the next read.
                if conversion.error == EINVAL { break }
                // An unrepresentable input character becomes '?'; malformed remote bytes
                // become the Unicode replacement character without losing later text.
                let first = UInt8(bitPattern: input!.pointee)
                let length: Int
                if sourceIsUTF8 && first >= 0xC2 {
                    length = first < 0xE0 ? 2 : (first < 0xF0 ? 3 : 4)
                } else { length = 1 }
                let skip = min(length, remaining)
                input = input!.advanced(by: skip)
                remaining -= skip
                result.append(contentsOf: destinationIsUTF8 ? [0xEF, 0xBF, 0xBD] : [0x3F])
                _ = iconv(descriptor, nil, nil, nil, nil)
            }
            consumed = inputBytes.count - remaining
        }
        pending.removeFirst(consumed)
        return result
    }
}
