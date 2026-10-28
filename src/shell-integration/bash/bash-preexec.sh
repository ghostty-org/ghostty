# bash-preexec.sh -- Bash support for ZSH-like 'preexec' and 'precmd' functions.
# https://github.com/rcaloras/bash-preexec
#
#
# 'preexec' functions are executed before each interactive command is
# executed, with the interactive command as its argument. The 'precmd'
# function is executed before each prompt is displayed.
#
# Author: Ryan Caloras (ryan@bashhub.com)
# Forked from Original Author: Glyph Lefkowitz
#
# V0.7.0
#

# General Usage:
#
#  1. Source this file at the end of your bash profile so as not to interfere
#     with anything else that's using PROMPT_COMMAND.
#
#  2. Add any precmd or preexec functions by appending them to their arrays:
#       e.g.
#       precmd_functions+=(my_precmd_function)
#       precmd_functions+=(some_other_precmd_function)
#
#       preexec_functions+=(my_preexec_function)
#
#  3. Consider changing anything using the DEBUG trap or PROMPT_COMMAND
#     to use preexec and precmd instead. Preexisting usages will be
#     preserved, but doing so manually may be less surprising.
#
#  Note: This module requires two Bash features which you must not otherwise be
#  using: the "DEBUG" trap, and the "PROMPT_COMMAND" variable. If you override
#  either of these after bash-preexec has been installed it will most likely break.

# Tell shellcheck what kind of file this is.
# shellcheck shell=bash

# Make sure this is bash that's running and return otherwise.
# Use POSIX syntax for this line:
if [ -z "${BASH_VERSION-}" ]; then
    return 1
fi

# We only support Bash 3.1+.
# Note: BASH_VERSINFO is first available in Bash-2.0.
if [[ -z "${BASH_VERSINFO-}" ]] || (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 1) )); then
    return 1
fi

# Avoid duplicate inclusion
if [[ -n "${bash_preexec_imported:-}" || -n "${__bp_imported:-}" ]]; then
    return 0
fi
bash_preexec_imported="defined"

# WARNING: This variable is no longer used and should not be relied upon.
# Use ${bash_preexec_imported} instead.
# shellcheck disable=SC2034
__bp_imported="${bash_preexec_imported}"

# Should be available to each precmd and preexec
# functions, should they want it. $? and $_ are available as $? and $_, but
# $PIPESTATUS is available only in a copy, $BP_PIPESTATUS.
# TODO: Figure out how to restore PIPESTATUS before each precmd or preexec
# function.
__bp_last_ret_value="$?"
BP_PIPESTATUS=("${PIPESTATUS[@]}")
__bp_last_argument_prev_command="$_"

__bp_inside_precmd=0
__bp_inside_preexec=0

# Initial PROMPT_COMMAND string that is removed from PROMPT_COMMAND post __bp_install
# shellcheck disable=SC2016
__bp_install_string='__bp_install "$_"'

# Fails if any of the given variables are readonly
# Reference https://stackoverflow.com/a/4441178
__bp_require_not_readonly() {
    local var
    for var; do
        if ! ( unset "$var" 2> /dev/null ); then
            echo "bash-preexec requires write access to ${var}" >&2
            return 1
        fi
    done
}

# Remove ignorespace and or replace ignoreboth from HISTCONTROL
# so we can accurately invoke preexec with a command from our
# history even if it starts with a space.
__bp_adjust_histcontrol() {
    local histcontrol
    histcontrol="${HISTCONTROL:-}"
    histcontrol="${histcontrol//ignorespace}"
    # Replace ignoreboth with ignoredups
    if [[ "$histcontrol" == *"ignoreboth"* ]]; then
        histcontrol="ignoredups:${histcontrol//ignoreboth}"
    fi
    export HISTCONTROL="$histcontrol"
}

