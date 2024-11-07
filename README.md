<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://user-images.githubusercontent.com/1299/199110421-9ff5fc30-a244-441e-9882-26070662adf9.png" alt="Logo" width="100">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    <a href="#about">About</a>
    ·
    <a href="#download">Download</a>
    ·
    <a href="#roadmap-and-status">Roadmap</a>
    ·
    <a href="#developing-ghostty">Developing</a>
  </p>
  <p align="center">
    <a href="https://github.com/ghostty-org/ghostty/blob/main/README_TESTERS.md"><b>Testers! Read This Too!</b></a>
  </p>
</p>

## About

Ghostty is a cross-platform, GPU-accelerated terminal emulator that aims to
push the boundaries of what is possible with a terminal emulator by exposing
modern, opt-in features that enable CLI tool developers to build more feature
rich, interactive applications.

There are a number of excellent terminal emulator options that exist
today. The unique goal of Ghostty is to have a platform for experimenting
with modern, optional, non-standards-compliant features to enhance the
capabilities of CLI applications. We aim to be the best in this category,
and competitive in the rest.

While aiming for this ambitious goal, our first step is to make Ghostty
one of the best fully standards compliant terminal emulator, remaining
compatible with all existing shells and software while supporting all of
the latest terminal innovations in the ecosystem. You can use Ghostty
as a drop-in replacement for your existing terminal emulator.

