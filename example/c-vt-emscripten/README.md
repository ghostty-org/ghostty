# Example: `ghostty-vt` with Emscripten

Embed libghostty-vt in an Emscripten application, both statically linked and
loaded with `dlopen`. The example exercises the default allocator and a custom
allocator that returns dirty memory, then checks scrolling, resizing, and
allocation cleanup.

## Usage

Run these commands from the repository root with Zig, Emscripten, Node.js,
and GNU coreutils installed. On Linux, enter the dedicated development shell:

```sh
nix develop .#emscripten
```

Build the library and run both versions of the example:

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-emscripten -Doptimize=fast
bash example/c-vt-emscripten/run.sh zig-out
```

`run.sh` compiles `src/main.c` with `emcc` against the installed archive and
headers, then runs it with Node.js. It also links a side module and tests
loading it dynamically. Temporary build products are removed on exit.
Checks remain active when `NDEBUG` is defined; the script builds with
`-DNDEBUG` to exercise this configuration.

The Emscripten CI job runs this example with both optimized and Debug library
builds. The script enables legacy return-address support when required by the SDK
and a 1 MiB stack for Debug allocator diagnostics.
