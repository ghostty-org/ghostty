# Parts of this script are based on Kitty's bash integration. Kitty is
# distributed under GPLv3, so this file is also distributed under GPLv3.
# The license header is reproduced below:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# We need to be in interactive mode to proceed.
if [[ "$-" != *i* ]] ; then builtin return; fi

# When automatic shell integration is active, we were started in POSIX
# mode and need to manually recreate the bash startup sequence.
if [ -n "$GHOSTTY_BASH_INJECT" ]; then
  # Store a temporary copy of our startup flags and unset these global
  # environment variables so we can safely handle reentrancy.
  builtin declare __ghostty_bash_flags="$GHOSTTY_BASH_INJECT"
  builtin unset ENV GHOSTTY_BASH_INJECT

  # Restore bash's default 'posix' behavior. Also reset 'inherit_errexit',
  # which doesn't happen as part of the 'posix' reset.
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null

  # Unexport HISTFILE if it was set by the shell integration code.
  if [[ -n "$GHOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
    builtin export -n HISTFILE
    builtin unset GHOSTTY_BASH_UNEXPORT_HISTFILE
  fi

  # Manually source the startup files. See INVOCATION in bash(1) and
  # run_startup_files() in shell.c in the Bash source code.
  if builtin shopt -q login_shell; then
    if [[ $__ghostty_bash_flags != *"--noprofile"* ]]; then
      [ -r /etc/profile ] && builtin source "/etc/profile"
      for __ghostty_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        [ -r "$__ghostty_rcfile" ] && { builtin source "$__ghostty_rcfile"; break; }
      done
    fi
  else
    if [[ $__ghostty_bash_flags != *"--norc"* ]]; then
      # The location of the system bashrc is determined at bash build
      # time via -DSYS_BASHRC and can therefore vary across distros:
      #  Arch, Debian, Ubuntu use /etc/bash.bashrc
      #  Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
      #  Void Linux uses /etc/bash/bashrc
      #  Nixos uses /etc/bashrc
      for __ghostty_rcfile in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
        [ -r "$__ghostty_rcfile" ] && { builtin source "$__ghostty_rcfile"; break; }
      done
      if [[ -z "$GHOSTTY_BASH_RCFILE" ]]; then GHOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
      [ -r "$GHOSTTY_BASH_RCFILE" ] && builtin source "$GHOSTTY_BASH_RCFILE"
    fi
  fi

  builtin unset __ghostty_rcfile
  builtin unset __ghostty_bash_flags
  builtin unset GHOSTTY_BASH_RCFILE
fi

# Sudo
if [[ "$GHOSTTY_SHELL_FEATURES" == *"sudo"* && -n "$TERMINFO" ]]; then
  # Wrap `sudo` command to ensure Ghostty terminfo is preserved.
  #
  # This approach supports wrapping a `sudo` alias, but the alias definition
  # must come _after_ this function is defined. Otherwise, the alias expansion
  # will take precedence over this function, and it won't be wrapped.
  function sudo {
    builtin local sudo_has_sudoedit_flags="no"
    for arg in "$@"; do
      # Check if argument is '-e' or '--edit' (sudoedit flags)
      if [[ "$arg" == "-e" || $arg == "--edit" ]]; then
        sudo_has_sudoedit_flags="yes"
        builtin break
      fi
      # Check if argument is neither an option nor a key-value pair
      if [[ "$arg" != -* && "$arg" != *=* ]]; then
        builtin break
      fi
    done
    if [[ "$sudo_has_sudoedit_flags" == "yes" ]]; then
      builtin command sudo "$@";
    else
      builtin command sudo TERMINFO="$TERMINFO" "$@";
    fi
  }
fi

# SSH Integration
if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-(env|terminfo) ]]; then
  ssh() {
    builtin local ssh_env ssh_opts ssh_exported_vars
    ssh_env=()
    ssh_opts=()
    ssh_exported_vars=()

    # Configure environment variables for remote session
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env ]]; then
      ssh_opts+=(-o "SetEnv COLORTERM=truecolor")

      if [[ -n "${TERM_PROGRAM+x}" ]]; then
        ssh_exported_vars+=("TERM_PROGRAM=${TERM_PROGRAM}")
      else
        ssh_exported_vars+=("TERM_PROGRAM")
      fi
      builtin export "TERM_PROGRAM=ghostty"
      ssh_opts+=(-o "SendEnv TERM_PROGRAM")

      if [[ -n "$TERM_PROGRAM_VERSION" ]]; then
        if [[ -n "${TERM_PROGRAM_VERSION+x}" ]]; then
          ssh_exported_vars+=("TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION}")
        else
          ssh_exported_vars+=("TERM_PROGRAM_VERSION")
        fi
        ssh_opts+=(-o "SendEnv TERM_PROGRAM_VERSION")
      fi

      ssh_env+=(
        "COLORTERM=truecolor"
        "TERM_PROGRAM=ghostty"
      )
      if [[ -n "$TERM_PROGRAM_VERSION" ]]; then
        ssh_env+=("TERM_PROGRAM_VERSION=$TERM_PROGRAM_VERSION")
      fi
    fi

    # Install terminfo on remote host if needed
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-terminfo ]]; then
      builtin local ssh_config ssh_user ssh_hostname
      ssh_config=$(builtin command ssh -G "$@" 2>/dev/null)

      while IFS=' ' read -r ssh_key ssh_value; do
        case "$ssh_key" in
          user) ssh_user="$ssh_value" ;;
          hostname) ssh_hostname="$ssh_value" ;;
        esac
        [[ -n "$ssh_user" && -n "$ssh_hostname" ]] && break
      done <<< "$ssh_config"

      ssh_target="${ssh_user}@${ssh_hostname}"

      if [[ -n "$ssh_hostname" ]]; then
        # Check if terminfo is already cached
        builtin local ssh_cache_check_success=false
        if builtin command -v ghostty >/dev/null 2>&1; then
          ghostty +ssh-cache --host="$ssh_target" >/dev/null 2>&1 && ssh_cache_check_success=true
        fi

        if [[ "$ssh_cache_check_success" == "true" ]]; then
          ssh_env+=(TERM=xterm-ghostty)
        elif builtin command -v infocmp >/dev/null 2>&1; then
          if ! builtin command -v base64 >/dev/null 2>&1; then
            builtin echo "Warning: base64 command not available for terminfo installation." >&2
            ssh_env+=(TERM=xterm-256color)
          else
            builtin local ssh_terminfo ssh_base64_decode_cmd

            # BSD vs GNU base64 compatibility
            if base64 --help 2>&1 | grep -q GNU; then
              ssh_base64_decode_cmd="base64 -d"
              ssh_terminfo=$(infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | base64 -w0 2>/dev/null)
            else
              ssh_base64_decode_cmd="base64 -D"
              ssh_terminfo=$(infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | base64 2>/dev/null | tr -d '\n')
            fi

            if [[ -n "$ssh_terminfo" ]]; then
              builtin echo "Setting up Ghostty terminfo on $ssh_hostname..." >&2
              builtin local ssh_cpath_dir ssh_cpath

              ssh_cpath_dir=$(mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null) || ssh_cpath_dir="/tmp/ghostty-ssh-$ssh_user.$$"
              ssh_cpath="$ssh_cpath_dir/socket"

              if builtin echo "$ssh_terminfo" | $ssh_base64_decode_cmd | builtin command ssh "${ssh_opts[@]}" -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s "$@" '
                infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                command -v tic >/dev/null 2>&1 || exit 1
                mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                exit 1
              ' 2>/dev/null; then
                builtin echo "Terminfo setup complete on $ssh_hostname." >&2
                ssh_env+=(TERM=xterm-ghostty)
                ssh_opts+=(-o "ControlPath=$ssh_cpath")

                # Cache successful installation
                if [[ -n "$ssh_target" ]] && builtin command -v ghostty >/dev/null 2>&1; then
                  (
                    set +m
                    {
                      ghostty +ssh-cache --add="$ssh_target" >/dev/null 2>&1 || true
                    } &
                  )
                fi
              else
                builtin echo "Warning: Failed to install terminfo." >&2
                ssh_env+=(TERM=xterm-256color)
              fi
            else
              builtin echo "Warning: Could not generate terminfo data." >&2
              ssh_env+=(TERM=xterm-256color)
            fi
          fi
        else
          builtin echo "Warning: ghostty command not available for cache management." >&2
          ssh_env+=(TERM=xterm-256color)
        fi
      else
        if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env ]]; then
          ssh_env+=(TERM=xterm-256color)
        fi
      fi
    fi

    # Execute SSH with environment handling
    builtin local ssh_term_override=""
    for ssh_v in "${ssh_env[@]}"; do
      if [[ "$ssh_v" =~ ^TERM=(.*)$ ]]; then
        ssh_term_override="${BASH_REMATCH[1]}"
        break
      fi
    done

    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env && -z "$ssh_term_override" ]]; then
      ssh_env+=(TERM=xterm-256color)
      ssh_term_override="xterm-256color"
    fi

    if [[ -n "$ssh_term_override" ]]; then
      builtin local ssh_original_term="$TERM"
      builtin export TERM="$ssh_term_override"
      builtin command ssh "${ssh_opts[@]}" "$@"
      local ssh_ret=$?
      builtin export TERM="$ssh_original_term"
    else
      builtin command ssh "${ssh_opts[@]}" "$@"
      local ssh_ret=$?
    fi

    # Restore original environment variables
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env ]]; then
      for ssh_v in "${ssh_exported_vars[@]}"; do
        if [[ "$ssh_v" == *=* ]]; then
          builtin export "${ssh_v?}"
        else
          builtin unset "${ssh_v}"
        fi
      done
    fi

    return $ssh_ret
  }
