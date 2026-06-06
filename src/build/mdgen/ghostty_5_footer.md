# FILES

_\$XDG_CONFIG_HOME/ghostty/config.ghostty_

: Location of the default user configuration file.

_\$XDG_CONFIG_DIRS/ghostty/config.ghostty_

: Location of the default system configuration files.

_\$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.

_\$LOCALAPPDATA/ghostty/config.ghostty_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.mitchellh.ghostty**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.
**XDG_CONFIG_DIRS**

: Colon separated list of paths to load configuration files.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See GitHub issues: <https://github.com/ghostty-org/ghostty/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Ghostty contributors <https://github.com/ghostty-org/ghostty/graphs/contributors>

# SEE ALSO

**ghostty(1)**
