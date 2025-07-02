# Notes on Running Ghostty on Linux

## Launching

If properly installed, Ghostty will take advantage of D-Bus activation and
`systemd` user services to provide the best experience possible.

If installed by a system package or by compiling from source and installing
into `$HOME/.local` (with `zig build -p $HOME/.local -Doptimize=ReleaseFast`)
several configuration files will be installed which allow Ghostty to be launched
from most GUI application launchers (like Gnome Shell or KDE Plasma) using D-Bus
activation and a `systemd` user service.

These are the files that control the launching of Ghostty if installed as
a user:

```
$PREFIX/share/applications/com.mitchellh.ghostty.desktop
$PREFIX/share/dbus-1/services/com.mitchellh.ghostty.service
$PREFIX/share/systemd/user/com.mitchellh.ghostty.service
```

If installed as a system package, the files will be found in the following
locations:

```
$PREFIX/share/applications/com.mitchellh.ghostty.desktop
$PREFIX/share/dbus-1/services/com.mitchellh.ghostty.service
$PREFiX/lib/systemd/user/com.mitchellh.ghostty.service
```

If these files are not installed in the proper locations and configured
correctly Ghostty may fail to launch.

## Checking Ghostty's Status

The following command will show you Ghostty's status:

```sh
systemctl status --user com.mitchellh.ghostty.service
```

Which should produce output similar to the following:

```
● com.mitchellh.ghostty.service - Ghostty
     Loaded: loaded (/home/binky/.config/systemd/user/com.mitchellh.ghostty.service; enabled; preset: ignored)
     Active: active (running) since Tue 2025-07-01 17:36:57 CDT; 1h 40min ago
 Invocation: 75ed691baf914c5baae03beca7d32ff5
   Main PID: 2900191 (.ghostty-wrappe)
      Tasks: 0 (limit: 76934)
     Memory: 8M (peak: 9.5M)
        CPU: 96ms
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/com.mitchellh.ghostty.service
             ‣ 2900191 /nix/store/bi6rbmzcpmbfd1zyaf8qihk9zggyr0i8-ghostty-1.1.4/bin/ghostty --launched-from=systemd

Jul 01 17:36:57 pinky ghostty[2900191]: info(font_shared_grid_set): font bold: Adwaita Mono Bold
Jul 01 17:36:57 pinky ghostty[2900191]: info(font_shared_grid_set): font italic: Adwaita Mono Italic
Jul 01 17:36:57 pinky ghostty[2900191]: info(font_shared_grid_set): font bold_italic: Adwaita Mono Bold Italic
```

## How Launching Works With D-Bus Activation

The application launcher, instead of executing Ghostty directly, will send a
signal to the D-Bus session broker asking it to open a Ghostty window. What
happens from there depends on if Ghostty is already running or not. The D-Bus
session broker knows if Ghostty is running or not because Ghostty will claim
a specific bus name on the session bus (`com.mitchellh.ghostty`). If there is
a program running that has claimed that bus name Ghostty will be assumed to
be running.

### If Ghostty is Already Running

If Ghostty is already running, the broker will send a D-Bus signal directly to
Ghostty asking it to create a new window.

```mermaid
sequenceDiagram
  actor Launcher
  participant D-Bus
  participant Ghostty
  Launcher->>D-Bus: Start a Ghostty window
  D-Bus->>Ghostty: Create a new window
  Ghostty->>D-Bus: OK
```

### If Ghostty is Not Running

If Ghostty is not running, the D-Bus session broker will ask `systemd` to start
Ghostty in a user service, and then will send Ghostty a D-Bus signal to create a
new window.

```mermaid
sequenceDiagram
  actor Launcher
  participant D-Bus
  participant systemd
  Launcher->>D-Bus: Start a Ghostty window
  D-Bus->>systemd: Start Ghostty service
  create participant Ghostty
  systemd->>Ghostty: Start Ghostty service
  Ghostty->>systemd: Started
  Ghostty->>D-Bus: I'm here!
  D-Bus->>Ghostty: Create a new window
  Ghostty->>D-Bus: OK
```

This ensures that any startup delay caused by GTK (or any other initialization) is
only incurred once per login.

## Starting Ghostty at Login

The Ghostty `systemd` user service can be configured to start up as soon as you
log in by running this command:

```sh
systemctl enable --user com.mitchell.ghostty.service
```

This will configure your system to start Ghostty, but not create any windows,
when you log in. Any startup delay will be "hidden" by the time that your system
needs to finish setting up everything after logging in.

## Stopping Ghostty

The Ghostty `systemd` user service can be stopped by running:

```sh
systemctl stop --user com.mitchellh.ghostty.service
```

> [!WARNING]
>
> There is a chance of data loss if the above command is run while there are any
> open Ghostty windows with programs running in them. Any programs running in
> Ghostty windows will be killed without asking for any confirmation.

## Logs

Any logs emitted by the Ghostty `systemd` user service can be seen by running
this command:

```sh
journalctl -a -f --user -u com.mitchellh.ghostty.service
```

## Creating New Windows "Manually"

With D-Bus activation and `systemd` user services in use, simply launching
`ghostty` from the CLI (or through a global keybind) will not create a new
Ghostty terminal window. The following command can be used to send a D-Bus
signal to Ghostty to create a new window:

```sh
gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate new-window [] []
```

This command will create a new Ghostty window even if Ghostty is not already
running as D-Bus activation will cause Ghostty to be launched.

### Tiling Window Managers

The above `gdbus` command is useful for tiling window managers like i3,
Hyprland, or River. Simply bind the `gdbus` command to a key to create new
Ghostty windows, even if Ghostty is not already running. This can partially
serve as an alternative to Ghostty's global keybinds for unsupported window
managers (at least for creating a new window).

## Reloading the Config

In addition to other built-in methods like the keybind action, sending the
`USR2` signal to the Ghostty process will trigger a configuration reload.

## Debug Installations

If you have installed a debug version of Ghostty, the above commands and file
paths need to be altered slightly:

```sh
systemctl enable --user com.mitchell.ghostty-debug.service
journalctl -a -f --user -u com.mitchellh.ghostty-debug.service
gdbus call --session --dest com.mitchellh.ghostty-debug --object-path /com/mitchellh/ghostty_debug --method org.gtk.Actions.Activate new-window [] []
```

These are the files that control the launching of debug versions of Ghostty if
installed as a user:

```
$PREFIX/share/applications/com.mitchellh.ghostty-debug.desktop
$PREFIX/share/dbus-1/services/com.mitchellh.ghostty-debug.service
$PREFIX/share/systemd/user/com.mitchellh.ghostty-debug.service
```

If installed as a system package, the files will be found in the following
locations:

```
$PREFIX/share/applications/com.mitchellh.ghostty-debug.desktop
$PREFIX/share/dbus-1/services/com.mitchellh.ghostty-debug.service
$PREFiX/lib/systemd/user/com.mitchellh.ghostty-debug.service
```
