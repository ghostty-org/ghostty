# Adapted from wezterm: https://github.com/wez/wezterm/blob/main/assets/wezterm-nautilus.py
# original copyright notice:
#
# Copyright (C) 2022 Sebastian Wiesner <sebastian@swsnr.de>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

from pathlib import Path
import gettext
from gi.repository import Nautilus, GObject, Gio

DOMAIN = "com.mitchellh.ghostty"
locale_dir = Path(__file__).absolute().parents[2] / "locale"
_ = gettext.translation(DOMAIN, locale_dir, fallback=True).gettext

def open_in_ghostty_activated(_menu, paths):
    for path in paths:
        cmd = ['ghostty', f'--working-directory={path}', '--gtk-single-instance=false']
        Gio.Subprocess.new(cmd, Gio.SubprocessFlags.NONE)


def get_paths_to_open(files):
    paths = []
    for file in files:
        location = file.get_location() if file.is_directory() else file.get_parent_location()
        path = location.get_path()
        if path and path not in paths:
            paths.append(path)
    if 10 < len(paths):
        # Let's not open anything if the user selected a lot of directories,
        # to avoid accidentally spamming their desktop with dozends of
        # new windows or tabs.  Ten is a totally arbitrary limit :)
        return []
    else:
        return paths


def get_items_for_files(name, files):
    paths = get_paths_to_open(files)
    if paths:
        item = Nautilus.MenuItem(name=name, label=_('Open in Ghostty'),
            icon='com.mitchellh.ghostty')
        item.connect('activate', open_in_ghostty_activated, paths)
        return [item]
    else:
        return []


class GhosttyMenuProvider(GObject.GObject, Nautilus.MenuProvider):
    def get_file_items(self, files):
        return get_items_for_files('GhosttyNautilus::open_in_ghostty', files)

    def get_background_items(self, file):
        return get_items_for_files('GhosttyNautilus::open_folder_in_ghostty', [file])
