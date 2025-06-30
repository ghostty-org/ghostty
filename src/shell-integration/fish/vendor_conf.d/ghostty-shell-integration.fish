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

    # SSH Integration
    if string match -qr 'ssh-(env|terminfo)' $GHOSTTY_SHELL_FEATURES

        if string match -q '*ssh-terminfo*' $GHOSTTY_SHELL_FEATURES
            set -g _CACHE "$GHOSTTY_RESOURCES_DIR/shell-integration/shared/ghostty-ssh-cache"
        end

        # SSH wrapper
        function ssh
            set -l env
            set -l opts
            set -l ctrl

            # Set up env vars first so terminfo installation inherits them
            if string match -q '*ssh-env*' $GHOSTTY_SHELL_FEATURES
                set -l vars \
                    COLORTERM=truecolor \
                    TERM_PROGRAM=ghostty

                if test -n "$TERM_PROGRAM_VERSION"
                    set -a vars "TERM_PROGRAM_VERSION=$TERM_PROGRAM_VERSION"
                end

                for v in $vars
                    set -l parts (string split = $v)
                    set -gx $parts[1] $parts[2]
                    set -a opts -o "SendEnv $parts[1]" -o "SetEnv $v"
                end
            end

            # Install terminfo if needed, reuse control connection for main session
            if string match -q '*ssh-terminfo*' $GHOSTTY_SHELL_FEATURES
                # Get target
                set -l target (command ssh -G $argv 2>/dev/null | awk '/^(user|hostname) /{print $2}' | paste -sd'@')

                if test -n "$target" -a ("$_CACHE" chk "$target")
                    set -a env TERM=xterm-ghostty
                else if command -v infocmp >/dev/null 2>&1
                    set -l tinfo (infocmp -x xterm-ghostty 2>/dev/null)
                    set -l status_code $status

                    if test $status_code -ne 0
                        echo "Warning: xterm-ghostty terminfo not found locally." >&2
                    end

                    if test -n "$tinfo"
                        echo "Setting up Ghostty terminfo on remote host..." >&2
                        set -l cpath "/tmp/ghostty-ssh-$USER-"(random)"-"(date +%s)
                        set -l result (echo "$tinfo" | command ssh $opts -o ControlMaster=yes -o ControlPath="$cpath" -o ControlPersist=60s $argv '
                            infocmp xterm-ghostty >/dev/null 2>&1 && echo OK && exit
                            command -v tic >/dev/null 2>&1 || { echo NO_TIC; exit 1; }
                            mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && echo OK || echo FAIL
                        ')

                        switch $result
                            case OK
                                echo "Terminfo setup complete." >&2
                                test -n "$target" && "$_CACHE" add "$target"
                                set -a env TERM=xterm-ghostty
                                set -a ctrl -o "ControlPath=$cpath"
                            case '*'
                                echo "Warning: Failed to install terminfo." >&2
                        end
                    end
                else
                    echo "Warning: infocmp not found locally. Terminfo installation unavailable." >&2
                end
            end

            # Fallback TERM only if terminfo didn't set it
            if string match -q '*ssh-env*' $GHOSTTY_SHELL_FEATURES
                if test "$TERM" = xterm-ghostty -a ! (string join ' ' $env | string match -q '*TERM=*')
                    set -a env TERM=xterm-256color
                end
            end

            # Execute
            if test (count $env) -gt 0
                env $env command ssh $opts $ctrl $argv
            else
                command ssh $opts $ctrl $argv
            end
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
