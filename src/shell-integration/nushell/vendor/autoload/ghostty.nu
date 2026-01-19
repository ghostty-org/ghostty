# Ghostty shell integration
export module ghostty {
  def has_feature [feature: string] {
    $feature in ($env.GHOSTTY_SHELL_FEATURES | default "" | split row ',')
  }

  # Wrap `sudo` to preserve Ghostty's TERMINFO environment variable
  export def --wrapped sudo [
    ...args  # Arguments to pass to `sudo`
  ] {
    mut sudo_args = $args

    if (has_feature "sudo") {
        # Extract just the sudo options (before the command)
        let sudo_options = ($args | take until {|arg|
            not (($arg | str starts-with "-") or ($arg | str contains "="))
        })

        # Prepend TERMINFO preservation flag if not using sudoedit
        if (not ("-e" in $sudo_options or "--edit" in $sudo_options)) {
            $sudo_args = ($args | prepend "--preserve-env=TERMINFO")
        }
    }

    ^sudo ...$sudo_args
  }
}

# Clean up XDG_DATA_DIRS by removing GHOSTTY_SHELL_INTEGRATION_XDG_DIR
if 'GHOSTTY_SHELL_INTEGRATION_XDG_DIR' in $env {
  if 'XDG_DATA_DIRS' in $env {
    $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR):" "")
  }
  hide-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR
}
