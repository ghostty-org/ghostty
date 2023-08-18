#!/usr/bin/env bash
#
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

# Import bash-preexec, safe to do multiple times
builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/bash-preexec.sh"

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_ghostty_executing=""
_ghostty_last_reported_cwd=""

function __ghostty_get_current_command() {
    builtin local last_cmd
    last_cmd=$(HISTTIMEFORMAT= builtin history 1)
    last_cmd="${last_cmd#*[[:digit:]]*[[:space:]]}"  # remove leading history number
    last_cmd="${last_cmd#"${last_cmd%%[![:space:]]*}"}"  # remove remaining leading whitespace
    builtin printf "\e]2;%s\a" "${last_cmd//[[:cntrl:]]}"  # remove any control characters
}

function __ghostty_precmd() {
    local ret="$?"
    if test "$_ghostty_executing" != "0"; then
      _GHOSTTY_SAVE_PS1="$PS1"
      _GHOSTTY_SAVE_PS2="$PS2"

      # Marks
      PS1=$PS1'\e]133;B\a'
      PS2=$PS2'\e]133;B\a'

      # Cursor
      PS1=$PS1'\e[5 q'
      PS0=$PS0'\e[0 q'

      # Command
      PS0=$PS0'$(__ghostty_get_current_command)'
      PS1=$PS1'\e]2;$PWD\a'
    fi

    if test "$_ghostty_executing" != ""; then
      builtin printf "\033]133;D;%s;aid=%s\007" "$ret" "$BASHPID"
    fi

    # unfortunately bash provides no hooks to detect cwd changes
    # in particular this means cwd reporting will not happen for a
    # command like cd /test && cat. PS0 is evaluated before cd is run.
    if [[ "$_ghostty_last_reported_cwd" != "$PWD" ]]; then
      _ghostty_last_reported_cwd="$PWD"
      builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
    fi

    builtin printf "\033]133;A;aid=%s\007" "$BASHPID"
    _ghostty_executing=0
}

function __ghostty_preexec() {
    PS1="$_GHOSTTY_SAVE_PS1"
    PS2="$_GHOSTTY_SAVE_PS2"
    builtin printf "\033]133;C;\007"
    _ghostty_executing=1
}

preexec_functions+=(__ghostty_preexec)
precmd_functions+=(__ghostty_precmd)
