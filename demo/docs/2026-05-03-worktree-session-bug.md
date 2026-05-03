# Bug: Worktree Session 无法关联

## 问题描述

用户点击 "Create worktree" 创建 session 后，session 始终无法与 Claude JSONL 文件关联。表现为：
- session 一直显示 "New Session" 标题
- status 停留在 "running"
- 用户关闭 tab 后，session 被删除（因为 `sessionId` 仍为 nil，触发 `unlinkTab` 删除逻辑）

## 根因

**问题一（已修复）**：代码只监控 workspace 特定子目录，漏掉了 worktree session。

Claude Code 的 session 存储结构：

```
~/.claude/projects/
├── -Users-hue-Desktop-git1/                    ← main session 位置
│   └── <sessionId>.jsonl
├── -Users-hue-Desktop-git1--claude-worktrees-xxx/ ← worktree session 位置
│   └── <sessionId>.jsonl
├── -Users-hue-Documents-ghostty-kanban/
│   └── <sessionId>.jsonl
...
```

原代码（ContentView.swift）根据 workspace 路径计算监控目录：

```swift
let encoded = ws.replacingOccurrences(of: "/", with: "-")
    .replacingOccurrences(of: ".", with: "-")
    ...
watchPath = claudeProjects + "/" + encoded  // 只监控一个目录
```

- 配置 workspace = `/Users/hue/Desktop/git1` → 只监控 `.../-Users-hue-Desktop-git1/`
- worktree session 在 `.../-Users-hue-Desktop-git1--claude-worktrees-xxx/` 子目录
- **子目录不在父目录的 `open(O_EVTONLY)` 监控范围内** → 漏报

**问题二（已修复）**：`isWorkTree` 匹配过滤过严 + `applyParsed` 覆盖本地值。

- `matchNewSessionId` 要求 `pendingSessionQueue.isWorkTree == parsed.isWorkTree`
- 但 JSONL 首次扫描时 `worktree-state` 事件尚未写入 → `parsed.isWorkTree = false`
- `isWorkTree: true` 的 pending entry 永远匹配不上

## 解决方案

### 修复 1：监控根目录

改动：`ContentView.swift` - 改为监控 `~/.claude/projects/` 根目录

```swift
// Before: watchPath = claudeProjects + "/" + encoded
// After:  watchPath = claudeProjects (root, recursive scan)
let watchPath = claudeProjects
```

`JsonlWatcher` 本身的 `enumerateJsonlFiles()` 会递归扫描子目录，自然同时抓到 main 和 worktree session。

### 修复 2：保护本地 `isWorkTree`（Plan D）

改动：`KanbanModels.swift`、`SessionManager.swift`、`KanbanBoardState.swift`

1. `Session` 模型加 `isWorkTreeOverridden: Bool` 字段
2. `createSession` 时 `isWorkTreeOverridden = worktree`（用户明确指定的标记）
3. `applyParsed` 和 `updateSessionFromParsed` 中加 guard：`if !session.isWorkTreeOverridden` 才更新 `isWorkTree`

这样本地用户指定的 `isWorkTree` 是 source of truth，JSONL 的值无法覆盖。

### 修复 3：FIFO Fallback（已在之前修复）

`matchNewSessionId` 在找不到 `isWorkTree` 精确匹配时，fallback 到 FIFO 取队列第一个。防止 `worktree-state` 事件未写入时关联失败。

## 修改文件

| 文件 | 改动 |
|------|------|
| `ContentView.swift` | 监控根目录 `~/.claude/projects/` |
| `KanbanModels.swift` | `Session` 加 `isWorkTreeOverridden` 字段 |
| `SessionManager.swift` | `createSession` 设置 `isWorkTreeOverridden`；`applyParsed` 加 guard |
| `KanbanBoardState.swift` | `updateSessionFromParsed` 加 guard；`.workspacePathDidChange` 通知 |

## 验证方法

1. 配置 workspace 为任意目录
2. 新建 main session → 确认关联（标题变为会话首句，status 更新）
3. 新建 worktree session → 确认关联（标题变为会话首句，status 更新，"worktree" 标签保留）
4. 关 tab → session 保留（不是删除），可 resume
