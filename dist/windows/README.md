# Ghostty for Windows

A native Windows build of Ghostty, made from the official source. Upstream
Ghostty supports only Linux and macOS, so this adds a Windows application
runtime (`src/apprt/win32`) and a few Windows fixes to the core. Everything
else, including the terminal emulation, fonts and renderer, is Ghostty's own.

## Build, test and install

Zig 0.17.0 and the Visual Studio C++ tools with a Windows SDK are needed.

    powershell -ExecutionPolicy Bypass -File dist\windows\build.ps1 -Zig C:\path\to\zig.exe

Run this from a different terminal than the Ghostty you installed. The
install step replaces the installed program, which cannot happen while it is
running, so close every installed Ghostty window first. The tests only stop
the Ghostty they start from `zig-out`, never the installed one.

That builds `zig-out\bin\ghostty.exe`, runs the tests and installs it for the
current user. Each step also works on its own:

    zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast -Dapp-runtime=win32
    powershell -ExecutionPolicy Bypass -File dist\windows\tests\run-unit-tests.ps1 -Zig <zig.exe>
    powershell -ExecutionPolicy Bypass -File dist\windows\tests\run-tests.ps1
    powershell -ExecutionPolicy Bypass -File dist\windows\install.ps1

## What the installer does

It copies Ghostty to `%LOCALAPPDATA%\Programs\Ghostty`, adds a `ghostty.cmd`
command to `%USERPROFILE%\.local\bin` (which must be on PATH), and adds a Start
menu shortcut. It does not touch the registry, PATH or the default terminal.
`uninstall.ps1` in the install folder removes it.

From cmd or PowerShell:

    ghostty                  opens a window and returns the prompt at once
    ghostty +version         runs a command line action and prints here
    ghostty --font-size=14   passes settings, like on other platforms

## What works

Windows, tabs (click, close, "+", drag to reorder) and splits (drag the
dividers), the shell through ConPTY, keyboard input with dead keys and input
methods, mouse selection and scrolling, clipboard, a scrollbar, search,
links, the bell, desktop notifications, taskbar progress, fullscreen and
maximize, window size and position from the config, a title bar that follows
the terminal colors, new tabs and splits starting in the current folder, and
config reload.

## What is missing

* Setting Ghostty as the Windows default terminal. Windows hands console
  sessions to a COM server, and the registration did not work out. See
  `src/apprt/win32/handoff.zig` for what exists.
* Per-pixel background transparency. `background-opacity` and
  `background-blur` work by fading the whole window (and asking Windows for
  blur or acrylic behind it), so the text fades with the background.
* Shell integration for cmd is limited to prompt marks; cmd does not report
  exit codes. PowerShell gets marks, exit codes and the working folder.
* CJK input methods are written but were not tested, since none was
  available to test with. Dead keys were tested.

## How the tests work

`tests\run-tests.ps1` starts real Ghostty windows and drives them with window
messages, then checks the window layout, files a typed command creates, the
clipboard, and screenshots of the window. Plain F-keys are bound to actions
with `--keybind`, because posted key messages carry no Ctrl or Shift state.
A test that needs a screenshot uses `PrintWindow`, which works while other
windows cover Ghostty.
