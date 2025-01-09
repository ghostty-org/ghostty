# FILES

_\$XDG_CONFIG_HOME/ghostty/config_

: Location of the default user configuration file.

_\$XDG_CONFIG_DIRS/ghostty/config_

: Location of the default system configuration files.

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

**XDG_CONFIG_DIRS**

: Colon separated list of paths to load configuration files.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See GitHub issues: <https://github.com/ghostty-org/ghostty/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>

# SEE ALSO

**ghostty(5)**
