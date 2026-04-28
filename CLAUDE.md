# Ghostty Kanban

Ghostty 终端的侧边栏看板，管理 Claude Code 会话。

## 核心功能
- Todo / In Progress / Review / Done 四列
- Claude Code 会话关联 Ghostty 分屏
- 拖拽管理任务
- 亮/暗主题

## 架构

**混合架构**：Web UI (HTML/CSS/JS) + Swift 原生逻辑

- UI 层：`macos/Resources/Kanban/board.html`（WKWebView 加载）
- 桥接层：`KanbanWebView.swift`（JS ↔ Swift 消息传递）
- 数据层：`BoardState.swift`、`KanbanModels.swift`

## 数据模型

```swift
KanbanTask: id, title, description, priority(P0-P3), status, sessions, isExpanded
Session: id, title, status(running/idle/needInput), timestamp, isWorkTree, branch
```

## 消息桥接

JS → Swift：`window.webkit.messageHandlers.kanbanBridge`
- `themeToggle`, `addTask`, `updateTask`, `moveTask`, `toggleExpand`, `addSession`, `removeSession`

Swift → JS：
- `updateBoardState({ tasks: [...] })`
- `setDarkMode(true)`
- `updateLayout(width, isNarrow)`

## 存储

| 数据 | 位置 |
|------|------|
| 任务 | `~/.config/ghostty/tasks.json` |
| 会话映射 | `.ghostty/sessions.json` |
| Claude 会话 | `~/.claude/projects/*/*.jsonl`（只读）|

## 构建

```bash
# Xcode（修改 Swift 代码后需要重新构建）
cd macos && xcodebuild -scheme Ghostty -configuration Debug build

# Zig
zig build && zig build test
```

## 开发

- **构建后启动**：构建完成后自动关闭旧进程并启动新版本 app，无需用户操作
- **UI 修改**：直接编辑 `macos/Resources/Kanban/board.html`，无需重新编译
- **调试**：Safari Web Inspector 可用；BoardState 变更自动同步到 WebView
- **Lint**：`swiftlint lint --strict`

## 已知问题 / 经验

- **WKWebView 中 `confirm()`/`alert()`/`prompt()` 不会弹出**：需要实现 `WKUIDelegate` 处理 JS 对话框，否则调用被静默忽略。使用自定义 HTML 对话框更可靠。

## 路线图

- [ ] Ghostty C API 集成
- [ ] 实时会话状态监控
- [ ] Git worktree 创建
- [ ] 会话继续/恢复
- [ ] 多项目支持