**Project Status:** Ghostty is still in beta but implements most of the
features you'd expect for a daily driver. We currently have hundreds of active
beta users using Ghostty as their primary terminal. See more in
[Roadmap and Status](#roadmap-and-status).

## Download

| Platform / Package | Links                                                                      | Notes                      |
| ------------------ | -------------------------------------------------------------------------- | -------------------------- |
| macOS              | [Tip ("Nightly")](https://github.com/ghostty-org/ghostty/releases/tag/tip) | MacOS 13+ Universal Binary |
| Linux              | [Build from Source](#developing-ghostty)                                   |                            |
| Linux (NixOS/Nix)  | [Use the Flake](#nix-package)                                              |                            |
| Linux (Arch)       | [Use the AUR package](https://aur.archlinux.org/packages/ghostty-git)      |                            |
| Windows            | [Build from Source](#developing-ghostty)                                   | [Notes](#windows-notes)    |

### Configuration

To configure Ghostty, you must use a configuration file. GUI-based configuration
is on the roadmap but not yet supported. The configuration file must be
placed at `$XDG_CONFIG_HOME/ghostty/config`, which defaults to
`~/.config/ghostty/config` if the [XDG environment is not set](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

The file format is documented below as an example:

```ini
# The syntax is "key = value". The whitespace around the equals doesn't matter.
background = 282c34
foreground= ffffff

# Comments start with a `#` and are only valid on their own line.
# Blank lines are ignored!

keybind = ctrl+z=close_surface
keybind = ctrl+d=new_split:right

# Empty values reset the configuration to the default value

font-family =

# Colors can be changed by setting the 16 colors of `palette`, which each color
# being defined as regular and bold.
#
# black
palette = 0=#1d2021
palette = 8=#7c6f64
# red
palette = 1=#cc241d
palette = 9=#fb4934
# green
palette = 2=#98971a
palette = 10=#b8bb26
# yellow
palette = 3=#d79921
palette = 11=#fabd2f
# blue
palette = 4=#458588
palette = 12=#83a598
# purple
palette = 5=#b16286
palette = 13=#d3869b
# aqua
palette = 6=#689d6a
palette = 14=#8ec07c
# white
palette = 7=#a89984
palette = 15=#fbf1c7
```

You can view all available configuration options and their documentation
by executing the command `ghostty +show-config --default --docs`. Note that
this will output the full default configuration with docs to stdout, so
you may want to pipe that through a pager, an editor, etc.

> [!NOTE]
>
> You'll see a lot of weird blank configurations like `font-family =`. This
> is a valid syntax to specify the default behavior (no value). The
> `+show-config` outputs it so it's clear that key is defaulting and also
> to have something to attach the doc comment to.

You can also see and read all available configuration options in the source
[Config structure](https://github.com/ghostty-org/ghostty/blob/main/src/config/Config.zig).
The available keys are the keys verbatim, and their possible values are typically
documented in the comments. You also can search for the
[public config files](https://github.com/search?q=path%3Aghostty%2Fconfig&type=code)
of many Ghostty users for examples and inspiration.

> [!NOTE]
>
> Configuration can be reloaded on the fly with the `reload_config`
> command. Not all configuration options can change without restarting Ghostty.
> Any options that require a restart should be documented.

#### Configuration Errors

If your configuration file has any errors, Ghostty does its best to ignore
them and move on. Configuration errors currently show up in the log. The
log is written directly to stderr, so it is up to you to figure out how to
access that for your system (for now). On macOS, you can also use the
system `log` CLI utility. See the [Mac App](#mac-app) section for more
information.

#### Debugging Configuration

You can verify that configuration is being properly loaded by looking at
the debug output of Ghostty. Documentation for how to view the debug output
is in the "building Ghostty" section at the end of the README.

In the debug output, you should see in the first 20 lines or so messages
about loading (or not loading) a configuration file, as well as any errors
it may have encountered. Configuration errors are also shown in a dedicated
window on both macOS and Linux (GTK). Ghostty does not treat configuration
errors as fatal and will fall back to default values for erroneous keys.

You can also view the full configuration Ghostty is loading using
`ghostty +show-config` from the command-line. Use the `--help` flag to
additional options for that command.

### Themes

Ghostty ships with 300+ built-in themes (from
[iTerm2 Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)).
You can configure Ghostty to use any of these themes using the `theme`
configuration. Example:

```
theme = Solarized Dark - Patched
```

You can find a list of built-in themes using the `+list-themes` action:

```
ghostty +list-themes
...
```

On macOS, the themes are built-in to the `Ghostty.app` bundle. On Linux,
theme support requires a valid Ghostty resources dir ("share" directory).
More details about how to validate the resources directory on Linux
is covered in the [shell integration section](#shell-integration-installation-and-verification).

Any custom color configuration (`palette`, `background`, `foreground`, etc.)
in your configuration files will override the theme settings. This can be
used to load a theme and fine-tune specific colors to your liking.

**Interested in contributing a new theme or updating an existing theme?**
Please send theme changes upstream to the
[iTerm2 Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes))
repository. Ghostty periodically updates the themes from this source.
_Do not send theme changes to the Ghostty project directly_.

### Shell Integration

Ghostty supports some features that require shell integration. I am aiming
to support many of the features that
[Kitty supports for shell integration](https://sw.kovidgoyal.net/kitty/shell-integration/).

The currently supported shell integration features in Ghostty:

- We do not confirm close for windows where the cursor is at a prompt.
- New terminals start in the working directory of the previously focused terminal.
- Complex prompts resize correctly by allowing the shell to redraw the prompt line.
- Triple-click while holding control (Linux) or command (macOS) to select the output of a command.
- The cursor at the prompt is turned into a bar.
- The `jump_to_prompt` keybinding can be used to scroll the terminal window
  forward and back through prompts.
- Alt+click (option+click on macOS) to move the cursor at the prompt.
- `sudo` is wrapped to preserve Ghostty terminfo (disabled by default)

#### Shell Integration Installation and Verification

Ghostty will automatically inject the shell integration code for `bash`, `zsh`
and `fish`. Other shells do not have shell integration code written but will
function fine within Ghostty with the above mentioned shell integration features
inoperative. **If you want to disable automatic shell integration,** set
`shell-integration = none` in your configuration file.

Automatic `bash` shell integration requires Bash version 4 or later and must be
explicitly enabled by setting `shell-integration = bash`.

**For the automatic shell integration to work,** Ghostty must either be run
from the macOS app bundle or be installed in a location where the contents of
`zig-out/share` are available somewhere above the directory where Ghostty
is running from. On Linux, this should automatically work if you run from
the `zig-out` directory tree structure (a standard FHS-style tree).

You may also manually set the `GHOSTTY_RESOURCES_DIR` to point to the
`zig-out/share/ghostty` contents. To validate this directory the file
`$GHOSTTY_RESOURCES_DIR/../terminfo/ghostty.terminfo` should exist.

To verify shell integration is working, look for the following log lines:

```
info(io_exec): using Ghostty resources dir from env var: /Applications/Ghostty.app/Contents/Resources
info(io_exec): shell integration automatically injected shell=termio.shell_integration.Shell.fish
```

If you see any of the following, something is not working correctly.
The main culprit is usually that `GHOSTTY_RESOURCES_DIR` is not pointing
to the right place.

```
ghostty terminfo not found, using xterm-256color

or

shell could not be detected, no automatic shell integration will be injected
```

#### Switching Shells with Shell Integration

Automatic shell integration as described in the previous section only works
for the _initially launched shell_ when Ghostty is started. If you switch
shells within Ghostty, i.e. you manually run `bash` or you use a command
like `nix-shell`, the shell integration _will be lost_ in that shell
(it will keep working in the original shell process).

To make shell integration work in these cases, you must manually source
the Ghostty shell-specific code at the top of your shell configuration
files. Ghostty will automatically set the `GHOSTTY_RESOURCES_DIR` environment
variable when it starts, so you can use this to (1) detect your shell
is launched within Ghostty and (2) to find the shell-integration.

For example, for bash, you'd put this _at the top_ of your `~/.bashrc`:

```bash
# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

Each shell integration's installation instructions are documented inline:

| Shell  | Integration                                                                                    |
| ------ | ---------------------------------------------------------------------------------------------- |
| `bash` | `${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash`                                 |
| `fish` | `${GHOSTTY_RESOURCES_DIR}/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish` |
| `zsh`  | `${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration`                           |

### Terminfo

Ghostty ships with its own [terminfo](https://en.wikipedia.org/wiki/Terminfo)
entry to tell software about its capabilities. When that entry is detected,
Ghostty sets the `TERM` environment variable to `xterm-ghostty`.

If the Ghostty resources dir ("share" directory) is detected, Ghostty will
set a `TERMINFO` environment variable so `xterm-ghostty` properly advertises
the available capabilities of Ghostty. On macOS, this always happens because
the terminfo is embedded in the app bundle. On Linux, this depends on
appropriate installation (see the installation instructions).

If you use `sudo`, sudo may reset your environment variables and you may see
an error about `missing or unsuitable terminal: xterm-ghostty` when running
some programs. To resolve this, you must either configure sudo to preserve
the `TERMINFO` environment variable, or you can use shell-integration with
the `sudo` feature enabled and Ghostty will alias sudo to automatically do
this for you. To enable the shell-integration feature specify
`shell-integration-features = sudo` in your configuration.

If you use SSH to connect to other machines that do not have Ghostty's terminfo
entry, you will see error messages like `missing or unsuitable terminal:
xterm-ghostty`.

Hopefully someday Ghostty will have terminfo entries pre-distributed
everywhere, but in the meantime there are two ways to resolve the situation:

1.  Copy Ghostty's terminfo entry to the remote machine.
2.  Configure SSH to fall back to a known terminfo entry.

#### Copy Ghostty's terminfo to a remote machine

The following one-liner will export the terminfo entry from your host and
import it on the remote machine:

```shell-session
infocmp -x | ssh YOUR-SERVER -- tic -x -
```

> [!NOTE]
>
> **macOS versions before Sonoma cannot use the system-bundled `infocmp`.**
> The bundled version of `ncurses` is too old to emit a terminfo entry that can be
> read by more recent versions of `tic`, and the command will fail with a bunch
> of `Illegal character` messages. You can fix this by using Homebrew to install
> a recent version of `ncurses` and replacing `infocmp` above with the full path
> `/opt/homebrew/opt/ncurses/bin/infocmp`.

#### Configure SSH to fall back to a known terminfo entry

If copying around terminfo entries is untenable, you can override `TERM` to a
fallback value using SSH config.

```ssh-config
# .ssh/config
Host example.com
  SetEnv TERM=xterm-256color
```

**Requires OpenSSH 8.7 or newer.** [The 8.7 release added
support](https://www.openssh.com/txt/release-8.7) for setting `TERM` via
`SetEnv`.

> [!WARNING]
>
> **Fallback does not support advanced terminal features.** Because
> `xterm-256color` does not include all of Ghostty's capabilities, terminal
> features beyond xterm's like colored and styled underlines will not work.

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
> We still consider some aspects of our performance a "bug" and plan on
> taking a dedicated pass to improve performance before public release.

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

To build Ghostty, you need [Zig 0.13](https://ziglang.org/) installed.

On Linux, you may need to install additional dependencies. See
[Linux Installation Tips](#linux-installation-tips). On macOS, you
need Xcode installed with the macOS and iOS SDKs enabled. See
[Mac `.app`](#mac-app).

The official development environment is defined by Nix. You do not need
to use Nix to develop Ghostty, but the Nix environment is the environment
which runs CI tests and builds release artifacts. Any development work on
Ghostty must pass within these Nix environments.

> [!NOTE]
>
> **Zig 0.13 is required.** Ghostty only guarantees that it can build
> against 0.13. Zig is still a fast-moving project so it is likely newer
> versions will not be able to build Ghostty yet. You can find binary
> releases of Zig release builds on the
> [Zig downloads page](https://ziglang.org/download/).

With Zig and necessary dependencies installed, a binary can be built using
`zig build`:

```shell-session
zig build
...

zig-out/bin/ghostty
```

This will build a binary for the currently running system (if supported).
**Note: macOS does not result in a runnable binary with this command.**
macOS builds produce a library (`libghostty.a`) that is used by the Xcode
project in the `macos` directory to produce the final `Ghostty.app`.

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

### Compiling a Release Build

The normal build will be a _debug build_ which includes a number of
safety features as well as debugging features that dramatically slow down
normal operation of the terminal (by as much as 100x). If you are building
a terminal for day to day usage, build a release version:

```shell-session
zig build -Doptimize=ReleaseFast
...
```

You can verify you have a release version by checking the filesize of the
built binary (`zig-out/bin/ghostty`). The release version should be significantly
smaller than debug builds. On Linux, the release build is around 31MB while the
debug build is around 145MB.

When using the GTK runtime (`-Dapp-runtime=gtk`) a release build will
use a [single-instance application](https://developer.gnome.org/documentation/tutorials/application.html).
If you're developing Ghostty from _inside_ a release build and build & launch a
new one that will not reflect the changes you made, but instead launch a new
window for the existing instance. You can disable this behaviour with the
`--gtk-single-instance=false` flag or by adding `gtk-single-instance = false` to
the configuration file.

### Linux Installation Tips

On Linux, you'll need to install header packages for Ghostty's dependencies
before building it. Typically, these are only gtk4 and libadwaita, since
Ghostty will build everything else static by default. On Ubuntu and Debian, use

```
sudo apt install libgtk-4-dev libadwaita-1-dev git
```

> [!NOTE]
>
> **A recent GTK is required for Ghostty to work with Nvidia (GL) drivers
> under x11.** Ubuntu 22.04 LTS has GTK 4.6 which is not new enough. Ubuntu 23.10
> has GTK 4.12 and works. From [this discussion](https://discourse.gnome.org/t/opengl-context-version-not-respected-on-gtk4-rs/12162?u=cdehais)
> the problem was fixed in GTK by Dec 2022. Also, if you are a BTRFS user, make
> sure to manually upgrade your Kernel (6.6.6 will work). The stock kernel in
> Ubuntu 23.10 is 6.5.0 which has a bug which
> [causes zig to fail its hash check for packages](https://github.com/ziglang/zig/issues/17282).

> [!WARNING]
>
> GTK 4.14 on Wayland has a bug which may cause an immediate crash.
> There is an [open issue](https://gitlab.gnome.org/GNOME/gtk/-/issues/6589/note_2072039)
> to track this GTK bug. You can workaround this issue by running ghostty with
> `GDK_DEBUG=gl-disable-gles ghostty`
>
> However, that fix may not work for you if the GTK version Ghostty is compiled
> against is too old, which mainly currently happens with development builds on NixOS.
>
> If your build of Ghostty immediately crashes after launch, try looking
> through the debug output. If running `./zig-out/bin/ghostty 2>&1 | grep "Unrecognized value"`
> result in the line `Unrecognized value "gl-disable-gles". Try GDK_DEBUG=help`,
> then the GTK version used is too old.
>
> To fix this, you might need to manually tie the `nixpkgs-stable` inputs to your
> system's `nixpkgs` in `flake.nix`:
>
> ```nix
> {
>   inputs = {
>     # nixpkgs-stable.url = "github:nixos/nixpkgs/release-23.05";
>
>     # Assumes your system nixpkgs is called "nixpkgs"
>     nixpkgs-stable.url = "nixpkgs";
>   }
> }
> ```

On Arch Linux, use

```
sudo pacman -S gtk4 libadwaita
```

On Fedora variants, use

```
sudo dnf install gtk4-devel zig libadwaita-devel
```

On Fedora Atomic variants, use

```
rpm-ostree install gtk4-devel zig libadwaita-devel
```

If you're planning to use a build from source as your daily driver,
I recommend using the `-p` (prefix) flag for `zig build` to install
Ghostty into `~/.local`. This will setup the proper FHS directory structure
that ensures features such as shell integration, icons, GTK shortcuts, etc.
all work.

```
zig build -p $HOME/.local -Doptimize=ReleaseFast
...
```

With a typical Freedesktop-compatible desktop environment (i.e. Gnome,
KDE), this will make Ghostty available as an app in your app launcher.
Note, if you don't see it immediately you may have to log out and log back
in or maybe even restart. For my Gnome environment, it showed up within a
few seconds. For any other desktop environment, you can launch Ghostty
directly using `~/.local/bin/ghostty`.

If Ghostty fails to launch using an app icon in your app launcher,
ensure that `~/.local/bin` is on your _system_ `PATH`. The desktop environment
itself must have that path in the `PATH`. Google for your specific desktop
environment and distribution to learn how to do that.

This _isn't required_, but `~/.local` is a directory that happens to be
on the search path for a lot of software (such as Gnome and KDE) and
installing into a prefix with `-p` sets up a directory structure to ensure
all features of Ghostty work.

### Mac `.app`

To build the official, fully featured macOS application, you must
build on a macOS machine with Xcode installed, and the active developer
directory pointing to it. If you're not sure that's the case, check the
output of `xcode-select --print-path`:

```shell-session
xcode-select --print-path
/Library/Developer/CommandLineTools        # <-- BAD
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcode-select --print-path
/Applications/Xcode.app/Contents/Developer # <-- GOOD
```

The above can happen if you install the Xcode Command Line Tools _after_ Xcode
is installed. With that out of the way, make sure you have both the macOS and
iOS SDKs installed (from inside Xcode → Settings → Platforms), and let's move
on to building Ghostty:

```shell-session
zig build -Doptimize=ReleaseFast
cd macos && xcodebuild
```

> [!NOTE]
> If you're using the Nix environment on macOS, `xcodebuild` will
> fail due to the linker environment variables Nix sets. You must
> run the `xcodebuild` command specifically outside of the Nix
> environment.

This will output the app to `macos/build/ReleaseLocal/Ghostty.app`.
This app will be not be signed or notarized.
[Official continuous builds are available](https://github.com/ghostty-org/ghostty/releases/tag/tip)
that are both signed and notarized.

The "ReleaseLocal" build configuration is specifically for local release
builds and disables some security features (such as "Library Validation")
to make it easier to run without having to have a code signing identity
and so on. These builds aren't meant for distribution. If you want a release
build with all security features, I highly recommend you use
[the official continuous builds](https://github.com/ghostty-org/ghostty/releases/tag/tip).

When running the app, logs are available via macOS unified logging such
as `Console.app`. The easiest way I've found to view these is to just use the CLI:

```sh
sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
...
```

### Windows Notes

Windows support is still a [work-in-progress](https://github.com/ghostty-org/ghostty/issues/437).
The current status is that a bare bones glfw-based build _works_! The experience
with this build is super minimal: there are no native experiences, only a
single window is supported, no tabs, etc. Therefore, the current status is
simply that the core terminal experience works.

If you want to help with Windows development, please see the
[tracking issue](https://github.com/ghostty-org/ghostty/issues/437). We plan
on vastly improving this experience over time.

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

Nix users can use the following command to format with Alejanda:

```
nix develop -c alejandra .
```

Non-Nix users should install Alejandra and use the following command to format with Alejandra:

```
alejandra .
```

Make sure your Alejandra version matches the version of Alejandra in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

### Nix Package

There is Nix package that can be used in the flake (`packages.ghostty` or `packages.default`).
It can be used in NixOS configurations and otherwise built off of.

Below is an example:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # NOTE: This will require your git SSH access to the repo.
    #
    # WARNING:
    # Do NOT pin the `nixpkgs` input, as that will
    # declare the cache useless. If you do, you will have
    # to compile LLVM, Zig and Ghostty itself on your machine,
    # which will take a very very long time.
    #
    # Additionally, if you use NixOS, be sure to **NOT**
    # run `nixos-rebuild` as root! Root has a different Git config
    # that will ignore any SSH keys configured for the current user,
    # denying access to the repository.
    #
    # Instead, either run `nix flake update` or `nixos-rebuild build`
    # as the current user, and then run `sudo nixos-rebuild switch`.
    ghostty = {
      url = "git+ssh://git@github.com/ghostty-org/ghostty";

      # NOTE: The below 2 lines are only required on nixos-unstable,
      # if you're on stable, they may break your build
      inputs.nixpkgs-stable.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, ghostty, ... }: {
    nixosConfigurations.mysystem = nixpkgs.lib.nixosSystem {
      modules = [
        {
          environment.systemPackages = [
            ghostty.packages.x86_64-linux.default
          ];
        }
      ];
    };
  };
}
```

You can also test the build of the nix package at any time by running `nix build .`.

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
