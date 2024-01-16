# FILES

_\$XDG_CONFIG_HOME/ghostty/config_

: Location of the default configuration file.

_\$LOCALAPPDATA/ghostty/config_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**TERM**

: Defaults to `xterm-ghostty`. Can be configured with the `term` configuration option.

**GHOSTTY_RESOURCES_DIR**

: Where the Ghostty resources can be found.

**XDG_CONFIG_HOME**

: Default location for configuration files.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See GitHub issues: <https://github.com/mitchellh/ghostty/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>

# SEE ALSO

**ghostty(5)**
