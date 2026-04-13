# Ghostty → Ghostties Text Rename Plan

- **Date:** 2026-04-13
- **Status:** planning
- **Repo commit at research:** `d5a13afeee0e333cfd012df743053defa42042e9`
- **Scope:** User-visible display strings only. Module names (`import Ghostty`), class/struct/file names, config paths (`~/.config/ghostty/`), URL schemes, bundle identifiers, CLI binary name `ghostty`, and UserDefaults keys are explicitly out of scope per `CLAUDE.md`.

> Cited lines current as of commit `d5a13afeee0e333cfd012df743053defa42042e9`. Spot-checked during plan authoring — all references verified in place.

---

## 1. Inventory (by surface)

### 1.1 Main menu chrome

- `macos/Sources/App/macOS/MainMenu.xib`
  - L79 — top-level App menu `title="Ghostty"`
  - L81 — `<menu ... title="Ghostty" systemMenu="apple" ...>`
  - L83 — `About Ghostty`
  - L113 — `Make Ghostty the Default Terminal`
  - L125 — `Hide Ghostty`
  - L143 — `Quit Ghostty`
  - L526 — `Ghostty Help`

### 1.2 Window placeholder titles

- `macos/Sources/Features/Terminal/Window Styles/` — 6 xibs, each L16 `title="👻 Ghostty"` → `"👻 Ghostties"`
- `macos/Sources/Features/QuickTerminal/QuickTerminal.xib` L16 — `title="👻 Ghostty"`
- `macos/Sources/Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift` L300 — default title string
- `macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift` L589 — default title string

### 1.3 NSAlert dialogs

- `macos/Sources/App/macOS/AppDelegate.swift` — L408, L410, L501, L1331

### 1.4 Toasts / banners / inline text

- `macos/Sources/Features/Terminal/ErrorView.swift` L13 — "restart Ghostty"
- `macos/Sources/Features/Terminal/TerminalView.swift` L157, L161, L174
- `macos/Sources/Features/Settings/SettingsView.swift` L17 — only final "restart Ghostty" (KEEP `~/.config/ghostty/config.ghostty` path)
- `macos/Sources/Features/Update/UpdatePopoverView.swift` L65
- `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` L95

### 1.5 About dialog

- `macos/Sources/Features/About/AboutView.swift` L50 — `Text("Ghostty")` (KEEP upstream github/docs URLs at L6/7)
- `macos/Sources/Features/About/CyclingIconView.swift` L29 — accessibility label

### 1.6 AppleScript runtime errors

- `macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift` L177, L235 — "Ghostty app delegate is unavailable."

### 1.7 App Intents (Shortcuts)

- `macos/Sources/Features/App Intents/GhosttyIntentError.swift` L8, L10
- `macos/Sources/Features/App Intents/IntentPermission.swift` L48

### 1.8 CLI launch-failure stderr

- `macos/Sources/App/macOS/main.swift` L16 — rename display prose only; **KEEP** `` `ghostty +help` `` (binary name).

### 1.9 Info.plist / AppleScript dictionary

- `macos/Ghostties-Info.plist` L111 — `UTTypeDescription`
- `macos/Ghostty.sdef` — 22 user-visible description strings at L4, L5, L6, L12, L41, L64, L154, L155, L167, L174, L203 (and adjacent descriptive attributes). **DO NOT** touch `<cocoa class="GhosttyScript…"/>` — those are Swift class identifiers.

### 1.10 Dock tile plugin display name

- `macos/Ghostties.xcodeproj/project.pbxproj` L975, L1004, L1033 — `INFOPLIST_KEY_CFBundleDisplayName = "Ghostty Dock Tile Plugin"` → `"Ghostties Dock Tile Plugin"`

### 1.11 iOS init view label (low priority / optional)

- `macos/Sources/App/iOS/iOSApp.swift` L45

---

## 2. Implementation Units

Each unit is its own commit. Build + launch + visual inspection before moving on.

### Unit 1 — Main menu chrome

- **Files:** `macos/Sources/App/macOS/MainMenu.xib`
- **Do NOT change:** `customModule="Ghostty"` bindings, action selectors (e.g. `toggleGhosttyFullScreen:`), object IDs.
- **Verify:** Launch app. Inspect App menu, Hide, Quit, Help, and "Make Default" strings.
- **Commit:** `rename: main menu titles Ghostty → Ghostties`

### Unit 2 — Window placeholder titles

