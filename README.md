<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>RoundedStone
</h1>
  <p align="center">
    A personal macOS fork of <a href="https://github.com/ghostty-org/ghostty">Ghostty</a> adding an adaptive split layout.
    <br />
    <a href="ADAPTIVE_LAYOUT.md">Adaptive Layout</a>
    ·
    <a href="https://github.com/ghostty-org/ghostty">Upstream Ghostty</a>
  </p>
</p>

## About

RoundedStone is a fork of [Ghostty](https://github.com/ghostty-org/ghostty),
the fast, native, feature-rich terminal emulator. Everything about Ghostty
itself — standards compliance, performance, `libghostty`, platform support —
is unchanged and documented upstream; see the
[mainline Ghostty repo](https://github.com/ghostty-org/ghostty) and
[ghostty.org/docs](https://ghostty.org/docs) for all of that.

This fork's only addition is an **adaptive split layout** on macOS: the
focused pane takes up most of the window, other panes
condense to smaller tiles, and the layout re-flows as focus moves between
panes. Manual split/drag/zoom behavior is unchanged when adaptive mode is
off, and it's on by default here. See [`ADAPTIVE_LAYOUT.md`](ADAPTIVE_LAYOUT.md)
for how it works, the config option, and known limitations.

The app builds and runs as `RoundedStone.app` (bundle id
`com.roundedstone.terminal`) so it can coexist with an unmodified Ghostty
install on the same machine; it reads the same config directory as
Ghostty (`~/Library/Application Support/com.mitchellh.ghostty/`).

## Building

Same build process as upstream Ghostty — see
[`HACKING.md`](HACKING.md). In short: `zig build -Demit-macos-app`, then
`xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug build`.
