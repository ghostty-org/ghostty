# Ghostty Kanban Sidebar 架构演进记录

> 目标：在 Ghostty 终端中实现一个独立于 tab 的侧边栏看板，
> 要求 sidebar 与 tab bar 位于同一层级（不是下方），
> 可拖拽调节宽度，数据在所有 tab 间共享。

---

## 尝试记录

### 尝试 1：Inline Sidebar（原始方案）

**文件**：`KanbanSidebarContainer` in `TerminalController.swift`

**方案**：
每个 TerminalController 的 `windowDidLoad()` 创建一个 `KanbanSidebarContainer`
(HStack：SidePanelView + TerminalView)，嵌入在内容区。

**结果**：✅ 工作，但每个 tab 各自有自己的 BoardState，数据不互通。

**问题**：每个 tab 独立加载 tasks.json，A tab 添加的任务 B tab 看不到。
各扫各的盘，CPU 和内存浪费。

---

### 尝试 2：BoardState.shared 单例

**文件**：`KanbanBoardState.swift`、`SidePanelView.swift`

**方案**：
`BoardState` 改为 `static let shared = BoardState()` 单例，
`SidePanelView` 用 `@StateObject private var boardState = BoardState.shared`。

**结果**：✅ 所有 tab 数据一致。

**遗留**：每个 tab 仍然有各自的 `SidePanelView` 实例（但是观察同一份数据）。
首 tab 侧边栏默认不显示（isVisible 默认 false），设置为 true 后可以。

---

### 尝试 3：浮动面板（独立 NSPanel）

**文件**：`KanbanPanelController.swift` (NSPanel-based)

**方案**：
创建一个独立的 NSPanel 窗口（有标题栏），作为 sidebar 宿主。
跟 Ghostty 窗口是「两个独立窗口」。

**结果**：❌ 用户不接受。
"现在彻底变成两个独立窗口了！我不要这样！"

**失败原因**：窗口完全独立，可以单独移动、最小化，
视觉上跟 Ghostty 窗口没有任何关联。

---

### 尝试 4：Theme Frame Overlay

**文件**：`KanbanSidebarController` (NSView overlay)

**方案**：
把 sidebar 作为 NSView 添加到 window.contentView.superview（即 NSThemeFrame）。
Theme Frame 在切换 tab 时不会变（只有 contentView 变），
所以 sidebar 可以跨 tab 保持。

**结果**：❌ sidebar 覆盖了 terminal 内容。
"面板覆盖掉了一部分 Terminal 面板的内容"

**失败原因**：sidebar 在 theme frame 层级，高于 contentView，
terminal 被遮挡。如果要避免遮挡，需要同时缩小 contentView，
但 contentView 的布局不由我们控制。

---

### 尝试 5：NSTitlebarAccessoryViewController（spacer 推 tab bar）

**文件**：`KanbanPanelController.swift` (accessory-based)

**方案**：
用 `NSTitlebarAccessoryViewController(.leading)` 做一个空白 spacer，
把原生 tab bar 推到右边。同时 inline sidebar 用 `.ignoresSafeArea(.all)`
延伸到标题栏区域。sidebar + spacer 组合让 sidebar 看起来跟 tab bar 同层。

**结果**：❌ 视图被标题栏裁剪。
"Sidebar 只在标题栏！下面完全被 Terminal 挡住了！"

**失败原因**：NSTitlebarAccessoryViewController 的视图被标题栏的
`masksToBounds` 裁剪，只能看见标题栏高度的部分，延伸不到内容区。

---

### 尝试 6：NSTitlebarAccessoryViewController（全高 + 禁用裁剪）

**文件**：`KanbanSidebarController`

**方案**：
在尝试 5 的基础上，递归遍历 theme frame 的所有子视图，
设置 `masksToBounds = false` 以允许 sidebar 延伸到内容区。

**结果**：❌ View 层级混乱。
只在第一个 tab 有效，切换 tab 后被覆盖。

**失败原因**：
1. 禁用系统私有视图的裁剪可能不生效或被系统重置
2. tab 切换时 window 改变，需要重新挂载，逻辑复杂

---

### 尝试 7：透明 Overlay Panel（点击穿透）

**文件**：`KanbanPanelController.swift` (NSPanel overlay)

**方案**：
创建一个透明 NSPanel（无标题栏、无阴影），作为 Ghostty 窗口的 child window。
Panel 比 Ghostty 窗口左扩 85px。左侧 85px 是 sidebar（交互），
剩余区域透明且点击穿透到下方的 Ghostty 窗口。

**结果**：❌ 但思路对了一半。
"tab 不会覆盖 sidebar 了。但 sidebar 完全暴露在外面，
不跟整个软件是一个整体。而且不能调节宽度。"

**成功点**：✅ tab 不覆盖 sidebar
✅ Ghostty 原生 tab 系统完全不动
✅ sidebar 始终可见，跨 tab 不变

**失败原因**：
1. 标题栏区域没有囊括 sidebar，视觉上不一体化
2. sidebar 和 terminal 中间的边界不可调节（因为 sidebar 是独立窗口）
3. sidebar 失去了所有自定义界面功能

