# This wrapper is sourced because Ghostty extends ZDOTDIR control through
# the zsh startup sequence (.zshenv -> .zprofile -> .zshrc). It permanently
# restores the user's ZDOTDIR, sources their .zshrc, and re-verifies that
# shell integration hooks are still in place.
#
# This file can get sourced with aliases enabled. To avoid alias expansion
# we quote everything that can be quoted. Some aliases will still break us
# though.

# Permanently restore the user's ZDOTDIR.
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    'builtin' 'typeset' _ghostty_user_zshrc=${ZDOTDIR-$HOME}"/.zshrc"
    [[ ! -r "$_ghostty_user_zshrc" ]] || 'builtin' 'source' '--' "$_ghostty_user_zshrc"
} always {
    # Re-add _ghostty_deferred_init to precmd_functions if it was removed
    # during startup. Tools like Kiro/Fig may replace precmd_functions in
    # .zprofile or .zshrc, silently removing our deferred init hook.
    if (( $+functions[_ghostty_deferred_init] )) &&
       [[ ${precmd_functions[(I)_ghostty_deferred_init]} -eq 0 ]]; then
        'builtin' 'typeset' -ag precmd_functions
        precmd_functions+=(_ghostty_deferred_init)
    fi
    'builtin' 'unset' 'GHOSTTY_ZSH_ZDOTDIR'
    'builtin' 'unset' '_ghostty_user_zshrc'
}
