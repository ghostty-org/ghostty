# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that Ghostty
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or [ghostty.org](https://ghostty.org/docs)

## Implementation Details

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/ghostty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/ghostty.bash`.
This also works for older versions of Bash.

```bash
# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Elvish

For [Elvish](https://elv.sh), `$GHOSTTY_RESOURCES_DIR/src/shell-integration`
contains an `./elvish/lib/ghostty-integration.elv` file.

Elvish, on startup, searches for paths defined in `XDG_DATA_DIRS`
variable for `./elvish/lib/*.elv` files and imports them. They are thus
made available for use as modules by way of `use <filename>`.

Ghostty launches Elvish, passing the environment with `XDG_DATA_DIRS`prepended
with `$GHOSTTY_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/ghostty-integration.elv`. The user can then import it
by `use ghostty-integration`, which will run the integration routines.

The [Elvish](https://elv.sh) shell integration is supported by
the community and is not officially supported by Ghostty. We distribute
it for ease of access and use but do not provide support for it.
If you experience issues with the Elvish shell integration, I welcome
any contributions to fix them. Thank you!

### Fish

For [Fish](https://fishshell.com/), Ghostty prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Zsh

For `zsh`, Ghostty sets `ZDOTDIR` so that it loads our configuration
from the `zsh` directory. The existing `ZDOTDIR` is retained so that
after loading the Ghostty shell integration the normal Zsh loading
sequence occurs.

```bash
if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
  source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
fi
```
