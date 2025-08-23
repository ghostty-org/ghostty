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

# This file can get sourced with aliases enabled. To avoid alias expansion
# we quote everything that can be quoted. Some aliases will still break us
# though.

# Restore the original ZDOTDIR value.
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    'builtin' 'unset' 'GHOSTTY_ZSH_ZDOTDIR'
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
        'builtin' 'autoload' '--' 'is-at-least'
        'is-at-least' "5.1" || {
            builtin echo "ZSH ${ZSH_VERSION} is too old for ghostty shell integration" > /dev/stderr
            'builtin' 'unset' '_ghostty_file'
            return
        }
        # ${(%):-%x} is the path to the current file.
        # On top of it we add :A:h to get the directory.
        'builtin' 'typeset' _ghostty_file="${${(%):-%x}:A:h}"/ghostty-integration
        if [[ -r "$_ghostty_file" ]]; then
            'builtin' 'autoload' '-Uz' '--' "$_ghostty_file"
            "${_ghostty_file:t}"
            'builtin' 'unfunction' '--' "${_ghostty_file:t}"
        fi
    fi
    'builtin' 'unset' '_ghostty_file'
}
