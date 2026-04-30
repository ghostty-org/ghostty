# Ghostty Kanban

Ghostty 终端的看板，管理 Claude Code 会话。

## 核心功能
- Todo / In Progress / Review / Done 四列
- Claude Code 会话关联 Ghostty 标签页
- 拖拽管理任务
- 亮/暗主题

## 架构

**纯 SwiftUI 原生架构**（非 WKWebView），位于 `demo/` 目录。

关键文件：
- `demo/Sources/GhosttyDemo/` — 全部 Swift 源码（10 个 UI/逻辑文件）
- `demo/Package.swift` — SPM 包定义
- `demo/run.sh` — 编译 → 打包 .app → 启动

## 数据模型

```swift
KanbanTask: id, title, description, priority(P0-P3), status, sessions, isExpanded
Session: id, title, status(running/idle/needInput), timestamp, isWorkTree, branch, tabID
```

## 关键设计

- **tabID: UUID?** 替代 surfaceId: UInt64?（TerminalTabManager 集成）
- **直接方法调用** 替代 NotificationCenter 间接通信
- **GCD DispatchSource** 替代 FSEvents（更轻量）
- **@Published** 自动绑定替代 JS 注入

## 存储

| 数据 | 位置 |
|------|------|
| 任务 | `~/Library/Application Support/KanbanBoard/tasks.json` |
| Claude 会话 | `~/.claude/projects/*/*.jsonl`（只读）|

## 构建

```bash
# 编译 + 打包 .app + 启动（推荐）
bash demo/run.sh

# 仅编译
cd demo && swift build
```

`run.sh` 生成 `demo/GhosttyDemo.app`，自动杀死旧进程并启动新版。

## 开发

**重要：每次修改 Swift 代码后必须重新打包 app！**
- 运行 `bash demo/run.sh` 即可完成编译 → 打包 → 替换旧 app → 启动
- 调试：Safari Web Inspector 不可用（纯 SwiftUI，非 WKWebView）
- 主题颜色在 `KanbanTheme.swift` 中调整

## 已知问题

- JSONL 监控依赖 `~/.claude/projects/` 目录存在
- 首次启动会创建示例任务数据
- 拖拽使用 `.draggable()`/`.dropDestination()` API

## 路线图

- [ ] Ghostty C API 集成
- [ ] Git worktree 创建
- [ ] 多项目支持
