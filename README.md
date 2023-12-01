<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://user-images.githubusercontent.com/1299/199110421-9ff5fc30-a244-441e-9882-26070662adf9.png" alt="Logo" width="100">
  <br>Ghostty
</h1>
  <p align="center">
    GPU-accelerated terminal emulator pushing modern features.
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
    <a href="https://github.com/mitchellh/ghostty/blob/main/README_TESTERS.md"><b>Testers! Read This Too!</b></a>
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

While aiming for this ambitious goal, Ghostty is a fully standards compliant
terminal emulator that aims to remain compatible with all existing shells
and software. You can use this as a drop-in replacement for your existing
terminal emulator.

**Project Status:** Ghostty is still in beta but implements most of the
features you'd expect for a daily driver. We currently have hundreds of active
beta users using Ghostty as their primary terminal. See more in
[Roadmap and Status](#roadmap-and-status).

## Download

| Platform / Package | Links                                                                    | Notes                      |
| ------------------ | ------------------------------------------------------------------------ | -------------------------- |
| macOS              | [Tip ("Nightly")](https://github.com/mitchellh/ghostty/releases/tag/tip) | MacOS 12+ Universal Binary |
| Linux              | [Build from Source](#developing-ghostty)                                 |                            |
| Windows            | [Build from Source](#developing-ghostty)                                 | [Notes](#windows-notes)    |

### Configuration

To configure Ghostty, you must use a configuration file. GUI-based configuration
is on the roadmap but not yet supported. The configuration file must be
placed at `$XDG_CONFIG_HOME/ghostty/config`, which defaults to
`~/.config/ghostty/config` if the [XDG environment is not set](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

The file format is documented below as an example:

```
# The syntax is "key = value". The whitespace around the equals doesn't matter.
background = 282c34
foreground= ffffff

# Blank lines are ignored!

keybind = ctrl+z=close_surface
keybind = ctrl+d=new_split:right

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

While the set of config keys and values are not yet documented, they are
discoverable in the [Config structure](https://github.com/mitchellh/ghostty/blob/main/src/config/Config.zig).
The available keys are the keys verbatim, and their possible values are typically
documented in the comments. You also can search for the
[public config files](https://github.com/search?q=path%3Aghostty%2Fconfig&type=code)
of many Ghostty users for examples and inspiration.

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
it may have encountered. Ghostty currently ignores errors and treats it
as if the configuration had not been set, so this is the best place to look
if something isn't working.

Eventually, we'll have a better mechanism for showing errors to the user.

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
$ ghostty +list-themes
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
- Triple-click while holding control to select the output of a command.
- The cursor at the prompt is turned into a bar.
- The `jump_to_prompt` keybinding can be used to scroll the terminal window
  forward and back through prompts.

#### Shell Integration Installation and Verification

Ghostty will automatically inject the shell integration code for `zsh` and
`fish`. `bash` does not support automatic injection but you can manually
`source` the `ghostty.bash` file in `src/shell-integration`. Other shells are
not supported. **If you want to disable this feature,** set
`shell-integration = none` in your configuration file.

**For the automatic shell integration to work,** Ghostty must either be run
from the macOS app bundle or be installed in a location where the contents of
`zig-out/share` are available somewhere above the directory where Ghostty
is running from. On Linux, this should automatically work if you run from
the `zig-out` directory tree structure (a standard FHS-style tree).

You may also manually set the `GHOSTTY_RESOURCES_DIR` to point to the
`zig-out/share` contents. To validate this directory the file
`$GHOSTTY_RESOURCES_DIR/terminfo/ghostty.terminfo` should exist.

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
# Ghostty shell integration
if [ -n "$GHOSTTY_RESOURCES_DIR" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

**This must be at the top of your bashrc, not the bottom.** The same
goes for any other shell.

### Terminfo and SSH

Ghostty ships with its own [terminfo](https://en.wikipedia.org/wiki/Terminfo)
entry to tell software about its capabilities. When that entry is detected,
Ghostty sets the `TERM` environment variable to `xterm-ghostty`.

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
$ infocmp -x | ssh YOUR-SERVER -- tic -x -
```

**Note: macOS versions before Sonoma cannot use the system-bundled `infocmp`.**
The bundled version of `ncurses` is too old to emit a terminfo entry that can be
read by more recent versions of `tic`, and the command will fail with a bunch
of `Illegal character` messages. You can fix this by using Homebrew to install
a recent version of `ncurses` and replacing `infocmp` above with the full path
`/opt/homebrew/opt/ncurses/bin/infocmp`.

#### Configure SSH to fall back to a known terminfo entry

If copying around terminfo entries is untenable, you can override `TERM` to a
fallback value using SSH config.

```ssh-config
# .ssh/config
Host example.com
  SetEnv TERM=xterm-256color
```

**Note: Fallback does not support advanced terminal features.** Because
`xterm-256color` does not include all of Ghostty's capabilities, terminal
features beyond xterm's like colored and styled underlines will not work.

**Note: Requires OpenSSH 8.7 or newer.** [The 8.7 release added
support](https://www.openssh.com/txt/release-8.7) for setting `TERM` via
`SetEnv`.

## Roadmap and Status

The high-level ambitious plan for the project, in order:

|  #  | Step                                                        | Status |
| :-: | ----------------------------------------------------------- | :----: |
|  1  | [Standards-compliant terminal emulation](docs/sequences.md) |   ⚠️   |
|  2  | Competitive performance                                     |   ✅   |
|  3  | Basic customizability -- fonts, bg colors, etc.             |   ✅   |
|  4  | Richer windowing features -- multi-window, tabbing, panes   |   ✅   |
|  5  | Native Platform Experiences (i.e. Mac Preference Panel)     |   ⚠️   |
|  6  | Windows Terminals (including PowerShell, Cmd, WSL)          |   ❌   |
|  N  | Fancy features (to be expanded upon later)                  |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

I am able to use this terminal as a daily driver. I think that's good enough
for a yellow status. There are a LOT of missing features for full standards
compliance but the set that are regularly in use are working pretty well.

#### Competitive Performance

We need better benchmarks to continuously verify this, but I believe at
this stage Ghostty is already best-in-class (or at worst second in certain
cases) for a majority of performance measuring scenarios.

For rendering, we have a multi-renderer architecture that uses OpenGL on
Linux and Metal on macOS. As far as I'm aware, we're the only terminal
emulator other than iTerm that uses Metal directly. And we're the only
terminal emulator that has a Metal renderer that supports ligatures (iTerm
uses a CPU renderer if ligatures are enabled). We can maintain roughly
100fps under heavy load and 120fps generally -- though the terminal is
usually rendering much lower due to little screen changes.

For IO, we have a dedicated IO thread that maintains very little jitter
under heavy IO load (i.e. `cat <big file>.txt`). On benchmarks for IO,
we're usually top of the class by a large margin over popular terminal
emulators. For example, reading a dump of plain text is 4x faster compared
to iTerm and Kitty, and 2x faster than Terminal.app. Alacritty is very
fast but we're still ~15% faster and our app experience is much more
feature rich.

#### Richer Windowing Features

The Mac app supports multi-window, tabbing, and splits.

The Linux app (built with GTK) supports multi-window and tabbing. Splits
will come soon in a future update.

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

## Developing Ghostty

To build Ghostty, you only need [Zig](https://ziglang.org/) installed.

The official development environment is defined by Nix. You do not need
to use Nix to develop Ghostty, but the Nix environment is the environment
which runs CI tests and builds release artifacts. Any development work on
Ghostty must pass within these Nix environments.

**Note: Zig nightly is required.** Ghostty is built against the nightly
releases of Zig while it is still in beta. I plan on stabilizing on a release
version when I get closer to generally releasing this to ease downstream
packagers. You can find binary releases of nightly builds on the
[Zig downloads page](https://ziglang.org/download/).

With Zig installed, a binary can be built using `zig build`:

```shell-session
$ zig build
...

$ zig-out/bin/ghostty
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
$ zig build -Doptimize=ReleaseFast
...
```

You can verify you have a release version by checking the filesize of the
built binary (`zig-out/bin/ghostty`). The release version should be less
than 5 MB on all platforms. The debug version is around 70MB.

**Note: when using the GTK runtime (`-Dapp-runtime=gtk`) a release build will
use a [single-instance application](https://developer.gnome.org/documentation/tutorials/application.html).
If you're developing Ghostty from _inside_ a release build and build & launch a
new one that will not reflect the changes you made, but instead launch a new
window for the existing instance. You can disable this behaviour with the
`--gtk-single-instance=false` flag or by adding `gtk-single-instance = false` to
the configuration file.**

### Linux Installation Tips

If you're planning to use a build from source as your daily driver,
I recommend using the `-p` (prefix) flag for `zig build` to install
Ghostty into `~/.local`. This will setup the proper FHS directory structure
that ensures features such as shell integration, icons, GTK shortcuts, etc.
all work.

```
$ zig build -p $HOME/.local -Doptimize=ReleaseFast
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
build on a macOS machine with XCode installed:

```shell-session
$ zig build -Doptimize=ReleaseFast
$ cd macos && xcodebuild
```

This will output the app to `macos/build/Release/Ghostty.app`.
This app will be not be signed or notarized. Note that
[official continuous builds are available](https://github.com/mitchellh/ghostty/releases/tag/tip)
that are both signed and notarized.

When running the app, logs are available via macOS unified logging such
as `Console.app`. The easiest way I've found to view these is to just use the CLI:

```sh
$ sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
...
```

### Windows Notes

Windows support is still a [work-in-progress](https://github.com/mitchellh/ghostty/issues/437).
The current status is that a bare bones glfw-based build _works_! The experience
with this build is super minimal: there are no native experiences, only a
single window is supported, no tabs, etc. Therefore, the current status is
simply that the core terminal experience works.

If you want to help with Windows development, please see the
[tracking issue](https://github.com/mitchellh/ghostty/issues/437). We plan
on vastly improving this experience over time.

### Linting

Ghostty's docs and resources (not including Zig code) are linted using
[Prettier](https://prettier.io) with out-of-the-box settings. A Prettier CI
check will fail builds with improper formatting. Therefore, if you are
modifying anything Prettier will lint, you may want to install it locally and
run this from the repo root before you commit:

```
prettier --write .
```

Make sure your Prettier version matches the version of in [devshell.nix](https://github.com/mitchellh/ghostty/blob/main/nix/devshell.nix).

### Nix Package

> [!WARNING]
> The Nix package currently depends on versions of LLVM and Zig that are
> currently not in cache.nixos.org and will be built from source. This can take
> a very long time, especially in situations where CPU is at a premium. Most
> people should follow the instructions in [Developing
> Ghostty](#developing-ghostty) instead.

There is a functional Nix package that can be used in the `flake.nix` file
(`packages.ghostty`). It can be used in NixOS configurations and otherwise
built off of (however, please heed the above warning).

Below is a sample on how to add it to a NixOS overlay:

```nix
{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;

    # NOTE: This will require your git SSH access to the repo
    ghostty = {
      url = git+ssh://git@github.com/mitchellh/ghostty;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, ghostty, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nixpkgs.overlays = [
            (final: prev: {
              ghostty = ghostty.packages.${prev.system}.ghostty;
            })
          ];
        }

        # Other modules here...
      ];
    };
  };
}
```

You can also test the build of the nix package at any time by running `nix build .`

#### Updating the Zig Cache Fixed-Output Derivation Hash

The Nix package depends on a [fixed-output
derivation](https://nixos.org/manual/nix/stable/language/advanced-attributes.html#adv-attr-outputHash)
that manages the Zig package cache. This allows the package to be built in the
Nix sandbox.

Occasionally (usually when `build.zig.zon` is updated), the hash that
identifies the cache will need to be updated. There are jobs that monitor the
hash in CI, and builds will fail if it drifts.

To update it, you can run the following in the repository root:

```
./nix/build-support/check-zig-cache-hash.sh --update
```

This will write out the `nix/zig_cache_hash.nix` file with the updated hash
that can then be committed and pushed to fix the builds.
