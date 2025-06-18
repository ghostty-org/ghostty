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

# SSH
if [[ -n "$GHOSTTY_SSH_INTEGRATION" ]]; then
  # Cache configuration
  _ghostty_cache_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ghostty"
  _ghostty_cache_file="$_ghostty_cache_dir/terminfo_hosts"

  # Create cache directory with proper permissions
  [[ ! -d "$_ghostty_cache_dir" ]] && mkdir -p "$_ghostty_cache_dir" && chmod 700 "$_ghostty_cache_dir"

  # Extract SSH target from arguments
  _ghostty_get_ssh_target() {
    local target=""
    local skip_next=false
    local args=("$@")

    for ((i=0; i<${#args[@]}; i++)); do
      local arg="${args[i]}"

      # Skip if we're processing a flag's argument
      [[ "$skip_next" == "true" ]] && { skip_next=false; continue; }

      # Handle flags that take arguments
      if [[ "$arg" =~ ^-[bcDEeFIiJLlmOopQRSWw]$ ]]; then
        skip_next=true
        continue
      fi

      # Handle combined short flags with values (e.g., -p22)
      [[ "$arg" =~ ^-[bcDEeFIiJLlmOopQRSWw].+ ]] && continue

      # Skip other flags
      [[ "$arg" =~ ^- ]] && continue

      # This should be our target
      target="$arg"
      break
    done

    # Handle user@host format
    echo "${target##*@}"
  }

  # Check if host has terminfo cached
  _ghostty_host_has_terminfo() {
    local host="$1"
    [[ -f "$_ghostty_cache_file" ]] && grep -qFx "$host" "$_ghostty_cache_file" 2>/dev/null
  }

  # Add host to cache atomically
  _ghostty_cache_host() {
    local host="$1"
    local temp_file
    temp_file="$_ghostty_cache_file.$$"

    # Merge existing cache with new host
    {
      [[ -f "$_ghostty_cache_file" ]] && cat "$_ghostty_cache_file"
      echo "$host"
    } | sort -u > "$temp_file"

    # Atomic replace with proper permissions
    mv -f "$temp_file" "$_ghostty_cache_file" && chmod 600 "$_ghostty_cache_file"
  }

  # Remove host from cache (for maintenance)
  _ghostty_uncache_host() {
    local host="$1"
    [[ -f "$_ghostty_cache_file" ]] || return 0

    local temp_file="$_ghostty_cache_file.$$"
    grep -vFx "$host" "$_ghostty_cache_file" > "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$_ghostty_cache_file"
  }

  # Main SSH wrapper
  ssh() {
    case "$GHOSTTY_SSH_INTEGRATION" in
      term-only) _ghostty_ssh_term_only "$@" ;;
      basic)     _ghostty_ssh_basic "$@" ;;
      full)      _ghostty_ssh_full "$@" ;;
      *)         _ghostty_ssh_basic "$@" ;;  # Default to basic
    esac
  }

  # Level: term-only - Just fix TERM compatibility
  _ghostty_ssh_term_only() {
    if [[ "$TERM" == "xterm-ghostty" ]]; then
      TERM=xterm-256color builtin command ssh "$@"
    else
      builtin command ssh "$@"
    fi
  }

  # Level: basic - TERM fix + environment propagation
  _ghostty_ssh_basic() {
    local term_value
    term_value=$([[ "$TERM" == "xterm-ghostty" ]] && echo "xterm-256color" || echo "$TERM")

    builtin command ssh "$@" "
      # Set environment for this session
      export GHOSTTY_SHELL_FEATURES='$GHOSTTY_SHELL_FEATURES'
      export TERM='$term_value'

      # Start interactive shell
      exec \$SHELL -l
    "
  }

  # Level: full - Complete integration with terminfo
  _ghostty_ssh_full() {
    local target
    target="$(_ghostty_get_ssh_target "$@")"

    # Quick path for cached hosts
    if [[ -n "$target" ]] && _ghostty_host_has_terminfo "$target"; then
      # Direct connection with full ghostty support
      builtin command ssh -t "$@" "
        export GHOSTTY_SHELL_FEATURES='$GHOSTTY_SHELL_FEATURES'
        export TERM='xterm-ghostty'
        exec \$SHELL -l
      "
      return $?
    fi

    # Check if we can export terminfo
    if ! builtin command -v infocmp >/dev/null 2>&1; then
      echo "Warning: infocmp not found locally. Using basic integration." >&2
      _ghostty_ssh_basic "$@"
      return $?
    fi

    # Generate terminfo data
    local terminfo_data
    terminfo_data="$(infocmp -x xterm-ghostty 2>/dev/null)" || {
      echo "Warning: xterm-ghostty terminfo not found locally. Using basic integration." >&2
      _ghostty_ssh_basic "$@"
      return $?
    }

    echo "Setting up Ghostty terminal support on remote host..." >&2

    # Create control socket path
    local control_path="/tmp/ghostty-ssh-${USER}-$"
    trap "rm -f '$control_path'" EXIT

    # Start control master and check/install terminfo
    local setup_script='
      if ! infocmp xterm-ghostty >/dev/null 2>&1; then
        if command -v tic >/dev/null 2>&1; then
          mkdir -p "$HOME/.terminfo" 2>/dev/null
          echo "NEEDS_INSTALL"
        else
          echo "NO_TIC"
        fi
      else
        echo "ALREADY_INSTALLED"
      fi
    '

    # First connection: Start control master and check status
    local install_status
    install_status=$(builtin command ssh -o ControlMaster=yes \
                                       -o ControlPath="$control_path" \
                                       -o ControlPersist=30s \
                                       "$@" "$setup_script")

    case "$install_status" in
      "NEEDS_INSTALL")
        echo "Installing xterm-ghostty terminfo..." >&2
        # Send terminfo through existing control connection
        if echo "$terminfo_data" | builtin command ssh -o ControlPath="$control_path" "$@" \
          'tic -x - 2>/dev/null && echo "SUCCESS"' | grep -q "SUCCESS"; then
          echo "Terminfo installed successfully." >&2
          [[ -n "$target" ]] && _ghostty_cache_host "$target"
        else
          echo "Warning: Failed to install terminfo. Using basic integration." >&2
          ssh -O exit -o ControlPath="$control_path" "$@" 2>/dev/null || true
          _ghostty_ssh_basic "$@"
          return $?
        fi
        ;;
      "ALREADY_INSTALLED")
        [[ -n "$target" ]] && _ghostty_cache_host "$target"
        ;;
      "NO_TIC")
        echo "Warning: tic not found on remote host. Using basic integration." >&2
        ssh -O exit -o ControlPath="$control_path" "$@" 2>/dev/null || true
        _ghostty_ssh_basic "$@"
        return $?
        ;;
    esac

    # Now use the existing control connection for interactive session
    echo "Connecting with full Ghostty support..." >&2

    # Pass environment through and start login shell to show MOTD
    builtin command ssh -t -o ControlPath="$control_path" "$@" "
      # Set up Ghostty environment
      export GHOSTTY_SHELL_FEATURES='$GHOSTTY_SHELL_FEATURES'
      export TERM='xterm-ghostty'

      # Display MOTD if this is a fresh connection
      if [[ '$install_status' == 'NEEDS_INSTALL' ]]; then
        # Try to display MOTD manually
        if [[ -f /etc/motd ]]; then
          cat /etc/motd 2>/dev/null || true
        fi
        # Run update-motd if available (Ubuntu/Debian)
        if [[ -d /etc/update-motd.d ]]; then
          run-parts /etc/update-motd.d 2>/dev/null || true
        fi
      fi

      # Force a login shell
      exec \$SHELL -l
    "

    local exit_code=$?

    # Clean up control socket
    ssh -O exit -o ControlPath="$control_path" "$@" 2>/dev/null || true

    return $exit_code
  }

  # Utility function to clear cache for a specific host
  ghostty_ssh_reset() {
    local host="${1:-}"
    if [[ -z "$host" ]]; then
      echo "Usage: ghostty_ssh_reset <hostname>" >&2
      return 1
    fi

    _ghostty_uncache_host "$host"
    echo "Cleared Ghostty terminfo cache for: $host"
  }

  # Utility function to list cached hosts
  ghostty_ssh_list_cached() {
    if [[ -f "$_ghostty_cache_file" ]]; then
      echo "Hosts with cached Ghostty terminfo:"
      cat "$_ghostty_cache_file"
    else
      echo "No hosts cached yet."
    fi
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
      _GHOSTTY_SAVE_PS0="$PS0"
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
        PS1=$PS1'\[\e[5 q\]'
        PS0=$PS0'\[\e[0 q\]'
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

    PS0="$_GHOSTTY_SAVE_PS0"
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