---

### 尝试 8：Inline + Titlebar Spacer（回退又试）

**文件**：`KanbanPanelController.swift`、
`TerminalController.swift:KanbanSidebarContainer`

**方案**：
回到 inline 布局（HStack: sidebar + terminal），
加上 `.fullSizeContentView` + `.ignoresSafeArea(.all)`，
配合 NSTitlebarAccessoryViewController spacer 推 tab bar。

**结果**：❌
"tab 还是包括了 sidebar！"

**失败原因**：macOS 原生 tab bar 由窗口服务器绘制，
永远在内容视图之上。fullSizeContentView 让内容延伸到标题栏背后，
但 tab bar 仍然绘制在内容上方。sidebar 在标题栏区域被 tab bar 覆盖。

---

### 尝试 9：自定义外框 + 单窗口架构（最终方案 ✅）

**文件**：
- `KanbanWindowManager.swift`（新增）
- `TerminalController.swift`（KanbanSidebarContainer 简化为透传壳）
- `AppDelegate.swift`（启动走 KanbanWindowManager）
- `KanbanPanelController.swift`（删除）

**方案**：
完全放弃 macOS 原生 tab 系统。KanbanWindowManager 创建**一个主窗口**，
窗口内容为：

```
┌─ 透明标题栏 (traffic lights ●●●) ───────────────┐
├──────┬──────────────────────────────────────────┤
│side  │ [Tab1] [Tab2] [+]       ← 自定义 tab bar │
│bar   ├──────────────────────────────────────────┤
│80px  │                                          │
│drag  │ 子窗口 (borderless, terminal only)        │
└──────┴──────────────────────────────────────────┘
```

- 主窗口 `tabbingMode = .disallowed`（禁用原生 tab）
- 每个 "tab" = 一个 TerminalController + 它的 borderless 子窗口
- TerminalController 的 `windowDidLoad` 只创建 `TerminalView`（无 sidebar）
- `_KanbanRootView` 是唯一创建 `SidePanelView` 的地方
- 切换 tab = 显示/隐藏对应的子窗口 + 调整位置
- "+" 按钮 = `KanbanWindowManager.newTab()`

**结果**：✅
- Sidebar 跟 tab bar 同一层级 ✅
- 拖拽可调 sidebar 宽度 ✅
- 只有一个 sidebar 实例 ✅
- Ghostty 原生 tab 系统不需要动（只要不让它创建独立窗口）✅
- 每个 TerminalController 窗口 borderless 嵌入主窗口 ✅

**成功原因**：
1. 不再尝试在原生 tab 系统里做文章
2. 一个主窗口拥有全部内容，子窗口只提供 terminal 渲染
3. 清晰的定义：谁创建什么、谁拥有什么

---

## 遗留问题

1. **Ghostty session 创建/恢复走的不是 KanbanWindowManager** ——
   `onKanbanCreateSplit`、`onKanbanResumeSession` 等 handler 调用的是
   `ghostty.newTab()`，会创建独立窗口（不进 KanbanWindowManager）。
   需要把这些路径也改为调用 `KanbanWindowManager.newTab()`。

2. **Cmd+Shift+S 快捷键** —— 当前 `BaseTerminalController` 里
   切换的是 `SidebarState.shared.isVisible`。但主窗口的 `_KanbanRootView`
   用的是自己的 `@State sbVisible`。没有连通。

3. **自定义 tab bar 功能简陋** —— 目前只有 "Tab 1"、"Tab 2" 等默认名字，
   没有 tab 标题同步、没有拖拽排序、没有右键菜单。

4. **SidePanelViewModel 初始化时序** —— `KanbanWindowManager.launch()`
   里初始化了 sharedSidebarViewModel，但某些 session 操作可能在此之前触发。

5. **子窗口渲染** —— borderless 子窗口用 `styleMask = []`，
   某些 Ghostty 功能可能依赖窗口具有特定 styleMask。

---

## 代码映射

| 功能 | 文件 | 关键代码 |
|------|------|----------|
| 主窗口创建 | `KanbanWindowManager.swift` | `launch(ghostty:)` |
| 主窗口内容布局 | `KanbanWindowManager.swift` | `_KanbanRootView` |
| 自定义 tab bar | `KanbanWindowManager.swift` | `_KanbanTabBar` |
| SideBar 唯一实例 | `KanbanWindowManager.swift:153` | `SidePanelView(...)` |
| 子窗口管理 | `KanbanWindowManager.swift` | `configureChildWindow()`, `positionChildWindows()` |
| Terminal-only 布局 | `TerminalController.swift` | `windowDidLoad` → `TerminalView(...)` |
| 旧的 pass-through | `TerminalController.swift` | `KanbanSidebarContainer`（空壳） |
| BoardState 单例 | `KanbanBoardState.swift` | `static let shared = BoardState()` |
| 性能优化 | `SessionFileWatcher.swift` | 增量 JSONL 解析、mtime 跟踪、路径缓存 |
