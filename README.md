<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="#developing-ghostty">Developing</a>
  </p>
</p>

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

In all categories, I am not trying to claim that Ghostty is the
best (i.e. the fastest, most feature-rich, or most native). But
Ghostty is competitive in all three categories and Ghostty
doesn't make you choose between them.

Ghostty also intends to push the boundaries of what is possible with a
terminal emulator by exposing modern, opt-in features that enable CLI tool
developers to build more feature rich, interactive applications.

While aiming for this ambitious goal, our first step is to make Ghostty
one of the best fully standards compliant terminal emulator, remaining
compatible with all existing shells and software while supporting all of
the latest terminal innovations in the ecosystem. You can use Ghostty
as a drop-in replacement for your existing terminal emulator.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Roadmap and Status

The high-level ambitious plan for the project, in order:

|  #  | Step                                                      | Status |
| :-: | --------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                    |   ✅   |
|  2  | Competitive performance                                   |   ✅   |
|  3  | Basic customizability -- fonts, bg colors, etc.           |   ✅   |
|  4  | Richer windowing features -- multi-window, tabbing, panes |   ✅   |
|  5  | Native Platform Experiences (i.e. Mac Preference Panel)   |   ⚠️   |
|  6  | Cross-platform `libghostty` for Embeddable Terminals      |   ⚠️   |
|  7  | Windows Terminals (including PowerShell, Cmd, WSL)        |   ❌   |
|  N  | Fancy features (to be expanded upon later)                |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements enough control sequences to be used by hundreds of
testers daily for over the past year. Further, we've done a
[comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

We believe Ghostty is one of the most compliant terminal emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

We need better benchmarks to continuously verify this, but Ghostty is
generally in the same performance category as the other highest performing
terminal emulators.

For rendering, we have a multi-renderer architecture that uses OpenGL on
Linux and Metal on macOS. As far as I'm aware, we're the only terminal
emulator other than iTerm that uses Metal directly. And we're the only
terminal emulator that has a Metal renderer that supports ligatures (iTerm
uses a CPU renderer if ligatures are enabled). We can maintain around 60fps
under heavy load and much more generally -- though the terminal is
usually rendering much lower due to little screen changes.

For IO, we have a dedicated IO thread that maintains very little jitter
under heavy IO load (i.e. `cat <big file>.txt`). On benchmarks for IO,
we're usually within a small margin of other fast terminal emulators.
For example, reading a dump of plain text is 4x faster compared to iTerm and
Kitty, and 2x faster than Terminal.app. Alacritty is very fast but we're still
around the same speed (give or take) and our app experience is much more
feature rich.

> [!NOTE]
> Despite being _very fast_, there is a lot of room for improvement here.

#### Richer Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- The Linux app is built with GTK.

There are more improvements to be made. The macOS settings window is still
a work-in-progress. Similar improvements will follow with Linux.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

This goal is not hypothetical! The macOS app is a `libghostty` consumer.
The macOS app is a native Swift app developed in Xcode and `main()` is
within Swift. The Swift app links to `libghostty` and uses the C API to
render terminals.

This step encompasses expanding `libghostty` support to more platforms
and more use cases. At the time of writing this, `libghostty` is very
Mac-centric -- particularly around rendering -- and we have work to do to
expand this to other platforms.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending when the crash occurred.

## Developing Ghostty

See the documentation on the Ghostty website for
[building Ghostty from a source tarball](http://ghostty.org/docs/install/build).
Building Ghostty from a Git checkout is very similar, except you want to
omit the `-Doptimize` flag to build a debug build, and you may require
additional dependencies since the source tarball includes some processed
files that are not in the Git repository.

On Linux or macOS, you can use `zig build -Dapp-runtime=glfw run` for a quick
GLFW-based app for a faster development cycle while developing core
terminal features. Note that this app is missing many features and is also
known to crash in certain scenarios, so it is only meant for development
tasks.

Other useful commands:

- `zig build test` for running unit tests.
- `zig build test -Dtest-filter=<filter>` for running a specific subset of those unit tests
- `zig build run -Dconformance=<name>` runs a conformance test case from
  the `conformance` directory. The `name` is the name of the file. This runs
  in the current running terminal emulator so if you want to check the
  behavior of this project, you must run this command in Ghostty.

### Extra Dependencies

Building Ghostty from a Git checkout on Linux requires some additional
dependencies:

- `blueprint-compiler`

macOS users don't require any additional dependencies.

> [!NOTE]
> This only applies to building from a _Git checkout_. This section does
> not apply if you're building from a released _source tarball_. For
> source tarballs, see the
> [website](http://ghostty.org/docs/install/build).

### Xcode Version and SDKs

Building the Ghostty macOS app requires that Xcode, the macOS SDK,
and the iOS SDK are all installed.

A common issue is that the incorrect version of Xcode is either
installed or selected. Use the `xcode-select` command to
ensure that the correct version of Xcode is selected:

```shell-session
sudo xcode-select --switch /Applications/Xcode-beta.app
```

> [!IMPORTANT]
>
> Main branch development of Ghostty is preparing for the next major
> macOS release, Tahoe (macOS 26). Therefore, the main branch requires
> **Xcode 26 and the macOS 26 SDK**.
>
> You do not need to be running on macOS 26 to build Ghostty, you can
> still use Xcode 26 beta on macOS 15 stable.

### Linting

#### Prettier

Ghostty's docs and resources (not including Zig code) are linted using
[Prettier](https://prettier.io) with out-of-the-box settings. A Prettier CI
check will fail builds with improper formatting. Therefore, if you are
modifying anything Prettier will lint, you may want to install it locally and
run this from the repo root before you commit:

```
prettier --write .
```

Make sure your Prettier version matches the version of Prettier in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

Nix users can use the following command to format with Prettier:

```
nix develop -c prettier --write .
```

#### Alejandra

Nix modules are formatted with [Alejandra](https://github.com/kamadorueda/alejandra/). An Alejandra CI check
will fail builds with improper formatting.

Nix users can use the following command to format with Alejandra:

```
nix develop -c alejandra .
```

Non-Nix users should install Alejandra and use the following command to format with Alejandra:

```
alejandra .
```

Make sure your Alejandra version matches the version of Alejandra in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

#### Updating the Zig Cache Fixed-Output Derivation Hash

The Nix package depends on a [fixed-output
derivation](https://nix.dev/manual/nix/stable/language/advanced-attributes.html#adv-attr-outputHash)
that manages the Zig package cache. This allows the package to be built in the
Nix sandbox.

Occasionally (usually when `build.zig.zon` is updated), the hash that
identifies the cache will need to be updated. There are jobs that monitor the
hash in CI, and builds will fail if it drifts.

To update it, you can run the following in the repository root:

```
./nix/build-support/check-zig-cache-hash.sh --update
```

This will write out the `nix/zigCacheHash.nix` file with the updated hash
that can then be committed and pushed to fix the builds.
