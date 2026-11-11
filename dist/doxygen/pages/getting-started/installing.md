# Installing {#installing}

libghostty-vt is a normal C library. There are several official ways to get it:

- **Source:** @ref installing-source "build it from source" and link it
  with @ref installing-pkg-config "pkg-config".
- **CMake:** @ref installing-cmake "let CMake fetch and build it" for you.
- **Zig:** @ref installing-zig "add it as a dependency".
- **Windows:** download the prebuilt @ref installing-windows "DLL and static
  library".
- **Swift or another Apple project:** download the prebuilt @ref
  installing-swift "XCFramework".
- **The web or JavaScript:** download the prebuilt @ref installing-wasm
  "WebAssembly module".
- **Nix:** @ref installing-nix "use our flake".

We don't publish prebuilt packages for Linux or FreeBSD. On those systems, you
build from source or use your system's package if it has one.

Every method that builds the library needs [Zig](https://ziglang.org) 0.17. You
don't need to know any Zig to do it. The build stops with an error on any other
minor version. Different libghostty-vt versions may require different Zig
versions, the Zig version is not part of our ABI promise.

## Release Files {#installing-releases}

libghostty-vt is released separately from Ghostty, with its own version numbers
and its own `vt-X.Y.Z` tags. Each release is published to one directory:

```
https://release.files.ghostty.org/libghostty-vt/VERSION/
```

`VERSION` is the version number with no prefix, such as `1.0.1`. The directory
has the following files:

| File                                         | Contents                                  |
| -------------------------------------------- | ----------------------------------------- |
| `libghostty-vt-VERSION.tar.gz`               | Source tarball                            |
| `libghostty-vt-VERSION-deps.tar.gz`          | Zig packages for building with no network |
| `libghostty-vt-VERSION-docs.zip`             | This documentation as HTML                |
| `ghostty-vt-VERSION-x86_64-windows-gnu.zip`  | DLL and static library for Windows x86_64 |
| `ghostty-vt-VERSION-aarch64-windows-gnu.zip` | DLL and static library for Windows arm64  |
| `ghostty-vt-VERSION.xcframework.zip`         | Static libraries for macOS and iOS        |
| `ghostty-vt-VERSION.wasm`                    | WebAssembly module, optimized for speed   |
| `ghostty-vt-VERSION-small.wasm`              | WebAssembly module, optimized for size    |
| `SHA256SUMS`                                 | Checksums of all of the above             |

**Verifying a download:** every file has a
[minisign](https://jedisct1.github.io/minisign/) signature next to it, with a
`.minisig` extension. Check `SHA256SUMS` against our public key, then check your
files against `SHA256SUMS`:

```sh
minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV -m SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

**Trying unreleased code:** the
[tip release](https://github.com/ghostty-org/ghostty/releases/tag/tip) has a
source tarball, an XCFramework and the WebAssembly modules built from the latest
commit to `main`. They change with every commit, so don't ship them.

## Swift and Apple Platforms {#installing-swift}

The XCFramework has static libraries for macOS (arm64 and x86_64), iOS, and the
iOS simulator, along with the headers and a module map. Add it to your package
as a `binaryTarget`:

```swift
.binaryTarget(
    name: "GhosttyVt",
    url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
    checksum: "<sha256 of the zip>"
),
```

The checksum is the line for the zip in `SHA256SUMS`. Depend on `GhosttyVt` from
your target, then `import GhosttyVt` to call the C API from Swift. In an Xcode
project, unzip it and add `ghostty-vt.xcframework` to your target instead.

To build it yourself, run this from a checkout on a Mac with Xcode to get
`zig-out/lib/ghostty-vt.xcframework`:

```sh
zig build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast
```

See
[swift-vt-xcframework](https://github.com/ghostty-org/ghostty/tree/main/example/swift-vt-xcframework)
for a full example.

## WebAssembly {#installing-wasm}

We publish two builds of the WebAssembly module, and both have every feature
enabled:

- **`ghostty-vt-VERSION-small.wasm`:** optimized for size. Use this one on the
  web unless you've measured a reason not to.
- **`ghostty-vt-VERSION.wasm`:** optimized for speed. It's 10-20% faster on
  workloads heavy in escape sequences, and somewhat larger.

To build it yourself, for example to leave out features and make it smaller, run
this from a checkout to get `zig-out/bin/ghostty-vt.wasm`:

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

See [wasm-vt](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-vt)
for how to load it from JavaScript, and @ref wasm "WebAssembly" for the
functions that only exist for this build.

## Windows {#installing-windows}

We publish a zip for Windows x86_64 and arm64. Both are built for the
gnu ABI, and MSVC, clang and mingw programs can all link them. We test the
x86_64 zip at release. The arm64 zip is built the same way, in CI and at
release, but never run.

Download and verify the zip, then unzip it:

```powershell
curl.exe -LO https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1-x86_64-windows-gnu.zip
curl.exe -LO https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1-x86_64-windows-gnu.zip.minisig
minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV -m ghostty-vt-1.0.1-x86_64-windows-gnu.zip
Expand-Archive ghostty-vt-1.0.1-x86_64-windows-gnu.zip -DestinationPath .
```

It unpacks to one directory named after the zip. `bin/` has `ghostty-vt.dll`
and its `ghostty-vt.pdb`, `lib/` has the import library `ghostty-vt.lib` and the
static library `ghostty-vt-static.lib`, and `include/` has the headers. `lib/`
also has the CMake and pkg-config files.

Point CMake at that directory and link the DLL:

```cmake
find_package(ghostty-vt CONFIG REQUIRED)
target_link_libraries(hello PRIVATE ghostty-vt::ghostty-vt)
```

```powershell
cmake -B build -DCMAKE_PREFIX_PATH=C:/path/to/ghostty-vt-1.0.1-x86_64-windows-gnu
```

Without CMake, compile with the `include` directory and link
`lib/ghostty-vt.lib`, such as `cl /I include hello.c lib\ghostty-vt.lib`.

**At run time,** `ghostty-vt.dll` must be on `PATH` or next to your `.exe`.
It only imports ntdll, kernel32 and the Universal C Runtime, so there is no
redistributable to install. Keep `ghostty-vt.pdb` next to the DLL so stack
traces show function names.

**The static library** works with clang, mingw and Zig, but not with MSVC's
`link.exe`, which rejects some of its symbols and sections. With MSVC, use the
DLL. The CMake target `ghostty-vt::ghostty-vt-static` and
`libghostty-vt-static.pc` define `GHOSTTY_STATIC` for you. If you call the
compiler yourself, define it, or the headers declare every function as imported
from the DLL. Also link ntdll:

```powershell
clang -DGHOSTTY_STATIC -I include hello.c lib\ghostty-vt-static.lib -lntdll -o hello.exe
```

To build it yourself, run this from a checkout to get the same files in
`zig-out/`:

```sh
zig build -Demit-lib-vt -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

## CMake {#installing-cmake}

CMake can fetch and build the library for you, so you can skip the build below.
You still need `zig` on your `PATH`.

```cmake
include(FetchContent)
FetchContent_Declare(ghostty
    URL https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz
    URL_HASH SHA256=<sha256 of the tarball>
)
FetchContent_MakeAvailable(ghostty)

add_executable(hello hello.c)
target_link_libraries(hello PRIVATE ghostty-vt)
```

The hash is the line for the tarball in `SHA256SUMS`. Link `ghostty-vt-static`
instead for the static library.

If you already installed the library, use `find_package(ghostty-vt REQUIRED)`
and link `ghostty-vt::ghostty-vt`. Pass `-DCMAKE_PREFIX_PATH="$HOME/.local"` if
CMake can't find it.

See @ref c-vt-cmake/src/main.c "c-vt-cmake" and @ref
c-vt-cmake-static/src/main.c "c-vt-cmake-static". To cross-compile, see @ref
c-vt-cmake-cross/src/main.c "c-vt-cmake-cross" and the
[CMake README](https://github.com/ghostty-org/ghostty/blob/main/dist/cmake/README.md).

## Zig {#installing-zig}

Zig programs can use the Zig module directly, which skips the C API:

```sh
zig fetch --save=ghostty https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz
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

## Nix {#installing-nix}

Our flake has a `libghostty-vt` package, built with `ReleaseFast`:

```sh
nix build 'github:ghostty-org/ghostty/vt-1.0.1#libghostty-vt^*'
```

The `^*` builds every output. The default output has the shared library, and the
`dev` output has the headers, the static library, and the pkg-config and CMake
files.

## Build from Source {#installing-source}

Download a source tarball and build it:

```sh
curl -LO https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz
tar -xzf libghostty-vt-1.0.1.tar.gz
cd libghostty-vt-1.0.1
zig build -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

This installs the shared library, the static library, the headers, and the
pkg-config and CMake files.

Use the release tarball, not the archive GitHub generates for a tag. The GitHub
archive is missing the file that tells the build to make the library, so it
builds the Ghostty app instead.

**From a checkout:** to build `main` or any other commit, add `-Demit-lib-vt`.
Without it, `zig build` builds the Ghostty app.

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Demit-lib-vt -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

**With no network:** the build downloads a few Zig packages. The dependency
tarball has all of them, and the
[packaging guide](https://github.com/ghostty-org/ghostty/blob/main/PACKAGING-LIBGHOSTTY.md)
shows how to use it. If you're packaging libghostty-vt for a distribution, start
there.

## pkg-config {#installing-pkg-config}

Save the program from the @ref mainpage "main page" as `hello.c` and build it:

```sh
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig"
cc -o hello hello.c $(pkg-config --cflags --libs libghostty-vt) -Wl,-rpath,"$HOME/.local/lib"
./hello
```

The rpath tells the loader where the shared library is. On macOS you always need
one, because the library loads as `@rpath/libghostty-vt.1.dylib`. On Linux you
can drop it if you install to a directory the loader already searches, such as
`/usr/lib`.

## Static Linking {#installing-static}

Link statically when you want one binary with nothing to install next to it:

```sh
cc -o hello hello.c $(pkg-config --static --cflags --libs libghostty-vt-static)
```

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
