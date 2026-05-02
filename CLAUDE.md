# 行为准则

1. 每当我提新功能/修改点，先用准确易懂的语言复述并找我确认；周全思考，提醒我未考虑的细节。
2. 我是一个毫无编程经验的产品经理，请用简单、清晰、有逻辑的语言表达。
3. 任务稍微复杂就委派子 Agent；复杂度更高则拆成多个子 Agent 串行/并行，你作为协调者规划和统筹。

# Ghostty Demo

Ghostty 终端的演示应用，集成了看板功能用于管理 Claude Code 会话。

## 项目结构

```
ghostty-kanban/
├── demo/                          # Ghostty Demo 应用（主要）
│   ├── Sources/
│   │   ├── GhosttyDemo/           # 全部 SwiftUI 源码
│   │   └── GhosttyRuntime/        # Ghostty Swift 运行时
│   ├── Package.swift              # SPM 包定义
│   └── run.sh                     # 编译 → 打包 .app → 启动
└── docs/
    ├── kanban-migration-plan.md   # 看板功能详细设计
    └── session-management-plan.md # 会话管理设计
```

## 核心功能

**终端演示**
- Ghostty 终端渲染（GhosttySurfaceView）
- 多标签页管理（TerminalTabManager）
- 终端文本输入与命令发送

**看板管理**
- Todo / In Progress / Review / Done 四列
- 拖拽管理任务
- 亮/暗主题

**Claude 会话集成**
- 关联 Claude Code 会话与 Ghostty 标签页
- JSONL 会话状态实时监控（running/idle/needInput）
- 会话创建、恢复、删除

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
