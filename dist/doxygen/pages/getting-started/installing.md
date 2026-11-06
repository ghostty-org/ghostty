# Installing {#installing}

You build libghostty-vt from source with [Zig](https://ziglang.org). You don't
need to know any Zig to do it, and the result is a normal C library. We haven't
tagged a release yet, so for now that means a checkout of `main`.

You need Zig 0.17. The build stops with an error on any other minor version.

If you use CMake, Zig, WebAssembly or Swift, skip to that section. The first two
build the library for you.

## Build from Source {#installing-source}

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Demit-lib-vt -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

This installs the shared library, the static library, the headers, and the
pkg-config and CMake files. In a checkout `-Demit-lib-vt` is required. Without
it, `zig build` builds the Ghostty app.

## pkg-config {#installing-pkg-config}

Save the program from the @ref mainpage "main page" as `hello.c` and build it:

```sh
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig"
cc -o hello hello.c $(pkg-config --cflags --libs libghostty-vt) -Wl,-rpath,"$HOME/.local/lib"
./hello
```

The rpath tells the loader where the shared library is. On macOS you always need
one, because the library loads as `@rpath/libghostty-vt.0.dylib`. On Linux you
can drop it if you install to a directory the loader already searches, such as
`/usr/lib`.

## Static Linking {#installing-static}

Link statically when you want one binary with nothing to install next to it:

```sh
cc -o hello hello.c $(pkg-config --static --cflags --libs libghostty-vt-static)
```

## CMake {#installing-cmake}

CMake can fetch and build the library for you, so you can skip the build above.
You still need `zig` on your `PATH`.

```cmake
include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(ghostty)

add_executable(hello hello.c)
target_link_libraries(hello PRIVATE ghostty-vt)
```

Link `ghostty-vt-static` instead for the static library. If you already
installed the library, use `find_package(ghostty-vt REQUIRED)` and link
`ghostty-vt::ghostty-vt`. Pass `-DCMAKE_PREFIX_PATH="$HOME/.local"` if CMake
can't find it.

See @ref c-vt-cmake/src/main.c "c-vt-cmake" and @ref
c-vt-cmake-static/src/main.c "c-vt-cmake-static". To cross-compile, see @ref
c-vt-cmake-cross/src/main.c "c-vt-cmake-cross" and the
[CMake README](https://github.com/ghostty-org/ghostty/blob/main/dist/cmake/README.md).

## Zig {#installing-zig}

Zig programs can use the Zig module directly, which skips the C API:

```sh
zig fetch --save=ghostty git+https://github.com/ghostty-org/ghostty
```

Then import the module in your `build.zig`:

```zig
if (b.lazyDependency("ghostty", .{})) |dep| {
    exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
}
```

See [zig-vt](https://github.com/ghostty-org/ghostty/tree/main/example/zig-vt).
If your Zig build compiles a C program, use
`exe_mod.linkLibrary(dep.artifact("ghostty-vt"))` instead, as @ref
c-vt-stream/src/main.c "c-vt-stream" does.

## WebAssembly {#installing-wasm}

Run this from the checkout to get `zig-out/bin/ghostty-vt.wasm`:

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

See [wasm-vt](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-vt)
for how to load it from JavaScript, and @ref wasm "WebAssembly" for the
functions that only exist for this build.

## Swift {#installing-swift}

Run this from the checkout on a Mac with Xcode to get
`zig-out/lib/ghostty-vt.xcframework`:

```sh
zig build -Demit-lib-vt -Demit-xcframework=true
```

Add it to your package as a `binaryTarget`, as
[swift-vt-xcframework](https://github.com/ghostty-org/ghostty/tree/main/example/swift-vt-xcframework)
does.

## Build Options {#installing-options}

Most programs don't need any of these. The
[packaging guide](https://github.com/ghostty-org/ghostty/blob/main/PACKAGING-LIBGHOSTTY.md)
has the whole list.

`-Dsimd=false` removes the SIMD code. On Linux that also removes libc: the
shared library then links nothing at all. It makes parsing much slower, so only
do this if libc is what you're trying to avoid. WebAssembly and freestanding
builds are like this already. On macOS the library still links libSystem, like
every program does.

`-Dvt-features` leaves out parts of the library to make it smaller. See @ref
features.
