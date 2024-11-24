# This is originally based on the recommended bash integration from
# the semantic prompts proposal as well as some logic from Kitty's
# bash integration.
#
# I'm not a bash expert so this probably has some major issues but for
# my simple bash usage this is working. If a bash expert wants to
# improve this please do!

# We need to be in interactive mode and we need to have the Ghostty
# resources dir set which also tells us we're running in Ghostty.
if [[ "$-" != *i* ]] ; then builtin return; fi
if [ -z "$GHOSTTY_RESOURCES_DIR" ]; then builtin return; fi

# When automatic shell integration is active, we need to manually
# load the normal bash startup files based on the injected state.
if [ -n "$GHOSTTY_BASH_INJECT" ]; then
  builtin declare ghostty_bash_inject="$GHOSTTY_BASH_INJECT"
  builtin unset GHOSTTY_BASH_INJECT ENV

  # At this point, we're in POSIX mode and rely on the injected
  # flags to guide is through the rest of the startup sequence.

  # POSIX mode was requested by the user so there's nothing
  # more to do that optionally source their original $ENV.
  # No other startup files are read, per the standard.
  if [[ "$ghostty_bash_inject" == *"--posix"* ]]; then
    if [ -n "$GHOSTTY_BASH_ENV" ]; then
      builtin source "$GHOSTTY_BASH_ENV"
      builtin export ENV="$GHOSTTY_BASH_ENV"
    fi
  else
    # Restore bash's default 'posix' behavior. Also reset 'inherit_errexit',
    # which doesn't happen as part of the 'posix' reset.
    builtin set +o posix
    builtin shopt -u inherit_errexit 2>/dev/null

    # Unexport HISTFILE if it was set by the shell integration code.
    if [[ -n "$GHOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
      builtin export -n HISTFILE
      builtin unset GHOSTTY_BASH_UNEXPORT_HISTFILE
    fi

    # Manually source the startup files, respecting the injected flags like
    # --norc and --noprofile that we parsed with the shell integration code.
    #
    # See also: run_startup_files() in shell.c in the Bash source code
    if builtin shopt -q login_shell; then
      if [[ $ghostty_bash_inject != *"--noprofile"* ]]; then
        [ -r /etc/profile ] && builtin source "/etc/profile"
        for rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          [ -r "$rcfile" ] && { builtin source "$rcfile"; break; }
        done
      fi
    else
      if [[ $ghostty_bash_inject != *"--norc"* ]]; then
        # The location of the system bashrc is determined at bash build
        # time via -DSYS_BASHRC and can therefore vary across distros:
        #  Arch, Debian, Ubuntu use /etc/bash.bashrc
        #  Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
        #  Void Linux uses /etc/bash/bashrc
        for rcfile in /etc/bash.bashrc /etc/bash/bashrc ; do
          [ -r "$rcfile" ] && { builtin source "$rcfile"; break; }
        done
        if [[ -z "$GHOSTTY_BASH_RCFILE" ]]; then GHOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
        [ -r "$GHOSTTY_BASH_RCFILE" ] && builtin source "$GHOSTTY_BASH_RCFILE"
      fi
    fi
  fi

  builtin unset GHOSTTY_BASH_ENV GHOSTTY_BASH_RCFILE
  builtin unset ghostty_bash_inject rcfile
fi

# Import bash-preexec, safe to do multiple times
builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/bash-preexec.sh"

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_ghostty_executing=""
_ghostty_last_reported_cwd=""

function __ghostty_get_current_command() {
    builtin local last_cmd
    # shellcheck disable=SC1007
    last_cmd=$(HISTTIMEFORMAT= builtin history 1)
    last_cmd="${last_cmd#*[[:digit:]]*[[:space:]]}"  # remove leading history number
    last_cmd="${last_cmd#"${last_cmd%%[![:space:]]*}"}"  # remove remaining leading whitespace
    builtin printf "\e]2;%s\a" "${last_cmd//[[:cntrl:]]}"  # remove any control characters
}

function __ghostty_precmd() {
    local ret="$?"
    if test "$_ghostty_executing" != "0"; then
      _GHOSTTY_SAVE_PS0="$PS0"
      _GHOSTTY_SAVE_PS1="$PS1"
      _GHOSTTY_SAVE_PS2="$PS2"

      # Marks
      PS1=$PS1'\[\e]133;B\a\]'
      PS2=$PS2'\[\e]133;B\a\]'

      if [[ "${PS1}" == *"\n"* || "${PS1}" == *$'\n'* ]]; then
        # bash doesn't redraw the leading lines in a multiline prompt so
        # mark the last line as a secondary prompt (k=s) to prevent the
        # preceding lines from being erased by ghostty after a resize.
        builtin local oldval
        oldval=$(builtin shopt -p extglob)
        builtin shopt -s extglob
        PS1=${PS1%@('\n'|$'\n')*}'\n\[\e]133;A;k=s\a\]'${PS1##*@('\n'|$'\n')}
        builtin eval "$oldval"
      fi

      # Cursor
      if test "$GHOSTTY_SHELL_INTEGRATION_NO_CURSOR" != "1"; then
        PS1=$PS1'\[\e[5 q\]'
        PS0=$PS0'\[\e[0 q\]'
      fi

      # Sudo
      if [[ "$GHOSTTY_SHELL_INTEGRATION_NO_SUDO" != "1" ]] && [[ -n "$TERMINFO" ]]; then
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        # shellcheck disable=SC2317
        sudo() {
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

      if [[ "$GHOSTTY_SHELL_INTEGRATION_NO_TITLE" != 1 ]]; then
        # Command and working directory
        # shellcheck disable=SC2016
        PS0=$PS0'$(__ghostty_get_current_command)'
        PS1=$PS1'\[\e]2;$PWD\a\]'
      fi
    fi

    if test "$_ghostty_executing" != ""; then
      # End of current command. Report its status.
      builtin printf "\033]133;D;%s;aid=%s\007" "$ret" "$BASHPID"
    fi

    # unfortunately bash provides no hooks to detect cwd changes
    # in particular this means cwd reporting will not happen for a
    # command like cd /test && cat. PS0 is evaluated before cd is run.
    if [[ "$_ghostty_last_reported_cwd" != "$PWD" ]]; then
      _ghostty_last_reported_cwd="$PWD"
      builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
    fi

    # Fresh line and start of prompt.
    builtin printf "\033]133;A;aid=%s\007" "$BASHPID"
    _ghostty_executing=0
}

function __ghostty_preexec() {
    PS0="$_GHOSTTY_SAVE_PS0"
    PS1="$_GHOSTTY_SAVE_PS1"
    PS2="$_GHOSTTY_SAVE_PS2"
    builtin printf "\033]133;C;\007"
    _ghostty_executing=1
}

preexec_functions+=(__ghostty_preexec)
precmd_functions+=(__ghostty_precmd)
