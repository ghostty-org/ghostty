# GhosttyKanban Demo 技术文档

> 一个 macOS SwiftUI 应用，演示如何通过 Ghostty 公共 C API 将终端真正嵌入到自定义窗口中管理。

---

## 项目结构

```
demo/
├── Package.swift              # SwiftPM 项目配置（链接 libghostty-internal.a）
├── run.sh                     # 构建 + 创建 .app bundle + 启动
├── libghostty-internal.a      # GhosttyKit 预编译静态库 (384MB)
├── Sources/
│   ├── CGhostty/              # C 模块，暴露 ghostty.h API 给 Swift
│   │   ├── include/
│   │   │   └── ghostty.h      # Ghostty 公共 C API 头文件（来自 xcframework）
│   │   └── stub.c             # 占位源文件
│   └── GhosttyDemo/
│       ├── DemoApp.swift      # @main 入口，调用 EmbeddedTerminal.initialize()
│       ├── ContentView.swift  # 主界面：左面板 + 右面板（Tab bar + 终端）
│       └── EmbeddedTerminal.swift  # 核心：终端管理、多 Tab、键盘转发
└── docs/
    ├── direction-exploration.md    # 方向探索记录
    └── technical-demo.md           # 本文档
```

---

## 构建与运行

```bash
cd /Users/hue/Documents/ghostty-kanban/demo
./run.sh
```

`run.sh` 的工作流程：
1. `swift build` — 编译 Swift 代码并链接 `libghostty-internal.a`
2. 创建 `GhosttyDemo.app` bundle（含 Info.plist）
3. 启用 entitlements（辅助功能权限）
4. `open` 启动 app

---

## 架构

### 分层

```
┌───────────────────────────────────────────────────┐
│                    SwiftUI UI                     │
│  HSplitView                                       │
│    ├── LeftPanel（控制按钮、命令输入）              │
│    └── RightPanel                                 │
│          ├── TabBarView（Tab 切换）                │
│          ├── ZStack（多个 terminal 视图层叠）       │
│          │     └── TerminalViewWrapper (NSViewRepresentable) │
│          └── CommandBar（命令输入栏）               │
├───────────────────────────────────────────────────┤
│               EmbeddedTerminal                    │
│  （ObservableObject, @MainActor）                  │
│    ├── tabs: [TerminalTab]                        │
│    │     └── TerminalTab                          │
│    │           ├── surface: ghostty_surface_t     │
│    │           └── view: TerminalNSView           │
│    ├── ensureApp() / newTab() / selectTab()       │
│    ├── sendText() / handleKeyEvent()              │
│    └── TermStore（非 actor 资源管理）               │
│          ├── app: ghostty_app_t                   │
│          ├── config: ghostty_config_t              │
│          ├── surfaces: [ghostty_surface_t]         │
│          └── timer: Timer (30fps)                 │
├───────────────────────────────────────────────────┤
│               CGhostty (C 模块)                    │
│    └── ghostty.h → libghostty-internal.a          │
│          ├── ghostty_init() / _app_new() / _tick() │
│          ├── ghostty_surface_new() / _free()       │
│          ├── ghostty_surface_key() / _text()       │
│          ├── ghostty_surface_set_size() / _focus() │
│          └── ghostty_surface_draw()                │
└───────────────────────────────────────────────────┘
```

### 关键数据流

```
键盘输入流：
  NSEvent → TerminalNSView.keyDown()
         → EmbeddedTerminal.handleKeyEvent()
         → ghostty_input_key_s 构造
         → ghostty_surface_key(surface, &ke)
         → Ghostty 内部处理 → PTY → shell

文本发送流：
  用户输入命令 → sendText("cmd") → 自动追加 "\n"
         → ghostty_surface_text(surface, text, len)
         → Ghostty 内部处理 → PTY → shell 执行

渲染流：
  Timer @30fps → ghostty_app_tick(app)
         → Ghostty 处理事件、渲染
         → Metal render → CAMetalLayer → NSView

Tab 切换流：
  selectTab(at: index)
         → ghostty_surface_set_focus(old, false)
         → old.view.isHidden = true
         → ghostty_surface_set_focus(new, true)
         → new.view.isHidden = false
         → window.makeFirstResponder(new.view)
```

---

## 核心模块说明

### EmbeddedTerminal.swift

| 方法 | 说明 |
|------|------|
| `initialize()` | 调用 `ghostty_init()` 初始化全局状态（必须在 @main 之前调用） |
| `ensureApp()` | 创建 `ghostty_config` + `ghostty_app`，启动 30fps 渲染定时器 |
| `newTab(title:command:)` | 创建新 Tab：新建 `TerminalNSView` + surface，加入 `tabs` 并选中 |
| `selectTab(at:)` | 切换 Tab：blur 旧的 + hide，focus 新的 + unhide + 设为 first responder |
| `closeTab(at:)` | 关闭 Tab：free surface + 从列表移除，自动切换到邻居 |
| `sendText(_:to:)` | 发送文本到指定 surface（自动追加 `\n`） |
| `handleKeyEvent(_:surface:)` | 将 NSEvent 转换为 `ghostty_input_key_s` 并转发 |
| `handleFlagsChanged(_:surface:)` | 转发修饰键事件（Shift/Ctrl/Option/Cmd） |

### TerminalNSView

| 方法 | 说明 |
|------|------|
| `acceptsFirstResponder` | 返回 `true`，允许成为第一响应者接收键盘事件 |
| `viewDidMoveToWindow()` | 自动成为 first responder |
| `keyDown(with:)` | 转发按键事件到 terminal |
| `flagsChanged(with:)` | 转发修饰键事件 |
| `mouseDown(with:)` | 点击时重新成为 first responder |
| `findSurface()` | 遍历 terminal.tabs 找到自己对应的 surface |

