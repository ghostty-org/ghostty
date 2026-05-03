# swift-vt-xcframework

Demonstrates consuming libghostty-vt from a Swift Package using the
pre-built XCFramework. Creates a terminal, writes VT sequences into it,
and formats the screen contents as plain text.

This example requires the XCFramework to be built first.

## Building

First, build the XCFramework from the repository root:

```shell-session
zig build -Demit-lib-vt
```

Then build and run the Swift package:

```shell-session
cd example/swift-vt-xcframework
swift build
swift run
```
