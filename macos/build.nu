#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

# Reset macOS Help Viewer state for Ghostty's help book (dev helper).
#
# helpd keeps two kinds of state: a per-book content cache (refreshed
# when the book's CFBundleVersion changes) and Core Spotlight search
# donations, which are only updated incrementally — search results for
# pages that no longer exist stick around and open as "content not
# available". `hiutil -P` quits Help Viewer (Tips) and helpd and purges
# the persisted state including the donations; the explicit removal
# below covers Ghostty's content cache in case parts of the purge fail.
# Relaunch the app afterwards so it re-registers the book.
def "main help-book-reset" [] {
    try { ^/usr/bin/hiutil -P }

    let cache_globs = [
        $"($env.HOME)/Library/Group Containers/group.com.apple.helpviewer.content/Library/Caches/com.mitchellh.ghostty*.help"
        $"($env.HOME)/Library/Caches/com.apple.helpd/Generated/com.mitchellh.ghostty*"
    ]
    for pattern in $cache_globs {
        glob $pattern | each {|path| rm -r -f $path } | ignore
    }

    print "Help Viewer state purged. Relaunch the app to re-register the book. The registration might take roughly 10s to finish."
}

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        $action)
}
