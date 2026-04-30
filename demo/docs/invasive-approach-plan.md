# 侵入式 Demo 方案文档

> 目标：以最小改动量，利用 Ghostty 现有 Swift 源码，实现与 Ghostty.app 功能一致的原生终端嵌入。

---

## 1. 为什么 C API 方案不够

### 1.1 Ghostty 的分层结构

```
Ghostty.app（~2万行 Swift/ObjC）
├── Ghostty.App.swift           ← 全局 app 对象，完整回调实现
├── SurfaceView_AppKit.swift    ← 终端完整 NSView（99KB！）
│     ├── 鼠标拖选 / 双击选词 / 三击选行
│     ├── 系统剪贴板读写（NSPasteboard）
│     ├── IME 输入法 / markedText / selectedRange
│     ├── 光标形状切换（IBeam/Arrow/Resize/Link）
│     ├── 拖放文件到终端
│     ├── 右键菜单（查找、服务、字典）
│     ├── Cmd+C 复制 / Cmd+V 粘贴（performKeyEquivalent）
│     ├── 安全输入（SecureInput）
│     ├── 窗口焦点 / 通知监听
│     └── title / bell / url hover / progress bar
├── Ghostty.Input.swift         ← 输入事件编码
├── Ghostty.Config.swift        ← 配置管理（37KB）
├── TerminalView.swift          ← SwiftUI 分屏布局
├── TerminalController.swift    ← NSWindowController + tab 管理
└── Helpers/（Cursor, MetalView, Extensions...）
        │
        ▼ import GhosttyKit
        │
GhosttyKit.xcframework = module.map { ghostty.h } + libghostty-internal.a
        │
        ▼
libghostty-internal.a（384MB Zig 核心）
        ├── 终端模拟（VT500+ 序列解析）
        ├── PTY 管理（forkpty）
        ├── Metal 渲染
        └── ghostty.h 的 70+ 个 C 函数
```

### 1.2 当前 Demo 缺失的功能

| 功能 | 原因 | 在 Ghostty 源码中的位置 |
|------|------|------------------------|
| 鼠标拖选文字 | TerminalNSView 未转发 mouseDragged | SurfaceView_AppKit.swift:900+ |
| 复制 (Cmd+C) | clipboard 回调实现不完整；performKeyEquivalent 未代理所有快捷键 | SurfaceView_AppKit.swift:500+ |
| 粘贴 (Cmd+V) | 同上 | SurfaceView_AppKit.swift:500+ |
| 输入法/IME | 未实现 insertText/markedText | SurfaceView_AppKit.swift:600+ |
| 光标形状 | 未监听 mouse_shape action | SurfaceView_AppKit.swift:456-520 |
| 拖放文件 | 未注册 draggedTypes | SurfaceView_AppKit.swift:358 |
| 右键菜单 | 未实现 willOpenMenu | SurfaceView_AppKit.swift:××× |
| 快捷键绑定 | action_cb 返回 false | Ghostty.App.swift:action() |
| 搜索 (Cmd+F) | 未实现搜索 UI | SurfaceView_AppKit.swift:43-73 |
| 进度条 (OSC 9) | 未处理 progress 状态 | SurfaceView_AppKit.swift:23-36 |
| URL hover banner | 未监听 mouse_over_link action | URLHoverBanner.swift |
| 通知（bell） | 未处理 bell action | SurfaceView_AppKit.swift |
| 安全输入 | 未集成 SecureInput | SecureInput/ |
| 关闭确认 | close_surface_cb 未实现 | Ghostty.App.swift |

**结论：Ghostty.app 的功能不是"一行一行缺失"的，而是整个 AppKit 集成层完全没有使用。SurfaceView_AppKit.swift（99KB）包含了上面所有功能。**

---

## 2. 侵入式方案

### 2.1 核心思路

**不重新实现 Ghostty 的 AppKit 运行时，而是直接复用 Ghostty 的 Swift 源码。**

