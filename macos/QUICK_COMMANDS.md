# Quick Commands & Intelligent Process Monitoring

Open **View → Quick Commands**, click the sidebar button in the top bar, or press **⌘⇧B** (`Cmd+Shift+B`). Drag the divider to resize the right sidebar.
Each tab keeps its own visibility and width until it closes. The sidebar starts closed and does not restore its visibility across app launches.

---

## Features

### 1. 1-Click Command Execution & Insertion
- **▶ Execute mode**: writes the command text followed by one carriage return (`\r`).
- **✎ Insert mode**: writes the command text directly into the prompt without pressing Enter, allowing manual review and editing.
- **Split & Run**: hover over any command card to click the split icon, which creates a new right-side split and immediately runs the command in it.
- **Dynamic Placeholders**: commands with variables like `<host>`, `<user>`, or `{branch}` display an interactive parameter modal upon click, allowing you to fill in values before sending.
- **Auto-Injection**: tokens like `{clipboard}` and `{selection}` automatically inject current macOS clipboard or highlighted terminal text.

### 2. Full Native Keyboard Navigation
- **`↑` / `↓` (Up/Down Arrow)**: navigate through the command list with circular wrapping.
- **Auto-Scroll (`ScrollViewReader`)**: the list smoothly scrolls automatically to keep the currently selected command centered.
- **`Return`**: executes the highlighted command and immediately returns keyboard focus to the terminal.
- **`⌥ Return` (Option + Return)**: inserts the highlighted command into the terminal prompt and returns focus to the terminal.
- **`Escape`**: drops focus from the search field and returns focus to the active terminal surface.
- **Zero-Conflict Isolation**: key events are intercepted **only** when the sidebar has focus. Whenever the terminal pane is active (`firstResponder`), 100% of keystrokes and shell navigation pass directly to the shell (`zsh`, `bash`, etc.) without interference.

### 3. Broadcast Mode (Send to All Splits)
- Inspired by SecureCRT, click the broadcast icon in the sidebar header to toggle broadcast mode.
- When enabled, executing or inserting a command broadcasts the text across **all splits** in the active window simultaneously.

### 4. Categorized Group Tabs
- Horizontal group tabs (All, Git, Cisco, Linux, Docker, etc.) for quick filtering.
- Dynamic group creation via the `+ Group` button.
- Real-time command counter per group badge.

---

## Real-Time Process & AI Agent Monitor

Ghostty includes a low-overhead, native Darwin process monitoring subsystem (`TerminalProcessMonitor`) and Braille progress indicators:

### 🤖 Intelligent AI Agent State Detection
- Automatically detects AI coding agents running in the foreground or background:
  - **Google Antigravity CLI (`agy`)**
  - **Claude Code (`claude`)**
  - **Codex CLI (`codex`)**
  - **Ollama (`ollama`)**
- Uses Darwin `proc_pidinfo(PROC_PIDTASKINFO)` to compute real-time microsecond CPU deltas (`pti_total_user + pti_total_system`) across the agent and all child processes spawned by it.
- **Thinking vs Idle**:
  - When actively computing, researching, or generating code, the badge shows `[🤖 agy ⣀⣄⣤⣦ thinking]` with an animated Braille equalizer.
  - When paused and waiting for user prompt or input, the badge switches to `[🤖 agy ⣀⣀⣀⣀ idle]` and halts the animation, dropping CPU usage to **0.0%**.
  - Includes a 2.5-second smoothing hysteresis window to prevent flickering during token streaming chunks.

### ⚡ Background Jobs Badge & Popover
- Background processes (e.g. `sleep 10 &`, long builds, servers) are detected automatically.
- Displayed as an orange pill `[⠋ N bg]` in both the top bar and sidebar header.
- Clicking the pill opens an interactive popover displaying all running jobs, their PIDs, and a one-click **Kill** button (`SIGTERM`).
- Finished jobs show a brief green notification pill (e.g., `✓ sleep finished`).

### ⠋ Braille Progress Components
- Uses native Unicode Braille glyphs:
  - **Equalizer Bar**: `⣀⣄⣤⣦`
  - **Spinner**: `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`
  - **Wave**: `⡀⠄⠂⠁⠈⠐⠠⢀`
  - **Circle**: `◜◠◝◞◡◟`
- When idle (`isAnimating: false`), displays dimmed resting glyphs without running `TimelineView` timers.

---

## Balanced Terminal Top Bar

When `macos-topbar = true` is enabled in configuration, Ghostty renders a balanced, streamlined top navigation bar:
- **Left**: Current working directory badge (click to copy full path to clipboard) and New Tab button.
- **Center**: Foreground process indicator, AI Agent thinking/idle badge, background jobs counter pill, and split counter.
- **Right**: Split Right (`2x1`), Split Down (`1x2`), and Quick Commands sidebar toggle (`⌘⇧B`).

---

## Configuration

Add commands directly in your Ghostty configuration file (`~/.config/ghostty/config`):

```ini
# Quick commands
quick-command = title:"Run tests",command:"zig build test",action:execute,group:"Zig"
quick-command = title:"Git commit",command:"git commit -m \"<message>\"",action:insert,group:"Git"
quick-command = title:"Show IP interface",command:"show ip interface brief",action:execute,group:"Cisco"
quick-command = title:"Connect SSH",command:"ssh <user>@<host>",action:execute,group:"Linux"
quick-command = title:"Docker ps",command:"docker ps -a",action:execute,group:"Docker"

# Top bar & keybind
macos-topbar = true
keybind = cmd+shift+b=toggle_quick_commands
```

- Repeat `quick-command` to append entries in order.
- `title` and `command` are required and cannot be blank.
- `action` defaults to `insert`. Can be `insert` or `execute`.
- `group` is optional and categorizes the command into a tab.
- Reload Ghostty's configuration (`⌘,` or `Cmd+Shift+,`) to update these entries live.

---

## Local Storage & Dotfiles Sync

The local library is saved atomically as versioned JSON at:
```
~/.config/ghostty/quick-commands.json
```
- Direct compatibility with your personal dotfiles repository.
- Changes made from external editors (Neovim, VS Code, or `git pull`) are automatically detected via a native Darwin file system watcher and reloaded live without restarting Ghostty.

---

## Verification & Testing

```sh
# Run Zig quick-command unit tests:
zig test src/quick_command_test.zig --test-filter QuickCommand

# Run Ghostty macOS unit test suite:
nu macos/build.nu --configuration Debug --action test

# Compile optimized local release build:
nu macos/build.nu --configuration ReleaseLocal --arch arm64 --action build
```
