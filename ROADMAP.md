# Ghostty Fork — Feature Roadmap

## v1: Popup Terminal (shipped)

Multi-instance floating terminal windows with named profiles. Extends the existing Quick Terminal into a configurable popup system.

**Config:**
```
popup = shell:position:center,width:88%,height:76%,keybind:ctrl+shift+t,autohide:true
popup = lazygit:position:center,width:88%,height:76%,keybind:ctrl+shift+g,command:lazygit,persist:false
```

**Branch:** `feature/popup-terminal` | **PR:** #1

---

## v2: Config Hot-Reload + Popup Polish

Edit popup config, reload without rebuilding. Per-popup border color, opacity, working directory.

**Key deliverables:**
- Config hot-reload for popup profiles (edit config → reload → popups update)
- `cwd` property (inherit working directory or set explicit path)
- `opacity` property (per-popup background transparency)
- `border-color` property (per-popup border, like tmux `popup-border-style`)
- `dismiss-key` property (Esc-to-close)

**Status:** Not started

---

## v3: Session Management

Tmux-style named sessions. Switch between "work", "personal", "ops" — each with their own tabs/splits.

**Key deliverables:**
- Named sessions with `session = work:cwd:~/projects`
- Session switcher UI (fuzzy-searchable picker)
- Session persistence across app restart
- Keybind actions: `switch_session`, `new_session`, `show_session_picker`
- Popup-session integration (popups scoped to sessions)

**Status:** Not started

---

## v4: Vi Mode

Navigate terminal scrollback with vim keybindings. Search, select, yank — like tmux copy mode.

**Key deliverables:**
- Enter/exit vi mode via keybind
- hjkl/w/b/gg/G navigation through scrollback
- `/pattern` search with n/N
- v/V/Ctrl+v selection + y yank to clipboard
- Visual cursor overlay on renderer

**Status:** Not started

---

## v5: Vi Mode — Relative Line Numbers

Gutter with relative line numbers during vi mode for fast jump navigation.

**Depends on:** v4

**Status:** Not started

---

## Dependency Graph

```
v1 (done) → v2 (config hot-reload)
              ├→ v3 (sessions)        ← can run in parallel with v4
              └→ v4 (vi mode)         ← can run in parallel with v3
                  └→ v5 (rel numbers) ← requires v4
```
