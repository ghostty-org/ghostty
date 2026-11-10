# Examples {#example-programs}

Every example is a complete program you can build and run. Each one lives in its
own directory under `example/`, with a README that says how to run it. Most of
them are one `zig build run`. CI compiles all 29 C examples, so they can't fall
behind the API.

If you want to see everything working together, start with
[Ghostling](https://github.com/ghostty-org/ghostling). It's a minimal but
complete terminal built on libghostty-vt.

If you only want to read a terminal's screen, start with @ref
c-vt-stream/src/main.c "c-vt-stream".

## Start Here

| Example                                         | What it does                                                                                                                                                                         |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| @ref c-vt-hello/src/main.c "c-vt-hello"         | The smallest complete program: create a terminal, write text with a color sequence in it, and print the screen. This is the program on the main page.                                |
| @ref c-vt-stream/src/main.c "c-vt-stream"       | Feed VT sequences into a terminal, read the final screen back as plain text, and draw it with a render state. Start here for read-only tools like replay viewers and CI log viewers. |
| @ref c-vt-formatter/src/main.c "c-vt-formatter" | Write text and cursor movement into a terminal, then stream the screen to stdout as plain text through a GhosttyWriter.                                                              |

## Terminal

| Example                                                         | What it does                                                                                                                                                                                                               | Guide                              |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| @ref c-vt-colors/src/main.c "c-vt-colors"                       | Set the default colors and palette, then read effective and default values as an OSC 10 override layers on top.                                                                                                            | @ref guide-colors "Colors"         |
| @ref c-vt-effects/src/main.c "c-vt-effects"                     | Register callbacks for what a program asks of the terminal: pty replies, the bell, title changes, OSC 52 clipboard reads and writes, and unknown sequences. You need these as soon as a real program runs in the terminal. | @ref guide-effects "Effects"       |
| @ref c-vt-compression/src/main.c "c-vt-compression"             | Compress scrollback while the terminal is idle.                                                                                                                                                                            | @ref guide-scrollback "Scrollback" |
| @ref c-vt-snapshot/src/main.c "c-vt-snapshot"                   | Encode a terminal's full state and restore it three ways: in one shot, with scrollback kept compressed, and page by page. The page by page path gives you a terminal you can draw before the old history arrives.          | @ref guide-snapshots "Snapshots"   |
| @ref c-vt-grid-traverse/src/main.c "c-vt-grid-traverse"         | Walk the whole grid cell by cell with grid refs, reading codepoints, row wrap state and styles.                                                                                                                            | @ref guide-grid "The Grid"         |
| @ref c-vt-grid-ref-tracked/src/main.c "c-vt-grid-ref-tracked"   | Keep a reference to one cell while the terminal scrolls under it.                                                                                                                                                          | @ref guide-grid "The Grid"         |
| @ref c-vt-render/src/main.c "c-vt-render"                       | Draw a frame from a render state: check what's dirty, walk the rows and cells, and read styles, colors, the cursor and the selection. Use this when you render the terminal yourself.                                      | @ref guide-rendering "Rendering"   |
| @ref c-vt-search/src/main.c "c-vt-search"                       | Search the terminal for a string, step through the matches like a find bar, and read the viewport matches to draw highlights.                                                                                              | @ref guide-search "Search"         |
| @ref c-vt-selection/src/main.c "c-vt-selection"                 | Select a word, a line, a command's output or the whole screen, then format each selection as text. The line and output selections use OSC 133 prompt markers.                                                              | @ref guide-selection "Selection"   |
| @ref c-vt-selection-gesture/src/main.c "c-vt-selection-gesture" | Feed press, drag, release and deep press events to ghostty_selection_gesture_event() and get back selections you can show or copy.                                                                                         | @ref guide-selection "Selection"   |
| @ref c-vt-kitty-graphics/src/main.c "c-vt-kitty-graphics"       | Accept images sent with the Kitty Graphics Protocol and find out what to draw. It installs a stand-in PNG decoder, reads placements from the render state, and plays an animation.                                         | @ref guide-images "Images"         |

## Input

| Example                                               | What it does                                                                                                                                                                                                                            | Guide                    |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| @ref c-vt-encode-key/src/main.c "c-vt-encode-key"     | Encode Ctrl+C as an escape sequence with the Kitty keyboard protocol.                                                                                                                                                                   | @ref guide-input "Input" |
| @ref c-vt-encode-mouse/src/main.c "c-vt-encode-mouse" | Encode a left button press at a pixel position as an SGR mouse sequence.                                                                                                                                                                | @ref guide-input "Input" |
| @ref c-vt-encode-focus/src/main.c "c-vt-encode-focus" | Encode a focus gained event as CSI I, for programs that turn on focus reporting (mode 1004).                                                                                                                                            | @ref guide-input "Input" |
| @ref c-vt-paste/src/main.c "c-vt-paste"               | Paste into a terminal with ghostty_terminal_paste(): plain text, bracketed paste (mode 2004), the unsafe-paste confirmation, and Kitty paste events (mode 5522). It also checks paste safety and encodes paste data without a terminal. | @ref guide-input "Input" |

## Building Blocks

| Example                                               | What it does                                                                                                                          | Guide                      |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| @ref c-vt-osc/src/main.c "c-vt-osc"                   | Parse an OSC sequence and read the window title out of it.                                                                            |                            |
| @ref c-vt-sgr/src/main.c "c-vt-sgr"                   | Parse SGR sequences into text attributes, including a real one from Kakoune with a curly underline and RGB colors.                    |                            |
| @ref c-vt-modes/src/main.c "c-vt-modes"               | Pack DEC and ANSI mode numbers into a GhosttyMode and encode a DECRPM report.                                                         |                            |
| @ref c-vt-color-scheme/src/main.c "c-vt-color-scheme" | Encode a color scheme report, the reply to a CSI ? 996 n query.                                                                       | @ref guide-colors "Colors" |
| @ref c-vt-size-report/src/main.c "c-vt-size-report"   | Encode an in-band size report (mode 2048) from the grid and cell size.                                                                |                            |
| @ref c-vt-allocator/src/main.c "c-vt-allocator"       | Run a terminal on your own allocator, built on `malloc` and `free`. It counts live bytes to check that the terminal frees everything. |                            |
| @ref c-vt-build-info/src/main.c "c-vt-build-info"     | Query build options like SIMD and Kitty graphics, then check that the loaded library matches the headers you compiled against.        |                            |

## Build Systems

| Example                                               | What it does                                                                                                                                    |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| @ref c-vt-cmake/src/main.c "c-vt-cmake"               | Build and link libghostty-vt from a CMake project with `FetchContent`.                                                                          |
| @ref c-vt-cmake-static/src/main.c "c-vt-cmake-static" | Build and statically link libghostty-vt from a CMake project with `FetchContent`.                                                               |
| @ref c-vt-cmake-cross/src/main.c "c-vt-cmake-cross"   | Cross-compile and statically link libghostty-vt from CMake with `ghostty_vt_add_target()`. The default target is a different OS from your host. |
| @ref c-vt-static/src/main.c "c-vt-static"             | Statically link libghostty-vt from a Zig build with the `ghostty-vt-static` artifact. The program is the same as c-vt-osc.                      |

## Other Languages

These aren't C, so they have no page here. Each link goes to the directory in
the repo.

| Example                                                                                               | Language    | What it does                                                                                                                                  |
| ----------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| [zig-vt](https://github.com/ghostty-org/ghostty/tree/main/example/zig-vt)                             | Zig         | Create a terminal with the `ghostty-vt` Zig module, write text that wraps at 6 columns, and print the screen as plain text.                   |
| [zig-vt-stream](https://github.com/ghostty-org/ghostty/tree/main/example/zig-vt-stream)               | Zig         | Parse VT sequences with the `vtStream` API. This is the Zig version of c-vt-stream, for the same read-only tools.                             |
| [zig-formatter](https://github.com/ghostty-org/ghostty/tree/main/example/zig-formatter)               | Zig         | Read VT sequences from stdin and write styled HTML with `TerminalFormatter`.                                                                  |
| [cpp-vt-stream](https://github.com/ghostty-org/ghostty/tree/main/example/cpp-vt-stream)               | C++         | A small C++ port of c-vt-stream. libghostty-vt is a C library, and this is how CI checks that it also compiles from C++.                      |
| [swift-vt-xcframework](https://github.com/ghostty-org/ghostty/tree/main/example/swift-vt-xcframework) | Swift       | Use the pre-built XCFramework from a Swift Package. It creates a terminal, writes VT sequences into it, and formats the screen as plain text. |
| [wasm-vt](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-vt)                           | WebAssembly | Run a terminal in a browser page from JavaScript: write VT sequences into it and format the screen as plain text.                             |
| [wasm-key-encode](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-key-encode)           | WebAssembly | Encode key events into escape sequences from JavaScript in a browser page.                                                                    |
| [wasm-sgr](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-sgr)                         | WebAssembly | Parse SGR sequences into text attributes from JavaScript in a browser page.                                                                   |
