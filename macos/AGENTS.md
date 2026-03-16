# macOS Trident (Ghostty Fork) Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

## Fork-Specific

- **Popup terminal:** `macos/Sources/Features/Popup/` (PopupManager, PopupController, PopupWindow)
- **Vi mode:** Overlay rendering in `src/renderer/Overlay.zig`, state in `src/ViMode.zig`
- **C API bridge for popups:** `PopupProfile.C` fields in `popup.zig` must match `ghostty_popup_profile_config_s` in `include/ghostty.h` exactly
- **Config bridge:** `Ghostty.Config.swift` `popupProfiles` computed property reads popup config from C API
- **Trident install:** Built app is copied to `/Applications/Trident.app` with `CFBundleDisplayName = Trident` and `GHOSTTY_CONFIG_PATH` pointing to `~/.config/trident/config`
- **Signing:** `codesign --force --deep --sign "Developer ID Application: Austin Tucker (3364PH2HE3)"`

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`