关键事实：
- `GhosttyKit` 模块 = `module { umbrella header "ghostty.h" }`，等价于我们 demo 的 `CGhostty`
- `Ghostty.App` 和 `SurfaceView` 是独立于 `NSWindow`/`NSApplication` 的 Swift 类
- `SurfaceView.init(_ app: ghostty_app_t)` 只需要 `ghostty_app_t`，不依赖窗口系统
- `SurfaceView` 内部处理了所有 AppKit 交互——鼠标、键盘、剪贴板、IME、光标、拖放

### 2.2 具体路径

```
步骤 1：模块重命名
    将 demo 的 CGhostty 模块重命名为 GhosttyKit（与 Ghostty 的模块名一致）
    → Ghostty 的 Swift 源码可以不加修改地 import

步骤 2：纳入 Ghostty Swift 源码
    从 macos/Sources/ 复制必要文件到 demo/Sources/GhosttyRuntime/
    保持目录结构和 import 语句不变

步骤 3：创建 SwiftUI 桥接层
    用 Ghostty.App + SurfaceView 替代手写的 EmbeddedTerminal
    十几行代码即可
```

### 2.3 需要纳入的文件

#### 核心（必须）

```
Sources/Ghostty/
├── Ghostty.App.swift              # 全局 app，所有回调实现
├── Ghostty.Surface.swift          # Surface 封装
├── Ghostty.Config.swift           # 配置
├── Ghostty.ConfigTypes.swift      # 配置类型
├── Ghostty.Input.swift            # 输入事件编码
├── Ghostty.Action.swift           # Action 类型
├── Ghostty.Event.swift            # 事件类型
├── Ghostty.Error.swift            # 错误类型
├── Ghostty.Command.swift          # 命令解析
├── Ghostty.Shell.swift            # Shell 工具
├── Ghostty.Inspector.swift        # Inspector
├── Ghostty.MenuShortcutManager.swift
├── GhosttyPackage.swift           # build info
├── GhosttyPackageMeta.swift
├── Ghostty.ChildExitedMessage.swift
├── GhosttyDelegate.swift
├── FullscreenMode+Extension.swift
└── NSEvent+Extension.swift

Sources/Ghostty/Surface View/
├── SurfaceView.swift              # SwiftUI wrapper
├── SurfaceView_AppKit.swift       # ★ 核心：99KB AppKit 实现
├── SurfaceView+Image.swift
├── SurfaceView+Transferable.swift
├── OSSurfaceView.swift            # 基类
├── SurfaceScrollView.swift
├── SurfaceDragSource.swift
├── SurfaceGrabHandle.swift
├── SurfaceProgressBar.swift
├── ChildExitedMessageBar.swift
├── InspectorView.swift
└── SurfaceView_UIKit.swift        # 不需要，但保留也无妨

Sources/Helpers/
├── Cursor.swift                   # 光标样式
├── MetalView.swift                # Metal 渲染
├── Weak.swift
├── KeyboardLayout.swift
├── Backport.swift
├── CrossKit.swift
├── CodableBridge.swift
├── ObjCExceptionCatcher.h
├── ObjCExceptionCatcher.m
├── HostingWindow.swift
├── NonDraggableHostingView.swift
├── VibrantLayer.h
├── VibrantLayer.m
├── TabTitleEditor.swift
├── TabGroupCloseCoordinator.swift
├── LastWindowPosition.swift
├── PermissionRequest.swift
├── URLHoverBanner.swift
├── AppInfo.swift
├── ExpiringUndoManager.swift
└── Extensions/                   # 全目录

Sources/Features/
├── ClipboardConfirmation/         # 剪贴板确认弹窗
├── Secure Input/                  # 安全输入
└── Terminal/                     # TerminalView（可选）
```

#### 不需要的文件

