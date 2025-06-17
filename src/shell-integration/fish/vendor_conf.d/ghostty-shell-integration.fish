# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    if contains cursor $features
        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -d "Set cursor shape"
            echo -en "\e[5 q"
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            echo -en "\e[0 q"
        end
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test "file" = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags "no"
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- "-e" "$arg"; or string match -q -- "--edit" "$arg"
                    set --function sudo_has_sudoedit_flags "yes"
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = "yes"
                command sudo $argv
            else
                command sudo TERMINFO="$TERMINFO" $argv
            end
        end
    end

    # SSH integration wrapper
    if test -n "$GHOSTTY_SSH_INTEGRATION"
        function ssh -d "Wrap ssh to provide Ghostty SSH integration"
            switch "$GHOSTTY_SSH_INTEGRATION"
                case term-only
                    _ghostty_ssh_term-only $argv
                case basic
                    _ghostty_ssh_basic $argv
                case full
                    _ghostty_ssh_full $argv
                case "*"
                    # Unknown level, fall back to basic
                    _ghostty_ssh_basic $argv
            end
        end

        # Level: term-only - Just fix TERM compatibility
        function _ghostty_ssh_term-only -d "SSH with TERM compatibility fix"
            if test "$TERM" = "xterm-ghostty"
                TERM=xterm-256color builtin command ssh $argv
            else
                builtin command ssh $argv
            end
        end

        # Level: basic - TERM fix + environment variable propagation
        function _ghostty_ssh_basic -d "SSH with TERM fix and environment propagation"
            # Build environment variables to propagate
            set --local env_vars

            # Fix TERM compatibility
            if test "$TERM" = "xterm-ghostty"
                set --append env_vars TERM=xterm-256color
            end

            # Propagate Ghostty shell integration environment variables
            if test -n "$GHOSTTY_SHELL_FEATURES"
                set --append env_vars GHOSTTY_SHELL_FEATURES="$GHOSTTY_SHELL_FEATURES"
            end

            # Execute with environment variables if any were set
            if test "$(count $env_vars)" -gt 0
                env $env_vars ssh $argv
            else
                builtin command ssh $argv
            end
        end

        # Level: full - All features
        function _ghostty_ssh_full
            # Full integration: Two-step terminfo installation
            if type -q infocmp
                echo "Installing Ghostty terminfo on remote host..." >&2

                # Step 1: Install terminfo 
                if infocmp -x xterm-ghostty 2>/dev/null | ssh $argv 'tic -x - 2>/dev/null'
                    echo "Terminfo installed successfully. Connecting with full Ghostty support..." >&2
                    
                    # Step 2: Connect with xterm-ghostty since we know terminfo is now available
                    set --local env_vars TERM=xterm-ghostty
                    
                    # Propagate Ghostty shell integration environment variables
                    if test -n "$GHOSTTY_SHELL_FEATURES"
                        set --append env_vars GHOSTTY_SHELL_FEATURES="$GHOSTTY_SHELL_FEATURES"
                    end
                    
                    env $env_vars ssh $argv
                    builtin return 0
                end
                echo "Terminfo installation failed. Using basic integration." >&2
            end

            # Fallback to basic integration
            _ghostty_ssh_basic $argv
        end
    end
    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_cancel --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en "\e]133;A\a"
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "\e]133;C\a"
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        printf \e\]7\;file://%s%s\a $hostname (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if contains cursor $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