# This variable describes whether we are currently in "interactive mode";
# i.e. whether this shell has just executed a prompt and is waiting for user
# input.  It documents whether the current command invoked by the trace hook is
# run interactively by the user; it's set immediately after the prompt hook,
# and unset as soon as the trace hook is run.
__bp_preexec_interactive_mode=""

# These global arrays are used to add functions to be run before, or after,
# prompts.  Note that Bash < 4.2 does not have the "-g" option of the "declare"
# builtin.  We actually do not need to explicitly initialize these arrays.
#declare -ga precmd_functions
#declare -ga preexec_functions

# Trims leading and trailing whitespace from $2 and writes it to the variable
# name passed as $1
__bp_trim_whitespace() {
    local var=${1:?} text=${2:-}
    text="${text#"${text%%[![:space:]]*}"}"   # remove leading whitespace characters
    text="${text%"${text##*[![:space:]]}"}"   # remove trailing whitespace characters
    printf -v "$var" '%s' "$text"
}


# Trims whitespace and removes any leading or trailing semicolons from $2 and
# writes the resulting string to the variable name passed as $1. This also
# removes the no-op colons, which are converted from the hooks to remove. Used
# for manipulating substrings in PROMPT_COMMAND
__bp_sanitize_string() {
    local var=${1:?} sanitized=${2:-}

    local unset_extglob=
    if ! shopt -q extglob; then
        unset_extglob=yes
        shopt -s extglob
    fi

    # We specify newline character through the variable `nl' because $'\n'
    # inside "${var//...}" is treated literally as "\$'\\n'" when `extquote' is
    # unset (shopt -u extquote). (Note: Bash 5.2's extquote seems to be buggy.)
    local tmp nl=$'\n'
    while
        # Note: Quoting parameter expansions $nl in PAT of ${var//PAT/REP} is
        # required by shellcheck.  On the other hand, we should not quote the
        # parameter expansions $nl in REP because the quotes will remain in the
        # replaced result with `shopt -s compat42'.
        # Note: We use ?(+([[:blank:]])) instead of *([[:blank:]]) to work
        # around a bug of Bash 3.2 that *(...) is not properly processed as
        # extglob at the beginning of the pattern in ${var//pat/rep}.
        tmp="${sanitized//?(+([[:blank:]]))[";$nl"]*([[:blank:]]):*([[:blank:]])[";$nl"]*([[:blank:]])/$nl}"
        [[ "$tmp" != "$sanitized" ]]
    do
        sanitized="$tmp"
    done
    sanitized="${sanitized#:*([[:blank:]])[";$nl"]}"
    sanitized="${sanitized%[";$nl"]*([[:blank:]]):}"
    __bp_trim_whitespace sanitized "$sanitized"
    sanitized=${sanitized%;}
    sanitized=${sanitized#;}
    __bp_trim_whitespace sanitized "$sanitized"
    if [[ "$sanitized" == ":" ]]; then
        sanitized=
    fi
    printf -v "$var" '%s' "$sanitized"

    if [[ -n "$unset_extglob" ]]; then
        shopt -u extglob
    fi
}


# Bash >= 5.1 supports the array version of PROMPT_COMMAND.
__bp_use_array_prompt_command() {
    (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))
}


# Remove $1 and sanitize each elements of PROMPT_COMMAND. We want to keep
# PROMPT_COMMAND scalar in bash < 5.1 because some configuration tests the
# support for the array PROMPT_COMMAND by checking the array attribute of
# PROMPT_COMMAND.
__bp_remove_command_from_prompt_command() {
    local removed_command="${1-}"
    if __bp_use_array_prompt_command; then
        local i sanitized_prompt_command
        for i in "${!PROMPT_COMMAND[@]}"; do
            sanitized_prompt_command="${PROMPT_COMMAND[i]:-}"
            sanitized_prompt_command="${sanitized_prompt_command//"$removed_command"/:}"
            __bp_sanitize_string sanitized_prompt_command "$sanitized_prompt_command"
            if [[ -n "$sanitized_prompt_command" ]]; then
                PROMPT_COMMAND[i]="$sanitized_prompt_command"
            else
                unset -v 'PROMPT_COMMAND[i]'
            fi
        done
    else
        local sanitized_prompt_command="${PROMPT_COMMAND:-}"
        sanitized_prompt_command="${sanitized_prompt_command//"$removed_command"/:}" # no-op
        __bp_sanitize_string PROMPT_COMMAND "$sanitized_prompt_command"
    fi
}


# This function is installed as part of the PROMPT_COMMAND;
# It sets a variable to indicate that the prompt was just displayed,
# to allow the DEBUG trap to know that the next command is likely interactive.
__bp_interactive_mode() {
    if [[ "${1-}" != "force" && ! "${BATS_VERSION-}" ]] && (( ${#FUNCNAME[*]} > 1 )); then
        # When this function is not called from the top level, the current
        # function call is probably performed via PROMPT_COMMAND saved by
        # another framework (e.g., starship). In this case, we do not want to
        # turn on the "interactive mode" here.
        return 0
    fi

    __bp_preexec_interactive_mode="on"
}


# This function is installed as part of the PROMPT_COMMAND.
# It will invoke any functions defined in the precmd_functions array.
__bp_precmd_invoke_cmd() {
    # Save the returned value and the last argument from our last command, and
    # the returned value from each process in its pipeline. Note: this MUST be
    # the first thing done in this function.
    # BP_PIPESTATUS may be unused, ignore
    # shellcheck disable=SC2034
    __bp_last_ret_value="$?" __bp_last_argument_prev_command="$_" \
        BP_PIPESTATUS=("${PIPESTATUS[@]}")


    # Don't invoke precmds if we are inside an execution of an "original
    # prompt command" by another precmd execution loop. This avoids infinite
    # recursion.
    if (( __bp_inside_precmd > 0 )); then
        return "$__bp_last_ret_value"
    fi

    # Check and adjust PROMPT_COMMAND to make sure that PROMPT_COMMAND has the
    # form "__bp_precmd_invoke_cmd; ...; __bp_interactive_mode"
    if ! __bp_install_prompt_command; then
        if [[ "${1-}" != "force" && ! "${BATS_VERSION-}" ]] && (( ${#FUNCNAME[*]} > 1 )); then
            # When PROMPT_COMMAND is already properly set up but this function
            # is not called from the top level, the current function call is
            # probably performed via PROMPT_COMMAND saved by another framework
            # (e.g., starship). In this case, we do not need to invoke precmd
            # because it is supposed to be already processed by the top-level
            # __bp_precmd_invoke_cmd.
            return "$__bp_last_ret_value"
        fi
    fi

    local __bp_inside_precmd=1
    __bp_invoke_precmd_functions "$__bp_last_ret_value" "$__bp_last_argument_prev_command"

    __bp_set_ret_value "$__bp_last_ret_value" "$__bp_last_argument_prev_command"
}

# This function invokes every function defined in the "precmd_functions" array.
# This function receives the arguments $1 and $2 for $?  and $_, respectively,
# which will be set for each precmd function. This function returns the last
# non-zero exit status of the hook functions. If there is no error, this
# function returns 0.
__bp_invoke_precmd_functions() {
    local lastexit=$1 lastarg=$2
    # Invoke every function defined in our function array.
    local precmd_function
    local precmd_function_ret_value
    local precmd_ret_value=0
    for precmd_function in "${precmd_functions[@]}"; do

        # Only execute this function if it actually exists.
        # Test existence of functions with: declare -[Ff]
        if type -t "$precmd_function" 1>/dev/null; then
            __bp_set_ret_value "$lastexit" "$lastarg"
            # Quote our function invocation to prevent issues with IFS
            "$precmd_function"
            precmd_function_ret_value=$?
            if [[ "$precmd_function_ret_value" != 0 ]]; then
                precmd_ret_value="$precmd_function_ret_value"
            fi
        fi
    done

    __bp_set_ret_value "$precmd_ret_value"
}

# Sets a return value in $?. We may want to get access to the $? variable in our
# precmd functions. This is available for instance in zsh. We can simulate it in bash
# by setting the value here.
__bp_set_ret_value() {
    return ${1:+"$1"}
}

__bp_in_prompt_command() {

    local prompt_command_array IFS=$'\n;'
    read -rd '' -a prompt_command_array <<< "${PROMPT_COMMAND[*]:-}"

    local trimmed_arg
    __bp_trim_whitespace trimmed_arg "${1:-}"

    local command trimmed_command
    for command in "${prompt_command_array[@]:-}"; do
        __bp_trim_whitespace trimmed_command "$command"
        if [[ "$trimmed_command" == "$trimmed_arg" ]]; then
            return 0
        fi
    done

    return 1
}

__bp_load_this_command_from_history() {
    this_command=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    this_command="${this_command#*[[:digit:]][* ] }"

    # Sanity check to make sure we have something to invoke our function with.
    [[ -n "$this_command" ]]
}

# This function is installed as the DEBUG trap.  It is invoked before each
# interactive prompt display.  Its purpose is to inspect the current
# environment to attempt to detect if the current command is being invoked
# interactively, and invoke 'preexec' if so.
__bp_preexec_invoke_exec() {
    local lastarg=$_

    # Don't invoke preexecs if we are inside of another preexec.
    if (( __bp_inside_preexec > 0 )); then
        return
    fi
    local __bp_inside_preexec=1

    # Checks if the file descriptor is not standard out (i.e. '1')
    # __bp_delay_install checks if we're in test. Needed for bats to run.
    # Prevents preexec from being invoked for functions in PS1
    if [[ ! -t 1 && -z "${__bp_delay_install:-}" ]]; then
        return
    fi

    if [[ -n "${COMP_POINT:-}" || -n "${READLINE_POINT:-}" ]]; then
        # We're in the middle of a completer or a keybinding set up by "bind
        # -x".  This obviously can't be an interactively issued command.
        return
    fi
    if [[ -z "${__bp_preexec_interactive_mode:-}" ]]; then
        # We're doing something related to displaying the prompt.  Let the
        # prompt set the title instead of me.
        return
    else
        # If we're in a subshell, then the prompt won't be re-displayed to put
        # us back into interactive mode, so let's not set the variable back.
        # In other words, if you have a subshell like
        #   (sleep 1; sleep 2)
        # You want to see the 'sleep 2' as a set_command_title as well.
        if [[ 0 -eq "${BASH_SUBSHELL:-}" ]]; then
            __bp_preexec_interactive_mode=""
        fi
    fi

    if  __bp_in_prompt_command "${BASH_COMMAND:-}"; then
        # If we're executing something inside our prompt_command then we don't
        # want to call preexec. Bash prior to 3.1 can't detect this at all :/
        __bp_preexec_interactive_mode=""
        return
    fi

    # Save the contents of $_ so that it can be restored later on.
    # https://stackoverflow.com/questions/40944532/bash-preserve-in-a-debug-trap#40944702
    __bp_last_argument_prev_command=$lastarg

    local this_command
    __bp_load_this_command_from_history || return

    __bp_invoke_preexec_functions "${__bp_last_ret_value:-}" "$__bp_last_argument_prev_command" "$this_command"
    local preexec_ret_value=$?

    # Restore the last argument of the last executed command, and set the return
    # value of the DEBUG trap to be the return code of the last preexec function
    # to return an error.
    # If `extdebug` is enabled a non-zero return value from any preexec function
    # will cause the user's command not to execute.
    # Run `shopt -s extdebug` to enable
    __bp_set_ret_value "$preexec_ret_value" "$__bp_last_argument_prev_command"
}

__bp_invoke_preexec_from_ps0() {
    __bp_last_argument_prev_command="${1:-}"

    local this_command
    __bp_load_this_command_from_history || return

    __bp_invoke_preexec_functions "${__bp_last_ret_value:-}" "$__bp_last_argument_prev_command" "$this_command"
}

# This function invokes every function defined in the "preexec_functions"
# array.  This function receives the arguments $1 and $2 for $?  and $_,
# respectively, which will be set for each preexec function.  The third
# argument $3 specifies the user command that is going to be executed
# (corresponding to BASH_COMMAND in the DEBUG trap).  This function returns the
# last non-zero exit status from the preexec functions.  If there is no error,
# this function returns `0`.
__bp_invoke_preexec_functions() {
    local lastexit=$1 lastarg=$2 this_command=$3
    local preexec_function
    local preexec_function_ret_value
    local preexec_ret_value=0
    for preexec_function in "${preexec_functions[@]:-}"; do

        # Only execute each function if it actually exists.
        # Test existence of function with: declare -[fF]
        if type -t "$preexec_function" 1>/dev/null; then
            __bp_set_ret_value "$lastexit" "$lastarg"
            # Quote our function invocation to prevent issues with IFS
            "$preexec_function" "$this_command"
            preexec_function_ret_value="$?"
            if [[ "$preexec_function_ret_value" != 0 ]]; then
                preexec_ret_value="$preexec_function_ret_value"
            fi
        fi
    done
    __bp_set_ret_value "$preexec_ret_value"
}

__bp_hook_preexec_into_debug() {
    local trap_string
    trap_string=$(trap -p DEBUG)
    trap '__bp_preexec_invoke_exec "$_"' DEBUG

    # Preserve any prior DEBUG trap as a preexec function
    eval "local trap_argv=(${trap_string:-})"
    local prior_trap=${trap_argv[2]:-}
    if [[ -n "$prior_trap" ]]; then
        eval '__bp_original_debug_trap() {
            '"$prior_trap"'
        }'
        preexec_functions+=(__bp_original_debug_trap)
    fi

    # Adjust our HISTCONTROL Variable if needed.
    #
    # GHOSTTY: Don't modify HISTCONTROL (#2269). This only improves the
    # accuracy of the command passed to preexec functions when the user has
    # ignorespace set. Our bash >= 4.4 integration reads `history 1` without
    # adjusting HISTCONTROL and accepts the same inaccuracy, so keep the
    # legacy path consistent with it and respect the user's setting.
    #__bp_adjust_histcontrol

    # Issue #25. Setting debug trap for subshells causes sessions to exit for
    # backgrounded subshell commands (e.g. (pwd)& ). Believe this is a bug in Bash.
    #
    # Disabling this by default. It can be enabled by setting this variable.
    if [[ -n "${__bp_enable_subshells:-}" ]]; then

        # Set so debug trap will work be invoked in subshells.
        set -o functrace > /dev/null 2>&1
        shopt -s extdebug > /dev/null 2>&1
    fi
}

__bp_hook_preexec_into_ps0() {
    # shellcheck disable=SC2016
    PS0=${PS0-}'${ __bp_invoke_preexec_from_ps0 "$_" >&2; }'

    # Adjust our HISTCONTROL Variable if needed.
    __bp_adjust_histcontrol
}

if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
    __bp_hook_preexec_proc=__bp_hook_preexec_into_ps0
else
    __bp_hook_preexec_proc=__bp_hook_preexec_into_debug
fi

__bp_install() {
    local lastexit=$? lastarg=$_
    # Exit if we already have this installed.
    # shellcheck disable=SC2016
    if [[ "${PROMPT_COMMAND[*]:-}" == *'__bp_precmd_invoke_cmd "$_"'* ]]; then
        return 1
    fi

    "$__bp_hook_preexec_proc"

    # Remove setting our trap install string and sanitize the existing prompt command string
    __bp_remove_command_from_prompt_command "$__bp_install_string"

    __bp_install_prompt_command || true

    # Add two functions to our arrays for convenience
    # of definition.
    precmd_functions+=(precmd)
    preexec_functions+=(preexec)

    # Invoke our two functions manually that were added to $PROMPT_COMMAND
    __bp_set_ret_value "$lastexit" "$lastarg"
    __bp_precmd_invoke_cmd force
    __bp_interactive_mode force
}

# Note: We need to add the "trace" attribute to these functions so that "trap
# ... DEBUG" inside "__bp_install" and "__bp_hook_preexec_into_debug" takes
# effect even when there is an existing DEBUG trap.
declare -ft __bp_install __bp_hook_preexec_into_debug

# Encloses PROMPT_COMMAND hooks within __bp_precmd_invoke_cmd and
# __bp_interactive_mode. If all the PROMPT_COMMAND hooks are already surrounded
# by __bp_precmd_invoke_cmd and __bp_interactive_mode, the function exits with
# status 1.
__bp_install_prompt_command() {
    local prompt_command="${PROMPT_COMMAND:-}"
    if __bp_use_array_prompt_command; then
        local IFS=$'\n'
        prompt_command="${PROMPT_COMMAND[*]:-}"
        IFS=$' \t\n'
    fi

    # Exit if we already have a properly set-up hooks in PROMPT_COMMAND
    # shellcheck disable=SC2016
    local prologue='__bp_precmd_invoke_cmd "$_"'
    local epilogue='__bp_interactive_mode'
    if [[ "$prompt_command" == "$prologue"$'\n'* && "$prompt_command" == *$'\n'"$epilogue" ]]; then
        return 1
    fi

    __bp_remove_command_from_prompt_command "$prologue"
    __bp_remove_command_from_prompt_command "$epilogue"

    # Install our hooks in PROMPT_COMMAND to allow our trap to know when we've
    # actually entered something.
    # shellcheck disable=SC2128,SC2178 # PROMPT_COMMAND is not an array in bash <= 5.0
    PROMPT_COMMAND=$prologue${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}
    if __bp_use_array_prompt_command; then
        PROMPT_COMMAND+=("$epilogue")
    else
        # shellcheck disable=SC2179 # PROMPT_COMMAND is not an array in bash <= 5.0
        PROMPT_COMMAND+=$'\n'$epilogue
    fi
    return 0
}

# Sets an installation string as part of our PROMPT_COMMAND to install
# after our session has started. This allows bash-preexec to be included
# at any point in our bash profile.
__bp_install_after_session_init() {
    # bash-preexec needs to modify these variables in order to work correctly
    # if it can't, just stop the installation
    __bp_require_not_readonly PROMPT_COMMAND HISTCONTROL HISTTIMEFORMAT || return
    if [[ $__bp_hook_preexec_proc == '__bp_hook_preexec_into_ps0' ]]; then
        __bp_require_not_readonly PS0 || return
    fi

    if __bp_use_array_prompt_command; then
        PROMPT_COMMAND+=("${__bp_install_string}")
    else
        local sanitized_prompt_command
        __bp_sanitize_string sanitized_prompt_command "${PROMPT_COMMAND:-}"
        if [[ -n "$sanitized_prompt_command" ]]; then
            # shellcheck disable=SC2178 # PROMPT_COMMAND is not an array in bash <= 5.0
            PROMPT_COMMAND=${sanitized_prompt_command}$'\n'
        fi
        # shellcheck disable=SC2179 # PROMPT_COMMAND is not an array in bash <= 5.0
        PROMPT_COMMAND+=${__bp_install_string}
    fi
}

# Run our install so long as we're not delaying it.
if [[ -z "${__bp_delay_install:-}" ]]; then
    __bp_install_after_session_init
fi
