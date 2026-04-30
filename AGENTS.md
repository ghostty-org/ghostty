# Ghostty Kanban

Ghostty 终端的看板，管理 Claude Code 会话。

## 核心功能
- Todo / In Progress / Review / Done 四列
- Claude Code 会话关联 Ghostty 标签页
- 拖拽管理任务
- 亮/暗主题
- JSONL 会话状态实时监控（running/idle/needInput）

## 架构

**纯 SwiftUI 架构**：`demo/` 目录下独立包

```
ContentView (HSplitView)
├── KanbanView (左面板, 240-600px)
│   ├── KanbanToolbar (标题 + 新建 + 主题切换)
│   ├── GeometryReader (自适应横排/纵排 @ 360px)
│   └── Status columns × 4
│       ├── ColumnView (标题 + 任务列表 + 拖拽接收)
│       └── TaskCardView (优先级色条 + 展开/折叠 + 拖拽源)
│           └── SessionPanelView (展开时显示 session 列表)
├── TabBarView (标签栏)
├── ZStack (终端区域)
└── 状态栏
```

## 数据流

```
用户操作 → BoardState (@Published) → View 自动刷新
              ↓
           Persistence (tasks.json ~/Library/Application Support/)
              ↓
           SessionManager (标签页 ↔ 会话关联)
              ↓
           JsonlWatcher (GCD ~/.claude/projects/*.jsonl)
```

## 关键设计决策

| 决策 | 选择 |
|------|------|
| UI 框架 | SwiftUI 原生（非 WKWebView）|
| 通信 | 直接方法调用（非 NotificationCenter）|
| 会话 → 标签页 | `tabID: UUID?`（非 `surfaceId: UInt64?`）|
| 文件监控 | GCD DispatchSource（非 FSEvents/Carbon）|
| 终端控制 | `sendText()`/`sendEnter()` |
| 命令模式 | `--permission-mode bypassPermissions` |

## 存储

| 数据 | 位置 |
|------|------|
| 任务 | `~/Library/Application Support/KanbanBoard/tasks.json` |
| Claude 会话 | `~/.claude/projects/*/*.jsonl`（只读） |

## 文件清单 (`demo/Sources/GhosttyDemo/`)

| 文件 | 职责 |
|------|------|
| `KanbanModels.swift` | Priority, Status, SessionStatus, Session, KanbanTask |
| `KanbanPersistence.swift` | JSON 持久化 + 示例数据 |
| `KanbanBoardState.swift` | 任务 CRUD + 主题管理 |
| `SessionManager.swift` | 会话生命周期 + 标签页管理 |
| `JsonlWatcher.swift` | JSONL 增量解析 + 状态检测 |
| `KanbanTheme.swift` | 亮/暗主题 + Environment 注入 |
| `KanbanView.swift` | 主看板 + 自适应布局 |
| `ColumnView.swift` | 单列 + 拖拽接收 |
| `TaskCardView.swift` | 任务卡片 + Session 面板 |
| `KanbanModals.swift` | 编辑/创建弹窗 |

## 构建与运行

```bash
# 编译 + 打包 .app + 启动
bash demo/run.sh

# 或仅编译
cd demo && swift build
```

`run.sh` 会：
1. 杀死旧进程
2. `swift build`
3. 在 `demo/` 根目录生成 `GhosttyDemo.app`
4. 签名并打开

## 自适应布局

| 看板宽度 | 布局 |
|----------|------|
| ≥ 360px | HStack 四列横排，每列独立 ScrollView |
| < 360px | ScrollView VStack 纵排，整体滚动 |

## 主题

28 色亮/暗主题，通过 `EnvironmentValues.themeColors` 注入。
偏好持久化到 `UserDefaults.standard("kanban-dark-mode")`。

## 路线图

- [ ] Ghostty C API 集成
- [ ] 实时会话状态监控 ✓
- [ ] Git worktree 创建
- [ ] 会话继续/恢复 ✓
- [ ] 多项目支持
