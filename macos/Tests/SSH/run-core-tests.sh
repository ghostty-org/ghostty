#!/bin/sh
# Run SSH model/auth policy tests without requiring the GhosttyKit build.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-ssh-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/SSHCore" "$work/Tests/SSHCoreTests"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SSHCore", platforms: [.macOS(.v13)], products: [], targets: [
    .target(name: "SSHCore"), .testTarget(name: "SSHCoreTests", dependencies: ["SSHCore"])
])
PACKAGE
for source in SSHProfile SSHAuthenticationPolicy SSHSessionFile SSHChildProcess; do
    if [ -f "$repo/macos/Sources/Features/SSH/$source.swift" ]; then
        cp "$repo/macos/Sources/Features/SSH/$source.swift" "$work/Sources/SSHCore/"
    fi
done
# Keep the initial red run meaningful even before sources exist.
touch "$work/Sources/SSHCore/Placeholder.swift"
for test in "$repo"/macos/Tests/SSH/*Tests.swift; do
    sed 's/@testable import Ghostty/@testable import SSHCore/' "$test" > "$work/Tests/SSHCoreTests/$(basename "$test")"
done
swift test --package-path "$work" --scratch-path "$work/build"
