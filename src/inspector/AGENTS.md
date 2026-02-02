# Inspector Subsystem

The inspector is a feature of Ghostty that works similar to a
browser's developer tools. It allows the user to inspect and modify the
terminal state.

- See the full C API by finding `dcimgui.h` in the `.zig-cache` folder
  in the root: `find . -type f -name dcimgui.h`. Use the newest version.
- See full examples of how to use every widget by loading this file:
  <https://raw.githubusercontent.com/ocornut/imgui/refs/heads/master/imgui_demo.cpp>
- On macOS, run builds with `-Demit-macos-app=false` to verify API usage.
- There are no unit tests in this package.
