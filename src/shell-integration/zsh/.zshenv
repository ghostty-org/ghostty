# Based on (started as) a copy of Kitty's zsh integration. Kitty is
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

# This script is sourced automatically by zsh when ZDOTDIR is set to this
# directory. It therefore assumes it's running within our shell integration
# environment and should not be sourced manually (unlike ghostty-integration).
#
# This file can get sourced with aliases enabled. To avoid alias expansion
# we quote everything that can be quoted. Some aliases will still break us
# though.

# Save Ghostty's integration directory. We need this to set ZDOTDIR back
# after sourcing the user's .zshenv so that our .zprofile and .zshrc
# wrappers are loaded.
'builtin' 'typeset' _ghostty_integ_dir="${${(%):-%x}:A:h}"

# Restore the original ZDOTDIR value if GHOSTTY_ZSH_ZDOTDIR is set.
# Otherwise, unset the ZDOTDIR that was set during shell injection.
# For interactive shells, keep GHOSTTY_ZSH_ZDOTDIR set so that our
# .zprofile and .zshrc wrappers can find the user's dot files.
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    if ! [[ -o 'interactive' ]]; then
        'builtin' 'unset' 'GHOSTTY_ZSH_ZDOTDIR'
    fi
else
    'builtin' 'unset' 'ZDOTDIR'
fi

# Use try-always to have the right error code.
{
    # Zsh treats unset ZDOTDIR as if it was HOME. We do the same.
    #
    # Source the user's .zshenv before sourcing ghostty-integration because the
    # former might set fpath and other things without which ghostty-integration
    # won't work.
    #
    # Use typeset in case we are in a function with warn_create_global in
    # effect. Unlikely but better safe than sorry.
    'builtin' 'typeset' _ghostty_file=${ZDOTDIR-$HOME}"/.zshenv"
    # Zsh ignores unreadable rc files. We do the same.
    # Zsh ignores rc files that are directories, and so does source.
    [[ ! -r "$_ghostty_file" ]] || 'builtin' 'source' '--' "$_ghostty_file"
} always {
    if [[ -o 'interactive' ]]; then
        # Update GHOSTTY_ZSH_ZDOTDIR to reflect any ZDOTDIR changes the
        # user's .zshenv may have made (e.g. setting ZDOTDIR for XDG layout).
        # Our .zprofile and .zshrc wrappers use this to find user files.
        if [[ -n "${ZDOTDIR+X}" ]]; then
            'builtin' 'export' GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"
        else
            'builtin' 'unset' 'GHOSTTY_ZSH_ZDOTDIR'
        fi

        # Set ZDOTDIR back to Ghostty's dir so our .zprofile and .zshrc
        # wrappers are sourced instead of the user's files directly.
        'builtin' 'export' ZDOTDIR="$_ghostty_integ_dir"

        'builtin' 'typeset' _ghostty_file="${_ghostty_integ_dir}"/ghostty-integration
        if [[ -r "$_ghostty_file" ]]; then
            'builtin' 'autoload' '-Uz' '--' "$_ghostty_file"
            "${_ghostty_file:t}"
            'builtin' 'unfunction' '--' "${_ghostty_file:t}"
        fi
    fi
    'builtin' 'unset' '_ghostty_file' '_ghostty_integ_dir'
}
