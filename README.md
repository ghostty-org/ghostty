<!-- LOGO -->
<h1>
<p align="center">
  <img src="images/phantom-logo.png" alt="Phantom" width="140">
  <br>Phantom
</h1>
  <p align="center">
    A Ghostty-powered terminal built around coding agents: tabs grouped by
    project, git/PR/dev-server status on every row, and a Claude Code
    session one click away — on top of the terminal
    <a href="https://ghostty.org">Ghostty</a> already got right.
    <br />
    <a href="#why">Why</a>
    ·
    <a href="#features">Features</a>
    ·
    <a href="#built-on-ghostty">Built on Ghostty</a>
    ·
    <a href="HACKING.md">Building</a>
  </p>
</p>

> Phantom is a personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)
> by [Mitchell Hashimoto](https://github.com/mitchellh) and its contributors.
> Everything that makes a terminal a terminal — the renderer, the VT
> emulation, `libghostty` — is theirs, untouched. This fork adds a sidebar, a
> settings app, and the agent-aware workflow around it.

## Why

Ghostty is, as far as I'm concerned, the best terminal available today —
fast, native, standards-compliant, built by people who clearly sweat the
details. I didn't want a *different* terminal. I wanted the same one, with a
workflow built for how I actually use it now: several coding agents running
in parallel, across several projects, and needing to know at a glance which
one needs me, which repo has an open PR, and which dev server is already
running — without alt-tabbing through a dozen indistinguishable tabs.

Phantom doesn't touch the engine. It's the app around it: a sidebar.

## Features

- **Grouped tabs** — group terminals manually, or point a group at a project
  folder and it claims every tab opened underneath it automatically.
- **Agent awareness** — a tab shows when its Claude Code session is working,
  waiting on you, or done, right from the sidebar; hooks install with one
  click in Settings.
- **One-click Claude sessions** — start a new terminal already running
  `claude`, in the right working directory, from the sidebar or a group
  header.
- **Git and PR at a glance** — branch name, an uncommitted-changes dot, and
  the open pull request for the current branch, all clickable, on every tab
  row.
- **Dev server detection** — a tab running `next dev` / `vite` / whatever
  gets a clickable `:3000`-style tag the moment the port opens — framework
  agnostic, no config.
- **Project PR list** — a group's header pops up every open PR across every
  repo in that project (workspace folders included), sorted, without a
  browser tab.
- **Themes, done properly** — the full curated catalog, an inline theme
  creator with a live preview, and Phantom's own chrome (Settings, About,
  the theme browser) follows whatever theme is active instead of the
  system's light/dark setting.
- **A real font picker** — search across every font macOS has installed,
  with a live preview, and separate fields for the terminal and for
  Phantom's own interface.
- **Native Settings, no config-file spelunking** — every style knob (font,
  cursor, effect, dividers) is a GUI control that writes to a config file
  Ghostty already understands.

## Built on Ghostty

[Ghostty](https://ghostty.org) is the entire reason this is fast and
correct: the multi-threaded core, the Metal renderer, the
standards-compliant VT emulation, `libghostty` — none of that is Phantom's.
It's [Mitchell Hashimoto](https://github.com/mitchellh)'s and the Ghostty
contributors', and this fork tracks it so it can keep merging upstream.

If you want the terminal engine itself — performance details, supported
sequences, the roadmap, platform notes — that's all in
[Ghostty's own documentation](https://ghostty.org/docs) and
[`HACKING.md`](HACKING.md), unchanged from upstream.

## Building

Phantom builds exactly like Ghostty does — see [`HACKING.md`](HACKING.md)
for the full setup. Short version, from the repo root:

```shell-session
zig build -Doptimize=ReleaseFast
```

## License

MIT, same as Ghostty — see [LICENSE](LICENSE).