- **Files:** 6 xibs in `macos/Sources/Features/Terminal/Window Styles/`, `macos/Sources/Features/QuickTerminal/QuickTerminal.xib`, `TitlebarTabsTahoeTerminalWindow.swift` L300, `TitlebarTabsVenturaTerminalWindow.swift` L589
- **Do NOT change:** `customModule="Ghostty"`, `customClass` values, or any binding IDs.
- **Verify:** Open a new window with no title set; confirm titlebar reads "👻 Ghostties". Check Quick Terminal.
- **Commit:** `rename: window placeholder titles Ghostty → Ghostties`

### Unit 3 — NSAlert dialogs

- **Files:** `macos/Sources/App/macOS/AppDelegate.swift` L408, L410, L501, L1331
- **Do NOT change:** alert style, button identifiers, any API keys or config identifiers nearby.
- **Verify:** Trigger each alert path (restart prompt, default-terminal prompt, etc.) — titles/messages read "Ghostties".
- **Commit:** `rename: NSAlert dialog text Ghostty → Ghostties`

### Unit 4 — Toasts / banners / inline text

- **Files:** `ErrorView.swift` L13, `TerminalView.swift` L157/L161/L174, `SettingsView.swift` L17 (only the final "restart Ghostty" — **KEEP** `~/.config/ghostty/config.ghostty`), `UpdatePopoverView.swift` L65, `TerminalCommandPalette.swift` L95
- **Do NOT change:** config file paths, URL schemes, log key names.
- **Verify:** Force a fatal error to view ErrorView; open Settings; open Command Palette.
- **Commit:** `rename: inline UI text Ghostty → Ghostties`

### Unit 5 — About dialog

- **Files:** `AboutView.swift` L50, `CyclingIconView.swift` L29
- **Do NOT change:** `GhosttyCommit` Info.plist key (L11), upstream github/docs URLs (L6/7), icon asset names.
- **Verify:** Open About window; VoiceOver read on cycling icon.
- **Commit:** `rename: About dialog Ghostty → Ghostties`

### Unit 6 — AppleScript runtime errors

- **Files:** `AppDelegate+AppleScript.swift` L177, L235
- **Do NOT change:** references to `Ghostty.sdef` file name, Swift class names, `Ghostty.SurfaceConfiguration` type.
- **Verify:** Run an AppleScript against a launched app without delegate available (e.g. during teardown) — confirm error string reads "Ghostties".
- **Commit:** `rename: AppleScript error messages Ghostty → Ghostties`

### Unit 7 — App Intents (Shortcuts)

- **Files:** `GhosttyIntentError.swift` L8/L10, `IntentPermission.swift` L48
- **Do NOT change:** enum name `GhosttyIntentError`, file names, intent identifiers.
- **Verify:** Run a Shortcut that triggers each error path; inspect the error string in Shortcuts.
- **Commit:** `rename: App Intents error copy Ghostty → Ghostties`

### Unit 8 — CLI launch-failure stderr

- **File:** `macos/Sources/App/macOS/main.swift` L16
- **Do NOT change:** `` `ghostty +help` `` backtick reference (CLI binary name), `Ghostty.logger`, `Ghostty.launchSource`, `GhosttyKit` import.
- **Verify:** Force `ghostty_init` failure (e.g. invalid config) via CLI launch path; confirm stderr reads "Ghostties failed to initialize…" with binary name intact.
- **Commit:** `rename: CLI launch failure prose Ghostty → Ghostties`

### Unit 9 — Info.plist UTType description

- **File:** `macos/Ghostties-Info.plist` L111 (`UTTypeDescription`)
- **Do NOT change:** `UTTypeIdentifier`, `CFBundleIdentifier`, any `com.mitchellh.ghostty.*` strings.
- **Verify:** Right-click a `.ghostty` file in Finder → Get Info; UTType description reads "Ghostties ...".
- **Commit:** `rename: UTType description Ghostty → Ghostties`

### Unit 10 — AppleScript dictionary prose

- **File:** `macos/Ghostty.sdef` — description attributes at L4, L5, L6, L12, L41, L64, L154, L155, L167, L174, L203 (22 total user-visible strings). Rename `Ghostty Scripting Dictionary`, `Ghostty Suite`, `Ghostty action string`, etc.
- **Do NOT change:** `<cocoa class="GhosttyScript…"/>` class identifiers, four-char codes (`Ghst`, `capp`, `GFWn`, `Gwnd`, `Gtab`, `GhstPfAc`, `GhstNWin`, `GhstNTab`, `GhstAcWn`, etc.), or the file name `Ghostty.sdef`.
- **Verify:** Open Script Editor → File → Open Dictionary → Ghostties.app; browse all suites and commands, confirm prose reads "Ghostties".
- **Commit:** `rename: AppleScript dictionary descriptions Ghostty → Ghostties`

### Unit 11 — Dock tile plugin display name

