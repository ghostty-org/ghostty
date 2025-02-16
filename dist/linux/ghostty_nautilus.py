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

from os.path import isdir
from gi import require_version
from gi.repository import Nautilus, GObject, Gio, GLib


class OpenInGhosttyAction(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self._systemd = None
        # Check if the this system runs under systemd, per sd_booted(3)
        if isdir('/run/systemd/system/'):
            self._systemd = Gio.DBusProxy.new_sync(session,
                    Gio.DBusProxyFlags.NONE,
                    None,
                    "org.freedesktop.systemd1",
                    "/org/freedesktop/systemd1",
                    "org.freedesktop.systemd1.Manager", None)

    def _open_terminal(self, path):
        cmd = ['ghostty', f'--working-directory={path}', '--gtk-single-instance=false']
        child = Gio.Subprocess.new(cmd, Gio.SubprocessFlags.NONE)
        if self._systemd:
            # Move new terminal into a dedicated systemd scope to make systemd
            # track the terminal separately; in particular this makes systemd
            # keep a separate CPU and memory account for the terminal which in turn
            # ensures that oomd doesn't take nautilus down if a process in
            # ghostty consumes a lot of memory.
            pid = int(child.get_identifier())
            props = [("PIDs", GLib.Variant('au', [pid])),
                ('CollectMode', GLib.Variant('s', 'inactive-or-failed'))]
            name = 'app-nautilus-com.mitchellh.ghostty-{}.scope'.format(pid)
            args = GLib.Variant('(ssa(sv)a(sa(sv)))', (name, 'fail', props, []))
            self._systemd.call_sync('StartTransientUnit', args,
                    Gio.DBusCallFlags.NO_AUTO_START, 500, None)

    def _menu_item_activated(self, _menu, paths):
        for path in paths:
            self._open_terminal(path)

    def _make_item(self, name, paths):
        item = Nautilus.MenuItem(name=name, label='Open in Ghostty',
            icon='com.mitchellh.ghostty')
        item.connect('activate', self._menu_item_activated, paths)
        return item

    def _paths_to_open(self, files):
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

    def get_file_items(self, *args):
        # Nautilus 3.0 API passes args (window, files), 4.0 API just passes files
        files = args[0] if len(args) == 1 else args[1]
        paths = self._paths_to_open(files)
        if paths:
            return [self._make_item(name='GhosttyNautilus::open_in_ghostty', paths=paths)]
        else:
            return []

    def get_background_items(self, *args):
        # Nautilus 3.0 API passes args (window, file), 4.0 API just passes file
        file = args[0] if len(args) == 1 else args[1]
        paths = self._paths_to_open([file])
        if paths:
            return [self._make_item(name='GhosttyNautilus::open_folder_in_ghostty', paths=paths)]
        else:
            return []