### TerminalTab

| 属性 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `title` | String | 标签标题 |
| `surface` | `ghostty_surface_t` | Ghostty surface 句柄 |
| `view` | `TerminalNSView` | 对应的 NSView（键盘 first responder） |

---

## 链接配置

### Package.swift 关键配置

```swift
.target(
    name: "CGhostty",
    publicHeadersPath: "include",
    cSettings: [.define("GHOSTTY_STATIC")],
    linkerSettings: [
        .unsafeFlags(["/path/to/libghostty-internal.a"]),
        .unsafeFlags(["-framework", "Cocoa"]),
        .unsafeFlags(["-framework", "Metal"]),
        .unsafeFlags(["-framework", "MetalKit"]),
        .unsafeFlags(["-framework", "Carbon"]),
        .unsafeFlags(["-framework", "CoreGraphics"]),
        .unsafeFlags(["-framework", "CoreVideo"]),
        .unsafeFlags(["-framework", "IOSurface"]),
        .unsafeFlags(["-framework", "IOKit"]),
        .unsafeFlags(["-framework", "UniformTypeIdentifiers"]),
        .unsafeFlags(["-framework", "UserNotifications"]),
        .unsafeFlags(["-lc++"]),
        .unsafeFlags(["-lz"]),
    ]
)
```

### `GHOSTTY_STATIC`

必须在编译时定义此宏，因为 ghostty.h 中的函数声明会根据 `GHOSTTY_STATIC` / `GHOSTTY_BUILD_SHARED` 切换 `__declspec(dllexport)` / `__declspec(dllimport)` 属性。静态链接需要定义此宏。

---

## 运行回调

`ghostty_runtime_config_s` 定义了 6 个 C 回调，当前实现状态：

| 回调 | 签名 | 当前实现 | 说明 |
|------|------|----------|------|
| `wakeup_cb` | `(void*) → void` | ✅ 调用 `ghostty_app_tick()` | 驱动事件循环和渲染 |
| `action_cb` | `(app, target, action) → bool` | ❌ 返回 `false` | 不处理 Ghostty action，某些功能受限 |
| `read_clipboard_cb` | `(void*, clipboard, state) → bool` | ❌ 返回 `false` | 无剪切板读取 |
| `confirm_read_clipboard_cb` | `(void*, str, state, request) → void` | ❌ no-op | 无剪切板确认 |
| `write_clipboard_cb` | `(void*, loc, content, len, confirm) → void` | ❌ no-op | 无剪切板写入 |
| `close_surface_cb` | `(void*, bool) → void` | ❌ no-op | 不处理 surface 关闭 |

---

## 已知问题与限制

### 严重

- **action_cb 未实现** → Ghostty 的 `new_tab`、`close_tab` 等 action 不会触发对应行为。当前 Tab 管理是 Demo 自身实现的，Ghostty 触发的 action 被忽略。
- **clipboard 回调未实现** → 终端内复制粘贴可能不工作。
- **`ghostty_surface_t` 空值检查** → `ghostty_surface_new()` 返回的是 `UnsafeMutableRawPointer`（非 Optional），不能直接用 `nil` 检查是否失败。

### 中等

- **渲染驱动** → 当前 30fps NSTimer 在终端空闲时浪费 CPU。应改为 Ghostty 内部的 display link 或 request 驱动的渲染。
- **键盘事件** → `event.characters` 的指针生命周期在 ghostty_input_key_s 中不安全（指向 Swift 临时字符串缓冲区，理论上会悬空）。
- **TermStore.deinit** → 分离的 TermStore 虽然在模式上正确，但 surface 的生命周期管理在 Tab 切换和 deinit 时有交叉，需仔细处理。

### 低

- **UI 细节** → Tab 栏无拖拽排序、无右键菜单、无图标。
- **配置** → 自动加载 `~/.config/ghostty/` 配置，可能与用户预期不符。
- **多窗口** → 目前只支持一个窗口内的多 Tab。

---

## 链表依赖

```
GhosttyDemo → CGhostty → libghostty-internal.a
                                 │
                    ┌────────────┼──────────────┐
                    ▼            ▼              ▼
              Metal.framework  Cocoa.framework  libc++.dylib
                    │              │
                    ▼              ▼
              MetalKit.framework  Carbon.framework
                    │              │
                    ▼              ▼
              CoreVideo.framework  CoreGraphics.framework
                    │
                    ▼
              IOSurface.framework
                    │
                    ▼
              IOKit.framework
                    │
                    ▼
              UniformTypeIdentifiers.framework
                    │
                    ▼
              UserNotifications.framework
```

---

## 与 GhosttyKanban 架构的关系

当前 Demo 演示的技术路径与 Kanban 的最终架构（`KanbanWindowManager` + borderless 子窗口）在目标上一致，但在实现方式上不同：

| 维度 | Kanban 架构 | Demo |
|------|------------|------|
| 终端来源 | Ghostty.app 的 `TerminalController` | `ghostty_surface_new()` C API 直接创建 |
| 窗口 | 主窗口 + borderless 子窗口 | 同一窗口内 ZStack 层叠 NSView |
| Tab 管理 | `childWindow.orderOut()/orderFront()` | `isHidden = true/false` |
| 代码修改 | 需要修改 Ghostty 源码 | 不修改 Ghostty 源码，仅 link xcframework |
| 键盘 | AppKit 原生事件链 | TerminalNSView 自定义转发 |
| 依赖 | 整个 Xcode + Zig 构建链 | 仅需要预编译的 .a 文件 + SwiftPM |

Demo 证明了可以通过纯公共 C API 实现终端嵌入，为 Kanban 架构提供了一个"可脱离 Ghostty.app 独立运行"的备选路径。
