# 看板标签功能 — 实施计划

日期: 2026-05-01
来源设计: docs/superpowers/specs/2026-05-01-tag-feature-design.md

## 任务

### 任务 1：Tag 枚举 + KanbanTask 模型变更

**文件**: `KanbanModels.swift`
**变更**:
1. 新增 `Tag` 枚举，继承 `String, Codable, CaseIterable, Identifiable`，8 个 case:
   `bug, feat, docs, refac, test, ui, sec, perf`
2. 添加 `var displayName: String` 计算属性
3. `KanbanTask` 新增 `var tags: [Tag] = []` 字段
4. 更新 `KanbanTask.init` 以兼容新增字段（默认为 `[]`）

### 任务 2：主题标签颜色

**文件**: `KanbanTheme.swift`
**变更**:
1. `ThemeColors` 结构体新增 8 个 `tagXxx: Color` 属性（如 `tagBug`, `tagFeat` 等）
2. Light theme 使用浅色值
3. Dark theme 使用暗色值
4. 更新 `static func colors(isDark:)` 双分支初始化

颜色对照表：

| 标签 | Light 模式 | Dark 模式 |
|------|-----------|-----------|
| Bug  | #FFECEC | #4A2A2A |
| Feat | #E8F8E8 | #2A4A2A |
| Docs | #E8F0FF | #2A3A4A |
| Refac | #F2E8F8 | #3A2A4A |
| Test | #FFF8D6 | #4A3A1A |
| UI   | #FFF0D6 | #4A3A1A |
| Sec  | #F0F0F2 | #3A3A3A |
| Perf | #E8FAFA | #2A4A4A |

### 任务 3：卡片标签渲染

**文件**: `TaskCardView.swift`
**变更**:
1. 在卡片底部区域（`card-footer`）的 `PriorityBadge` 之后、`session` 计数之前插入标签行
2. 使用 `Tag` 的 `displayName` 显示标签文本
3. 标签使用 `ForEach(task.tags)` 循环渲染
4. 每个标签显示为带背景色的圆角小方块，颜色来自 `colors.tagXxx`
5. 标签文字色 #444（亮色）/ #CCC（暗色）
6. 标签自动换行布局
7. 空 `tags` 数组时跳过渲染

**注意**: 标签的 `Environment` 主题色需要从 `@Environment(\.themeColors) var colors` 获取。

### 任务 4：弹窗标签选择器

**文件**: `KanbanModals.swift`
**变更**:
1. `TaskEditModal` 新增 `@State var selectedTags: [Tag]`
2. `init` 中从 `task?.tags ?? []` 初始化
3. 标题下方的标签选择区域：8 个可点击标签，已选高亮
4. "Save" 时将 `selectedTags` 传递给 `KanbanTask`
5. 更新 `KanbanTask` 构造：tags 参数传入

## 依赖关系

任务 1 → 任务 3、4（数据模型先定义）
任务 2 → 任务 3（主题色先定义）
任务 1、2 可并行

## 提交

单个 commit 包含所有变更，message 格式：`feat: 看板标签功能 - Tag 枚举、卡片渲染、弹窗选择器`
