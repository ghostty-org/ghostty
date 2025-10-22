# WebAssembly Key Encoder Example

This example demonstrates how to use the Ghostty VT library from WebAssembly to encode key events into terminal escape sequences.

## What It Does

The example demonstrates using the Ghostty VT library from WebAssembly to encode key events:

1. Loads the `ghostty-vt.wasm` module
2. Creates a key encoder with Kitty keyboard protocol support
3. Creates a key event for left ctrl release
4. Queries the required buffer size (optional)
5. Encodes the event into a terminal escape sequence
6. Displays the result in both hexadecimal and string format

## Building

First, build the WebAssembly module:

```bash
zig build lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

This will create `zig-out/bin/ghostty-vt.wasm`.

## Running

**Important:** You must serve this via HTTP, not open it as a file directly. Browsers block loading WASM files from `file://` URLs.

From the **root of the ghostty repository**, serve with a local HTTP server:

```bash
# Using Python (recommended)
python3 -m http.server 8000

# Or using Node.js
npx serve .

# Or using PHP
php -S localhost:8000
```

Then open your browser to:

```
http://localhost:8000/example/wasm-key-encode/
```

Click "Run Example" to see the key encoding in action.

## Expected Output

```
Encoding event: left ctrl release with all Kitty flags enabled
Required buffer size: 12 bytes
Encoded 12 bytes
Hex: 1b 5b 35 37 3a 33 3b 32 3a 33 75
String: \x1b[57:3;2:3u
```

## Notes

- The example uses the convenience allocator functions exported by the wasm module
- Error handling is included to demonstrate proper usage patterns
- The encoded sequence `\x1b[57:3;2:3u` is a Kitty keyboard protocol sequence for left ctrl release with all features enabled
- The `env.log` function must be provided by the host environment for logging support

## Current Limitations

The current C API is verbose when called from WebAssembly because:

- Functions use output pointers requiring manual memory allocation in JavaScript
- Options must be set via pointers to values
- Buffer sizes require pointer parameters

See `WASM_API_PLAN.md` for proposed improvements to make the API more wasm-friendly.