```
Sources/App/                       # AppDelegate, main.swift — 我们有自己的 app
Sources/Features/Settings/         # 设置窗口 — Demo 不需要
Sources/Features/About/            # 关于窗口
Sources/Features/Update/           # 自动更新
Sources/Features/QuickTerminal/    # 快速终端
Sources/Features/Command Palette/  # 命令面板（可选）
Sources/Features/Services/         # 系统服务
Sources/Features/Global Keybinds/  # 全局快捷键
Sources/Features/App Intents/      # Siri/Shortcuts
Sources/Features/Custom App Icon/  # 自定义图标
Sources/Features/AppleScript/      # AppleScript 支持
```

### 2.4 模块依赖图

```
DemoApp.swift
  └─ ContentView.swift
       ├─ TerminalTabView (新建，10-20 行)
       │    └─ Ghostty.App + Ghostty.SurfaceView
       │         ├─ ghostty_app_t → libghostty-internal.a
       │         └─ 全部 AppKit 集成 (鼠标/键盘/剪贴板/IME/...)
       └─ LeftPanel.swift (看板控制，保留)
```

### 2.5 代码改动量估算

| 文件 | 改动 | 说明 |
|------|------|------|
| `demo/Package.swift` | ~30 行 | 重命名 CGhostty → GhosttyKit，添加 GhosttyRuntime target |
| `CGhostty/` → `GhosttyKit/` | ~3 行 | 目录重命名，stub.c 不变 |
| `demo/Sources/GhosttyRuntime/` | ~60 文件 | 复制自 macos/Sources/，**代码不改** |
| `EmbeddedTerminal.swift` | **删除** | SurfaceView 替代了全部功能 |
| `ContentView.swift` | ~40 行 | 简化为直接使用 Ghostty.App + SurfaceView |
| `DemoApp.swift` | ~10 行 | 改用 Ghostty.App 初始化 |

**总改动：~80 行新代码 + 复制文件，不修改 Ghostty 源码。**

---

## 3. 需要的适配工作

### 3.1 `import GhosttyKit` 兼容

当前 Ghostty Swift 源码都写 `import GhosttyKit`。我们将 demo 的 C 模块
从 `CGhostty` 重命名为 `GhosttyKit`，模块名就一致了。

### 3.2 `AppDelegate` 耦合

`SurfaceView_AppKit.swift:217`：
```swift
if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
    self.derivedConfig = DerivedConfig(appDelegate.ghostty.config)
} else {
    self.derivedConfig = DerivedConfig()  // ← 已有 fallback
}
```

代码已经有 fallback 路径。Demo 不走 AppDelegate，所以自动走 `DerivedConfig()` 默认配置。

同理，`Ghostty.App.init()` 不依赖 AppDelegate，可以直接创建 app。

### 3.3 NotificationCenter 依赖

`SurfaceView` 监听了这些通知：
- `Ghostty.Notification.didUpdateRendererHealth`
- `Ghostty.Notification.didContinueKeySequence`
- `Ghostty.Notification.didEndKeySequence`
- `Ghostty.Notification.didChangeKeyTable`
- `.ghosttyConfigDidChange`
- `.ghosttyColorDidChange`
- `.ghosttyBellDidRing`
- `NSWindow.didChangeScreenNotification`

这些通知通过 `Ghostty.App` 发送，和 `NSApplication`/`AppDelegate` 无关。

### 3.4 Event Monitor

`SurfaceView` 使用 local event monitor 监听 `keyUp` 和 `leftMouseDown`。这个机制依赖 `NSApplication`，但在任何 macOS 应用中都可以正常工作。

### 3.5 `GhosttyMenuShortcutManager`

这个类注册全局快捷键（`Cmd+,` 等），依赖 `AppDelegate` 的菜单。Demo 可以移除这个依赖，或者简化。

---

## 4. 多 Tab 管理方案

### 4.1 每个 Tab 一个独立 SurfaceView