fi

# Import bash-preexec, safe to do multiple times
builtin source "$(dirname -- "${BASH_SOURCE[0]}")/bash-preexec.sh"

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_ghostty_executing=""
_ghostty_last_reported_cwd=""

function __ghostty_precmd() {
    local ret="$?"
    if test "$_ghostty_executing" != "0"; then
      _GHOSTTY_SAVE_PS1="$PS1"
      _GHOSTTY_SAVE_PS2="$PS2"

      # Marks
      PS1=$PS1'\[\e]133;B\a\]'
      PS2=$PS2'\[\e]133;B\a\]'

      # bash doesn't redraw the leading lines in a multiline prompt so
      # mark the last line as a secondary prompt (k=s) to prevent the
      # preceding lines from being erased by ghostty after a resize.
      if [[ "${PS1}" == *"\n"* || "${PS1}" == *$'\n'* ]]; then
        PS1=$PS1'\[\e]133;A;k=s\a\]'
      fi

      # Cursor
      if [[ "$GHOSTTY_SHELL_FEATURES" == *"cursor"* ]]; then
        PS1=$PS1'\[\e[5 q\]'      # blinking bar for input
        builtin printf "\e[0 q"   # reset to default cursor
      fi

      # Title (working directory)
      if [[ "$GHOSTTY_SHELL_FEATURES" == *"title"* ]]; then
        PS1=$PS1'\[\e]2;\w\a\]'
      fi
    fi

    if test "$_ghostty_executing" != ""; then
      # End of current command. Report its status.
      builtin printf "\e]133;D;%s;aid=%s\a" "$ret" "$BASHPID"
    fi

    # unfortunately bash provides no hooks to detect cwd changes
    # in particular this means cwd reporting will not happen for a
    # command like cd /test && cat. PS0 is evaluated before cd is run.
    if [[ "$_ghostty_last_reported_cwd" != "$PWD" ]]; then
      _ghostty_last_reported_cwd="$PWD"
      builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
    fi

    # Fresh line and start of prompt.
    builtin printf "\e]133;A;aid=%s\a" "$BASHPID"
    _ghostty_executing=0
}

function __ghostty_preexec() {
    builtin local cmd="$1"

    PS1="$_GHOSTTY_SAVE_PS1"
    PS2="$_GHOSTTY_SAVE_PS2"

    # Title (current command)
    if [[ -n $cmd && "$GHOSTTY_SHELL_FEATURES" == *"title"* ]]; then
      builtin printf "\e]2;%s\a" "${cmd//[[:cntrl:]]}"
    fi

    # End of input, start of output.
    builtin printf "\e]133;C;\a"
    _ghostty_executing=1
}

preexec_functions+=(__ghostty_preexec)
precmd_functions+=(__ghostty_precmd)
