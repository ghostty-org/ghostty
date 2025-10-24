# WebAssembly Key Encoder Example

This example demonstrates how to use the Ghostty VT library from WebAssembly
to encode key events into terminal escape sequences.

## Building

First, build the WebAssembly module:

```bash
zig build lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

This will create `zig-out/bin/ghostty-vt.wasm`.

## Running

**Important:** You must serve this via HTTP, not open it as a file directly.
Browsers block loading WASM files from `file://` URLs.

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

Focus the text input field and press any key combination to see the encoded output.
