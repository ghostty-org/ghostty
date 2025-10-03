% GHOSTTY(5) Version @@VERSION@@ | Ghostty terminal emulator configuration file

# NAME

**ghostty** - Ghostty terminal emulator configuration file

# DESCRIPTION

To configure Ghostty, you must use a configuration file. GUI-based configuration
is on the roadmap but not yet supported. The configuration file must be placed
at `$XDG_CONFIG_HOME/ghostty/config`, which defaults to `~/.config/ghostty/config`
if the [XDG environment is not set](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

**If you are using macOS, the configuration file can also be placed at
`$HOME/Library/Application Support/com.mitchellh.ghostty/config`.** This is the
default configuration location for macOS. It will be searched before any of the
XDG environment locations listed above.

The file format is documented below as an example:

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

You can view all available configuration options and their documentation by
executing the command `ghostty +show-config --default --docs`. Note that this will
output the full default configuration with docs to stdout, so you may want to
pipe that through a pager, an editor, etc.

Note: You'll see a lot of weird blank configurations like `font-family =`. This
is a valid syntax to specify the default behavior (no value). The `+show-config`
outputs it so it's clear that key is defaulting and also to have something to
attach the doc comment to.

You can also see and read all available configuration options in the source
Config structure. The available keys are the keys verbatim, and their possible
values are typically documented in the comments. You also can search for
the public config files of many Ghostty users for examples and inspiration.

## Configuration Errors

If your configuration file has any errors, Ghostty does its best to ignore
them and move on. Configuration errors will be logged.

## Debugging Configuration

You can verify that configuration is being properly loaded by looking at the
debug output of Ghostty.

In the debug output, you should see in the first 20 lines or so messages about
loading (or not loading) a configuration file, as well as any errors it may have
encountered. Configuration errors are also shown in a dedicated window on both
macOS and Linux (GTK). Ghostty does not treat configuration errors as fatal and
will fall back to default values for erroneous keys.

You can also view the full configuration Ghostty is loading using `ghostty
+show-config` from the command-line. Use the `--help` flag to additional options
for that command.

## Logging

Ghostty can write logs to a number of destinations. On all platforms, logging to
`stderr` is available. Depending on the platform and how Ghostty was launched,
logs sent to `stderr` may be stored by the system and made available for later
retrieval.

On Linux if Ghostty is launched by the default `systemd` user service, you can use
`journald` to see Ghostty's logs: `journalctl --user --unit app-com.mitchellh.ghostty.service`.

On macOS logging to the macOS unified log is available and enabled by default.
--Use the system `log` CLI to view Ghostty's logs: `sudo log stream level debug
----predicate 'subsystem=="com.mitchellh.ghostty"'`.

Ghostty's logging can be configured in two ways. The first is by what
optimization level Ghostty is compiled with. If Ghostty is compiled with `Debug`
optimizations debug logs will be output to `stderr`. If Ghostty is compiled with
any other optimization the debug logs will not be output to `stderr`.

Ghostty also checks the `GHOSTTY_LOG` environment variable. It can be used
to control which destinations receive logs. Ghostty currently defines two
destinations:

- `stderr` - logging to `stderr`.
- `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `GHOSTTY_LOG` to `true` will enable all
destinations. Setting `GHOSTTY_LOG` to `false` will disable all destinations.
