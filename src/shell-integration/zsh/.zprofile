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
'builtin' 'typeset' _ghostty_file=${GHOSTTY_ZSH_ZDOTDIR-$HOME}"/.zprofile"
[[ ! -r "$_ghostty_file" ]] || 'builtin' 'source' '--' "$_ghostty_file"
'builtin' 'unset' '_ghostty_file'
