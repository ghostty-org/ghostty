# gt — Ghostties task CLI

Terminal-native read/write for `.ghostties/tasks/*.md` — the same task files the Ghostties sidebar app reads. Zero coupling: `gt` talks to the filesystem, not the running app.

## Build

```sh
cd cli
swift build -c release
```

The binary is at `.build/release/gt`.

## Install

```sh
cp .build/release/gt /usr/local/bin/gt
```

> **Name conflict:** [git-town](https://www.git-town.com) also installs a `gt` binary. If you use git-town, install under a different name instead:
>
> ```sh
> cp .build/release/gt /usr/local/bin/ghostties-gt
> ```

## Requirements

- macOS 13+ (or Linux with Foundation)
- Swift 5.9+ (to build)

## Tasks directory discovery

`gt` walks up from the current directory looking for `.ghostties/tasks/`, git-style. If none is found, `gt new` creates one in the current directory.

## Subcommands

```
gt new <title> [--source <name>] [--branch <name>] [--project <name>] [--lane <lane>]
  Create a task. Prints the new file path. Default lane: backlog.

gt list [--lane <lane>] [--source <name>] [--project <name>]
  Print tasks sorted by lane priority (needs-you > running > review > inbox > backlog > done).
  Colorized when stdout is a tty.

gt focus <id>
  Write the task id to .ghostties/.focus. The app watches this file.

gt notes append <id> "<text>"
  Append a timestamped bullet to the task's ## Notes section.

gt done <id>
  Move the task to the done lane and stamp `completed:` in frontmatter.
```

## Task id resolution

Every subcommand that takes an id accepts the full id (the filename stem) or an unambiguous prefix:

```sh
gt focus sea-14          # unambiguous prefix — ok
gt focus sea-1           # ambiguous — errors with list of candidates
```

## Lane names

Six lanes match the sidebar IA: `inbox`, `backlog`, `running`, `needs-you`, `review`, `done`. The alias `graveyard` is accepted as input (it maps to `done`); on-disk status is always `done` for compatibility with the macOS app parser.

## Exit codes

- `0` — success
- `1` — usage error
- `2` — task or directory not found
- `3` — ambiguous id

## File format

Each task is a single markdown file with YAML-ish frontmatter. Example:

```markdown
---
title: Fix CEF build on arm64
source: github
source-id: gh-287
branch: cef-build
project: ghostties
created: 2026-04-22T22:35:00Z
status: running
---

## Goal

...

## Notes

- [2026-04-23 10:14] re-ran download-cef.sh; arm64 slice verified

## Activity

- 2026-04-22T22:35:00Z — Agent started from gh-287
```
