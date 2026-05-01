# 看板标签功能设计

日期: 2026-05-01
状态: 已批准

## 概要

为 Ghostty Kanban 看板的每个任务添加标签（Tag）功能，支持在创建和编辑任务时设置/更改标签。标签用于标记任务类型（bug/feature/docs 等），以低饱和度颜色区分，不做筛选功能。

## 标签列表

共 8 个固定标签，不可自定义：

| 标签 | 命名 | 颜色（亮色模式） | 颜色值 |
|------|------|-------------------|--------|
| Bug | `Bug` | 浅粉 | #FFECEC |
| Feature | `Feat` | 浅绿 | #E8F8E8 |
| Documentation | `Docs` | 浅蓝 | #E8F0FF |
| Refactor | `Refac` | 浅紫 | #F2E8F8 |
| Test | `Test` | 浅黄 | #FFF8D6 |
| UI | `UI` | 浅橙 | #FFF0D6 |
| Security | `Sec` | 浅灰 | #F0F0F2 |
| Performance | `Perf` | 浅青 | #E8FAFA |

文字颜色统一使用 #444，字体 10px 粗体 500，padding 2px 7px，圆角 4px。

## 数据模型

`KanbanTask` 新增 `tags: [Tag]` 字段：

```swift
enum Tag: String, Codable, CaseIterable, Identifiable {
    case bug, feat, docs, refac, test, ui, sec, perf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bug:   return "Bug"
        case .feat:  return "Feat"
        case .docs:  return "Docs"
        case .refac: return "Refac"
        case .test:  return "Test"
        case .ui:    return "UI"
        case .sec:   return "Sec"
        case .perf:  return "Perf"
        }
    }
}
```

```swift
struct KanbanTask: Identifiable, Codable, Equatable {
    // 现有字段不变
    var id: UUID
    var title: String
    var description: String
    var priority: Priority
    var status: Status
    var sessions: [Session]
    var isExpanded: Bool

    // 新增字段
    var tags: [Tag] = []
}
```

已有任务的 `tags` 为空数组 `[]`，向下兼容。

## 卡片 UI

### 标签位置

在卡片底部区域，顺序为：
```
P0/P1/P2 优先级标签 → 标签（flex 自动换行） → 终端图标（靠右对齐）
```

### 暗色模式

暗色模式使用与亮色模式相同的色相，做调暗处理以适配深色背景（卡片底色 #333）：

| 标签 | 颜色值 |
|------|--------|
| Bug | #4A2A2A |
| Feat | #2A4A2A |
| Docs | #2A3A4A |
| Refac | #3A2A4A |
| Test | #4A3A1A |
| UI | #4A3A1A |
| Sec | #3A3A3A |
| Perf | #2A4A4A |

文字颜色统一使用 #CCC。

## 交互

### 新建任务

TaskEditModal 中新增标签选择区，显示 8 个可选标签（可多选）。

### 编辑任务

双击卡片打开 TaskEditModal，标签区显示当前已选标签，可以随时添加/移除。

### 不支持

- 不按标签筛选
- 不自定义标签
- 不标签搜索
- 不拖拽标签

## 文件变更

| 文件 | 变更 |
|------|------|
| `KanbanModels.swift` | 新增 `Tag` 枚举，`KanbanTask` 加 `tags` 字段 |
| `KanbanTheme.swift` | 新增 `tagTag: Color` 等 8 个暗色/亮色主题色用于暗色模式 |
| `TaskCardView.swift` | 卡片底部添加标签渲染 |
| `KanbanModals.swift` | 创建/编辑弹窗添加标签选择器 |

## 后续工作（不在本次范围内）

- 标签筛选
- 自定义标签
- 标签统计
