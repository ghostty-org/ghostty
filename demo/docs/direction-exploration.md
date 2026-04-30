# Ghostty Kanban 方向探索记录

> 目标：在不修改 Ghostty 源码的前提下，将 Ghostty 终端真正嵌入到我们的看板应用右侧面板中，
> 支持完整的终端交互（键盘输入、命令执行）和多 Tab 管理。

---

## 探索过程

### 方案 A：AppleScript 控制 + Accessibility 定位

**思路**：
通过 `osascript` 发送 AppleScript 命令控制 Ghostty.app，然后用 System Events Accessibility API 将 Ghostty 窗口的位置和大小设置为看板右侧面板的区域。

**验证过程**：
- `open -na Ghostty.app --args -e "command"` 可创建运行指定命令的窗口 ✅
- AppleScript `new tab`、`select tab`、`split` 等命令可用 ✅
- `input text "cmd" & return to term` 可发送命令到终端 ✅
- System Events 可设置窗口位置和大小：
  ```applescript
  tell application "System Events"
      tell process "Ghostty"
          set position of window 1 to {x, y}
          set size of window 1 to {w, h}
      end tell
  end tell
  ```
- `perform action "..." on terminal id "xxx"` 可执行 Ghostty action ✅

**结果**：❌ 被拒

**问题**：
- Ghostty 窗口仍然是独立的 OS 窗口，只是视觉上被挪到了看板右侧
- 用户可以 cmd+tab 切换到 Ghostty 窗口，与看板分离
- 需要 Accessibility 权限
- 无法实现真正的"嵌入"

---

### 方案 B：GhosttyKit.xcframework 静态库链接

**思路**：
Ghostty 项目自带了预编译的 `GhosttyKit.xcframework`（384MB 静态库），其中包含完整的终端渲染引擎。
通过链接此库并调用 C API，可以在我们的进程内创建 Ghostty surface，直接渲染到指定的 NSView 上。

**关键 API**：

```c
// 1. 初始化全局状态
ghostty_init(argc, argv);

// 2. 创建配置
ghostty_config_new();
ghostty_config_load_default_files(cfg);
ghostty_config_finalize(cfg);

// 3. 创建 app（带运行时回调）
ghostty_runtime_config_s rt = { ... };
ghostty_app_new(&rt, cfg);

// 4. 创建 surface（嵌入到指定 NSView）
ghostty_surface_config_s sc = {
    .platform_tag = GHOSTTY_PLATFORM_MACOS,
    .platform.macos.nsview = myNSView,
    ...
};
ghostty_surface_new(app, &sc);
```

**优势**：
- 真正的进程内嵌入 — terminal 渲染在调用方的 NSView 里
- 完整的终端功能 — Metal 渲染、PTY、shell 进程
- 不从属于 Ghostty.app，可在任意 macOS 应用中使用
- 不修改 Ghostty 源码

**依赖**：
- `libghostty-internal.a`（来自 GhosttyKit.xcframework）
- 系统框架：Cocoa, Metal, MetalKit, Carbon, CoreGraphics, CoreVideo, IOSurface, IOKit, UniformTypeIdentifiers, UserNotifications
- `libc++`、`libz`

**结果**：✅ 最终采用

---

### 方案 C：直接使用 ghostty.h C API（不修改源码）

这个方案与方案 B 本质上是同一个方向，核心观点是：
> "使用 Ghostty 的公共 C API 并非修改源码，而是使用项目已提供的接口。"

`ghostty.h` 定义在 `include/ghostty.h`，也在 `GhosttyKit.xcframework` 中有一份拷贝。
该头文件声明了完整的嵌入 API，包括 surface 创建、键盘事件、文本发送、窗口控制等。

---

## 最终方案架构

```
Demo.app 进程
  │
  ├── SwiftUI 主界面 (HSplitView)
  │     ├── 左面板：控制按钮
  │     └── 右面板：Tab bar + 终端区域
  │
  ├── EmbeddedTerminal (ObservableObject)
  │     ├── TermStore (非 actor 隔离的资源管理)
  │     │     ├── ghostty_app_t
  │     │     ├── ghostty_surface_t[] (多 Tab 各自一个 surface)
  │     │     └── ghostty_config_t
  │     │
  │     ├── TerminalTab[]
  │     │     ├── id / title
  │     │     ├── ghostty_surface_t
  │     │     └── TerminalNSView (键盘 first responder)
  │     │
  │     └── C 回调
  │           ├── wakeup_cb → ghostty_app_tick()
  │           ├── action_cb → return false (未实现)
  │           ├── clipboard → no-op
  │           └── close_surface → no-op
  │
  └── CGhostty (C 模块)
        ├── module.modulemap
        └── ghostty.h → #import "include/ghostty.h"
              │
              └── libghostty-internal.a (384MB 预编译静态库)
```

---

## 关键决策点

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| 终端嵌入方式 | AppleScript / Accessibility / C API | C API (GhosttyKit) | 真正的进程内嵌入，不依赖外部进程 |
| 库文件来源 | 从源码构建 / 使用预编译 | 使用 xcframework 预编译 | 无需 Zig 工具链，零源码修改 |
| 链接方式 | SwiftPM binaryTarget / 直接 .a | 直接 .a + unsafeFlags | SwiftPM 对 .xcframework 支持有限 |
| 模块包装 | module.modulemap / bridging header | module map | 干净地暴露 C API 给 Swift |
| 多 Tab 实现 | 多个窗口 / 多个 surface | 多个 surface + 切换可见性 | 效率高，都在同一进程同一窗口内 |
| 键盘事件 | NSTextView / 自定义 NSView | 自定义 TerminalNSView | 完全控制 keyDown 转发路径 |
| 渲染驱动 | CVDisplayLink / NSTimer | NSTimer 30fps | 简单可靠，终端不需要 60fps |
| 资源管理 | @MainActor 隔离 / 独立 Store | TermStore（非 actor） | 避免 deinit 时的 actor 隔离冲突 |

---

## 技术债务 / 待改进

- [ ] **action_cb** — 返回 false 导致某些 Ghostty 行为（如新窗口创建）不会触发
- [ ] **clipboard 回调** — 剪切板复制粘贴需要实现
- [ ] **渲染驱动** — 当前 30fps 定时器，应改用 CVDisplayLink 或 Metal 的 draw handler
- [ ] **键盘布局** — 当前只转发 keyCode，未处理 IME/输入法/Unicode 组合
- [ ] **多窗口** — 当前只支持一个窗口内的多 Tab，不支持多窗口
- [ ] **拖拽分屏** — 当前无分屏功能，Tab 是基本管理单位
