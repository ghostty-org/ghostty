# Drag-and-Drop 实现记录

## 架构

Kanban 看板的拖拽功能完全基于 SwiftUI 原生 API 实现：

- **`DragGesture`** — 在 `TaskCardView` 上识别拖拽手势
- **`DragDropState`** — 全局拖拽状态管理器（`ObservableObject`）
- **拖拽幽灵（Ghost）** — 在 `KanbanView` 的 ZStack 中叠加渲染的半透明卡片副本
- **PreferenceKey** — `ColumnFramesKey` 和 `CardFramesKey` 用于收集列和卡片的布局坐标

## 拖拽流程

1. **开始拖拽**：`TaskCardView` 的 `DragGesture` 触发 `.onChanged`，首次触发时调用 `dragState.start(task:cardFrame:)` 记录卡片原始位置和尺寸
2. **拖拽中**：每次手势更新调用 `dragState.updateGhostPosition(at: value.location)`，将幽灵卡片居中于鼠标位置
3. **命中检测**：`updateTargetHitTest()` 用幽灵中心坐标逐列检测（带 `dx: -15, dy: -5` 容差），并在目标列内确定插入索引
4. **拖拽结束**：手势 `.onEnded` 触发 `dragState.endDrag()`，`KanbanView` 监听 `isDragging` 变化执行 `executeDrop()`

## 踩坑记录

### 问题 1：幽灵卡片中心未对齐鼠标

**现象**：拖动时幽灵卡片的中心点与鼠标光标有偏移。

**原因**：初始实现用 `cardOrigin + translation` 定位幽灵左上角，但光标位置是 `startLocation + translation`。只有抓取点在卡片正中心时才对齐。

**修复**：改用 `updateGhostPosition(at location:)`，直接将幽灵居中于鼠标坐标：
```swift
ghostRect.origin = CGPoint(
    x: location.x - ghostRect.width / 2,
    y: location.y - ghostRect.height / 2
)
```

### 问题 2：幽灵卡片内容水平居中而非顶左

**现象**：幽灵卡片的 title 跑到中间，左边空出一块。

**原因**：VStack 默认 `.center` 对齐，加上 `.frame(width:)` 固定宽度后，内部的 HStack 在整个宽框中被居中。

**尝试过的方案**：
- `VStack(alignment: .leading, ...)` — 在某些布局上下文中无效
- 用 `.position()` 替代 `.offset()` — `.position()` 可能干扰子视图布局
- `.overlay(alignment: .topLeading)` + `.offset()` — 位置和内容都无法同时正确

**最终方案**：在 HStack 末尾加 `Spacer(minLength: 0)`，利用 HStack 的默认从前往后排列特性，将所有内容推到左侧。

### 问题 3：幽灵被拉伸变形

**现象**：幽灵卡片变得超高。

**原因**：去掉了 `.fixedSize(horizontal: false, vertical: true)` 和 `.frame(width:)`，导致幽灵在 ZStack 中自由拉伸。

**修复**：保留这两个修饰器以固定尺寸。

### 关键教训

1. **不要用 `.position()` 做定位**：它的提案机制可能干扰子视图布局。用 ZStack 中的正常布局加上 `.offset()` 或直接居中计算更可控。
2. **内容对齐用 Spacer，不用 VStack alignment**：`Spacer(minLength: 0)` 在 HStack 末尾是强制顶左的最可靠方式。
3. **幽灵跟踪鼠标直接用 location，不要用 translation**：`value.location` 是绝对坐标，`value.translation` 需要额外计算偏移量。
4. **一次只改一件事**：同时改定位逻辑和布局修饰器会导致难以排查的复合问题。

## 关键代码

### DragDropState.swift

```swift
func start(task: KanbanTask, cardFrame: CGRect) {
    draggedTask = task
    isDragging = true
    sourceStatus = task.status
    targetStatus = task.status
    cardOrigin = cardFrame.origin
    ghostRect = cardFrame
    updateTargetHitTest()
}

func updateGhostPosition(at location: CGPoint) {
    ghostRect.origin = CGPoint(
        x: location.x - ghostRect.width / 2,
        y: location.y - ghostRect.height / 2
    )
    updateTargetHitTest()
}
```

### dragGhostView 核心结构

```swift
VStack(spacing: 0) {
    HStack(alignment: .top, spacing: 0) {
        Rectangle().fill(priorityColor).frame(width: 4)
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)...
            // 描述、优先级、会话数
        }
        .padding(8)
        Spacer(minLength: 0)  // ← 关键：强制顶左对齐
    }
}
.fixedSize(horizontal: false, vertical: true)
.frame(width: dragState.ghostRect.width)
.background(...)
.cornerRadius(8)
.shadow(...)
.position(x: ghostRect.midX, y: ghostRect.midY)
```

### 手势绑定（TaskCardView）

```swift
.highPriorityGesture(
    DragGesture(minimumDistance: 5, coordinateSpace: .named("board"))
        .onChanged { value in
            guard cardFrame != .zero else { return }
            if !dragState.isDragging {
                dragState.start(task: task, cardFrame: cardFrame)
            }
            dragState.updateGhostPosition(at: value.location)
        }
        .onEnded { _ in
            dragState.endDrag()
        }
)
```
