# Changelog

All notable changes to Ghostties are documented here. Ghostties is a macOS terminal app built on top of [Ghostty](https://ghostty.org) that adds a multi-agent workspace sidebar.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are pre-release betas until v0.1.0 stable.

---

## [0.1.0-beta.15] — 2026-05-05

Polish and stability fixes following the beta.14 smoke test.

### Fixed

- Dark mode titlebar now matches the canvas background color (previously showed a mismatched gray)
- Fullscreen icon position in the toolbar corrected
- Canvas corner radius is now consistent on all four corners
- Shadow depth between the browser panel and terminal panel is now consistent
- Sparkle update-available toast is no longer shown in release builds (debug-only now)

### Quality

- All upstream Ghostty tests pass — full test suite is green

---

## [0.1.0-beta.14] — 2026-04-30

First beta with a production-quality icon and an onboarding experience on first launch.

### Added

- New production app icon
- Debug builds use a distinct blueprint-style icon so it's easy to tell Dev from Release at a glance
- Onboarding sheet appears on first launch — includes welcome copy, links to send feedback, and a version footer
- Tasks panel now shows a "preview" callout card instead of an inline alert
- Honest placeholder copy in places that aren't fully wired up yet

### Changed

- Fresh installs now default to showing the project sidebar first (previously opened to an empty state)

---

## [0.1.0-beta.13] — 2026-04-30

Window controls alignment and the first version of task row interaction.

### Fixed

- Traffic light buttons (close / minimize / zoom) are now correctly centered in the titlebar — previously they floated slightly off

### Added

- Sidebar row-click v0 — clicking a task row now lets you interact with it

---

## [0.1.0-beta.12] — 2026-04-28

First distributable build. Ghostties can now be installed and kept up to date automatically.

### Added

- First full DMG bundle with notarization — Ghostties is now installable like any other Mac app
- Sparkle auto-update wired to ghostties.org — the app will notify you when a new beta is available
- Row-click interaction across the task list (12 interaction units shipped)
- Privacy and support pages live at ghostties.org

---

[0.1.0-beta.15]: https://github.com/SeanSmithDesign/ghostties/releases/tag/v0.1.0-beta.15
[0.1.0-beta.14]: https://github.com/SeanSmithDesign/ghostties/releases/tag/v0.1.0-beta.14
[0.1.0-beta.13]: https://github.com/SeanSmithDesign/ghostties/releases/tag/v0.1.0-beta.13
[0.1.0-beta.12]: https://github.com/SeanSmithDesign/ghostties/releases/tag/v0.1.0-beta.12
