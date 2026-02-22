# This wrapper is sourced because Ghostty extends ZDOTDIR control through
# the zsh startup sequence (.zshenv -> .zprofile -> .zshrc). It sources
# the user's .zprofile while keeping ZDOTDIR pointing to Ghostty's dir.
#
# We intentionally do NOT restore ZDOTDIR before sourcing so that if the
# user's .zprofile replaces the shell process (e.g. Kiro/Fig's PTY wrapper
# exec), the new shell inherits Ghostty's ZDOTDIR and integration loads.
#
# This file can get sourced with aliases enabled. To avoid alias expansion
# we quote everything that can be quoted. Some aliases will still break us
# though.

# Source the user's .zprofile from their original ZDOTDIR.
{
    'builtin' 'typeset' _ghostty_user_zprofile=${GHOSTTY_ZSH_ZDOTDIR-$HOME}"/.zprofile"
    [[ ! -r "$_ghostty_user_zprofile" ]] || 'builtin' 'source' '--' "$_ghostty_user_zprofile"
} always {
    'builtin' 'unset' '_ghostty_user_zprofile'
}
