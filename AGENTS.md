# Ghostty Demo — Agent 开发指南

本项目是 **Ghostty Demo**，用于演示 Ghostty 终端的核心能力。Kanban 看板是集成的功能模块，不是独立项目。

## 技术栈

- **纯 SwiftUI 原生架构**（非 WKWebView）
- **Ghostty Swift Runtime**：通过侵入式方案完全掌控 Ghostty Swift 源码
- **SPM 包管理**

## 源码位置

所有源码位于 `demo/Sources/GhosttyDemo/`：

| 文件 | 职责 |
|------|------|
| `KanbanModels.swift` | 数据模型 |
| `KanbanPersistence.swift` | JSON 持久化 |
| `KanbanBoardState.swift` | 任务状态管理 |
| `SessionManager.swift` | 会话生命周期管理 |
| `JsonlWatcher.swift` | JSONL 增量解析 + 状态检测 |
| `KanbanTheme.swift` | 亮/暗主题 |
| `KanbanView.swift` | 主看板视图 |
| `ColumnView.swift` | 单列视图 |
| `TaskCardView.swift` | 任务卡片 |
| `KanbanModals.swift` | 弹窗 |
| `TerminalTabManager.swift` | 标签页管理 |
| `ContentView.swift` | 主布局 |
| `DemoApp.swift` | 应用入口 |

## 关键设计决策

| 决策 | 选择 |
|------|------|
| UI 框架 | SwiftUI 原生（非 WKWebView）|
| 通信 | 直接方法调用（非 NotificationCenter）|
| 会话 → 标签页 | `tabID: UUID`（非 `surfaceId: UInt64`）|
| 文件监控 | GCD DispatchSource（非 FSEvents/Carbon）|
| 终端控制 | `sendText()`/`sendEnter()` |
| 命令模式 | `--permission-mode bypassPermissions` |

## 构建命令

```bash
# 编译 + 打包 .app + 启动
bash demo/run.sh
```

## 重要约束

- 纯 SwiftUI，无 Web Inspector 可用
- 修改代码后必须重新打包 app
- JSONL 监控依赖 `~/.claude/projects/` 目录存在
