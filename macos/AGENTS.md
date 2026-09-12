# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

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

## Help Book

- The Apple Help Book (`Ghostty.help`) behind the Help menu is generated
  by `zig build` into `zig-out/help/` and copied into the app bundle by
  the Xcode build. Its sources are `src/extra/help_book.zig` and the
  HTML/CSS/JS assets in `src/extra/help_book/`; see "macOS Help Book" in
  [HACKING.md](../HACKING.md).
- After changing help book sources, rebuild (`zig build
  -Demit-macos-app=false`) and run `macos/build.nu help-book-reset` to
  purge Help Viewer state (helpd's content cache and its Core Spotlight
  search donations; stale donations surface as "content not available"
  search results), then rebuild the app and relaunch it to re-register
  the book (which might take roughly 10s to finish).
- Stale sibling copies of Ghostty.app (`macos/build/`, Xcode DerivedData)
  can hijack help book resolution since all copies register the same book
  id; make sure the copy you launch is freshly built.
