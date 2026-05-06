import Foundation
import GhosttyVt

// Create a terminal with a small grid
var terminal: GhosttyTerminal?
var opts = GhosttyTerminalOptions(
    cols: 80,
    rows: 24,
    max_scrollback: 0
)
let result = ghostty_terminal_new(nil, &terminal, opts)
guard result == GHOSTTY_SUCCESS, let terminal else {
    fatalError("Failed to create terminal")
}

// Write some VT-encoded content
let text = "Hello from \u{1b}[1mSwift\u{1b}[0m via xcframework!\r\n"
text.withCString { ptr in
    ghostty_terminal_vt_write(terminal, ptr, strlen(ptr))
}

// Format the terminal contents as plain text
var fmtOpts = GhosttyFormatterTerminalOptions()
fmtOpts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
fmtOpts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
fmtOpts.trim = true

var formatter: GhosttyFormatter?
let fmtResult = ghostty_formatter_terminal_new(nil, &formatter, terminal, fmtOpts)
guard fmtResult == GHOSTTY_SUCCESS, let formatter else {
    fatalError("Failed to create formatter")
}

var buf: UnsafeMutablePointer<UInt8>?
var len: Int = 0
let allocResult = ghostty_formatter_format_alloc(formatter, nil, &buf, &len)
guard allocResult == GHOSTTY_SUCCESS, let buf else {
    fatalError("Failed to format")
}

print("Plain text (\(len) bytes):")
let data = Data(bytes: buf, count: len)
print(String(data: data, encoding: .utf8) ?? "<invalid UTF-8>")

ghostty_free(nil, buf, len)
ghostty_formatter_free(formatter)
ghostty_terminal_free(terminal)