```swift
class TerminalTabManager: ObservableObject {
    @Published var tabs: [SurfaceViewTab] = []
    @Published var activeIndex: Int = 0
    
    // 每个 tab 创建一个 SurfaceView
    func newTab() {
        let surfaceView = Ghostty.SurfaceView(ghostty.app!)
        surfaceView.configure(...)
        tabs.append(SurfaceViewTab(view: surfaceView))
    }
}

struct SurfaceViewTab {
    let id = UUID()
    let surfaceView: Ghostty.SurfaceView
    let title: String
}
```

### 4.2 切换逻辑

```swift
func selectTab(at index: Int) {
    let old = tabs[activeIndex].surfaceView
    let new = tabs[index].surfaceView
    old.isHidden = true
    ghostty_surface_set_focus(old.surface, false)
    new.isHidden = false
    ghostty_surface_set_focus(new.surface, true)
    activeIndex = index
}
```

---

## 5. 实施步骤

### Phase 1：模块重命名 + 验证编译
1. 重命名 `CGhostty` → `GhosttyKit`
2. 更新现有 Swift 代码的 `import` 语句
3. 验证当前 demo 编译通过

### Phase 2：纳入 Ghostty Swift 源码
1. 创建 `demo/Sources/GhosttyRuntime/` 目录
2. 从 `macos/Sources/` 复制第 2.3 节列出的文件
3. 在 `Package.swift` 中添加 `GhosttyRuntime` target
4. 编译，解决未满足的依赖

### Phase 3：重构 Demo UI
1. 删除 `EmbeddedTerminal.swift`
2. 简化 `ContentView.swift`：用 `Ghostty.App` + `SurfaceView` 替代
3. 实现基于 SurfaceView 的 Tab 管理
4. 编译 + 测试

### Phase 4：验证功能
1. 鼠标拖选文字 ✓
2. Cmd+C 复制 / Cmd+V 粘贴 ✓
3. Delete/Backspace 键 ✓
4. IME 输入法 ✓
5. 光标形状切换 ✓
6. 多 Tab 管理 ✓
7. 命令发送 + Enter 执行 ✓

---

## 6. 风险与 Unknowns

| 风险 | 可能性 | 影响 | 缓解 |
|------|--------|------|------|
| Swift 文件之间有隐藏的循环依赖 | 中 | 需要额外文件 | 按编译错误逐步添加 |
| `GhosttyMenuShortcutManager` 强依赖 AppDelegate | 高 | 编译失败 | 移除或 stub |
| `Ghostty.App` 中的 `#if os(macOS)` 检查 | 低 | 编译警告 | Demo 是 macOS-only，不受影响 |
| Swift 6 并发警告（actor isolation） | 中 | 编译警告 | SurfaceView 已标注 @MainActor |
| libghostty-internal.a 版本不匹配 Ghostty Swift 源码 | 低 | 运行时 crash | 确保 .a 和 Swift 源码来自同一 git commit |
| 未复制的文件中有运行时依赖 | 中 | 运行时 crash | 先在现有 Ghostty.app 中找出所有引用 |

---

## 7. 与 C API 方案的对比

| 维度 | C API 方案（当前） | 侵入式方案 |
|------|-------------------|-----------|
| 修改 Ghostty 源码 | 0 | 0（复制，不修改） |
| 终端功能完整度 | ~30% | ~95% |
| 需要写的代码 | 500+ 行 + 持续补功能 | ~80 行 |
| 需要复制的文件 | 1（ghostty.h） | ~60 个 Swift 文件 |
| 鼠标拖选 | 需手写 | ✅ 自带 |
| 剪贴板 | 需手写 | ✅ 自带 |
| IME 输入法 | 需手写 | ✅ 自带 |
| 光标形状 | 需手写 | ✅ 自带 |
| 拖放文件 | 需手写 | ✅ 自带 |
| 快捷键绑定 | 需手写 | ✅ 自带 |
| Tab 管理 | 需手写 | 需手写（但更简单） |
| action_cb | 未实现 | ✅ Ghostty.App 已实现 |
| 构建依赖 | SwiftPM only | SwiftPM + 文件复制 |