- **File:** `macos/Ghostties.xcodeproj/project.pbxproj` L975, L1004, L1033
- **Do NOT change:** `PRODUCT_NAME`, `PRODUCT_MODULE_NAME`, target names (`GhosttyDockTilePlugin` etc.), bundle IDs, signing settings.
- **Verify:** Build; right-click Dock tile; plugin name appears as "Ghostties Dock Tile Plugin".
- **Commit:** `rename: Dock tile plugin display name Ghostty → Ghostties`

### Unit 12 — iOS init view label (optional)

- **File:** `macos/Sources/App/iOS/iOSApp.swift` L45
- **Gate:** Confirm with user whether iOS target ships from this fork. If no — skip unit.
- **Do NOT change:** target identifiers, entitlements.
- **Verify:** Build iOS target if applicable; launch in Simulator; init view reads "Ghostties".
- **Commit:** `rename: iOS init view label Ghostty → Ghostties`

---

## 3. Risk Flags

- **AppKit auto-substitution.** macOS auto-populates some App/Hide/Quit menu strings from `CFBundleDisplayName` at runtime. Since `INFOPLIST_KEY_CFBundleDisplayName` is already `Ghostties`, the xib text may never be shown. Renaming it anyway is defensive but possibly redundant — harmless either way.
- **Upstream merge conflicts.** Every unit touches upstream-originated files; each rename is a future merge conflict. Accepted cost — the inventory is deliberately minimal, limited to display strings that actually render as "Ghostty" in the UI.
- **Help menu URL mismatch.** The "Ghostties Help" item opens `ghostty.org/docs` (upstream). Accept branding mismatch for now — no URL change.
- **`Ghostty.sdef` class bindings.** `<cocoa class="GhosttyScriptWindow"/>`, `GhosttyScriptTab`, `GhosttyScriptTerminal`, `GhosttyScriptInputTextCommand`, `GhosttyScriptKeyEventCommand`, `GhosttyScriptMouseButtonCommand`, `GhosttyScriptMousePosCommand`, `GhosttyScriptMouseScrollCommand` MUST remain. They match Swift class names; renaming them breaks AppleScript dispatch at runtime.
- **`main.swift` mixed copy.** Final string reads "Ghostties failed to initialize… run `ghostty +help`". Correct but mixed. Document as intentional — `ghostty` is the CLI binary, `Ghostties` is the app.

---

## 4. Open Questions (flag for user)

1. **MainMenu.xib top-level App menu title** — rename even though AppKit may override? **Recommend yes** (defensive + cheap).
2. **`Ghostty.sdef` "Ghostty action string"** — this is an upstream concept/term referenced in scripts. Rename to "Ghostties action string" or keep upstream term for compatibility? **Recommend rename** (user-visible in Script Editor; no AppleScript behavior depends on this string).
3. **iOS target** — is it shipped from this fork? **Probably not** — confirm before executing Unit 12.
4. **AboutView tagline** — the surrounding tagline/description is upstream verbiage. Rename or keep? **Recommend keep** — treat as a separate UX task (may want a Ghostties-specific tagline).
5. **`main.swift` mixed copy** — acceptable to ship "Ghostties failed… `ghostty +help`"? **Recommend yes** — the CLI is `ghostty`.

---

## 5. Surprising Findings

- **No localization.** English-only codebase — single pass, no `.strings` files to sync.
- **`CFBundleDisplayName` already correct.** `INFOPLIST_KEY_CFBundleDisplayName = Ghostties` already flows into NSServices and many auto-populated menu items.
- **`Ghostty.sdef` is the largest concentration.** 22 user-visible description strings in one file — single-file PR material.
- **Risk-ordered ranking.** AppleScript dictionary (Unit 10) has the most surface area but the lowest regression risk (pure prose). NSAlert and main.swift (Units 3 and 8) touch less text but run during critical paths.
- **Module name stays.** Keeping `import Ghostty` narrows scope dramatically — no Swift symbol churn, no xib `customModule` edits, no project.pbxproj target churn beyond display-name strings.

---

## 6. Not Doing (explicit out-of-scope list)

- Module rename (`import Ghostty`)
- Any Swift class/struct/enum/file rename
- `~/.config/ghostty/` config path
- CLI binary `ghostty`
- Bundle identifier `com.mitchellh.ghostty.*` (or any identifier)
- URL schemes
- UserDefaults keys
- Upstream-owned URLs (github.com/ghostty-org, ghostty.org/docs)
- `GhosttyKit` framework import
- AppleScript class identifiers (`GhosttyScript*`)
- Four-character AppleScript event codes
- `Ghostty.sdef` file name itself
- `GhosttyCommit` Info.plist key
