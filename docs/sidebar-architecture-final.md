# Ghostty Kanban 最终架构文档

> 基于自定义单窗口 + borderless 子窗口方案，
> sidebar 与 tab bar 位于同一层级。

---

## 1. 总体布局

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#ff6b6b', 'secondaryColor': '#4ecdc4'}}}%%
flowchart TD
    subgraph MainWindow["KanbanWindowManager 主窗口 (NSWindow)"]
        Titlebar["透明标题栏区域<br/>titlebarAppearsTransparent = true<br/>titleVisibility = .hidden<br/>含原生 traffic lights ●●●"]
        
        subgraph ContentArea["内容区 (NSHostingView → _KanbanRootView)"]
            direction LR
            subgraph SidebarArea["侧边栏区域"]
                Sidebar["SidePanelView<br/>width: 85px (可拖动 60~50%)"]
                DragHandle["拖拽手柄<br/>width: 6px"]
            end
            
            subgraph RightArea["右侧区域"]
                TabBar["自定义 Tab Bar<br/>height: 28px<br/>_KanbanTabBar"]
                TerminalPlaceholder["终端占位区 (透明 Rectangle)<br/>点击穿透到子窗口"]
            end
        end
    end
    
    subgraph ChildWindows["子窗口 (每个 Tab 一个)"]
        Child1["Tab 1: TerminalController.window<br/>styleMask = [] (borderless)<br/>hasShadow = false<br/>tabbingMode = .disallowed"]
        Child2["Tab 2: TerminalController.window<br/>(同上)"]
        ChildN["Tab N: ..."]
    end
    
    Titlebar --> ContentArea
    SidebarArea --> Sidebar
    SidebarArea --> DragHandle
    RightArea --> TabBar
    RightArea --> TerminalPlaceholder
    TerminalPlaceholder -. "覆盖" .-> Child1
    TerminalPlaceholder -. "覆盖" .-> Child2
    
    style MainWindow fill:#e8f4f8,stroke:#333,stroke-width:2px
    style Titlebar fill:#f0f0f0,stroke:#999,stroke-dasharray: 5 5
    style ContentArea fill:#fff,stroke:#666
    style Sidebar fill:#ffe0e0,stroke:#c44
    style DragHandle fill:#ddd,stroke:#999
    style TabBar fill:#e0ffe0,stroke:#4a4
    style Child1 fill:#f5f5ff,stroke:#66c
    style Child2 fill:#f5f5ff,stroke:#66c
    style ChildN fill:#f5f5ff,stroke:#66c
```

---

## 2. 窗口层级关系

```mermaid
classDiagram
    class KanbanWindowManager {
        +shared: KanbanWindowManager
        -window: NSWindow
        -tabs: [TabItem]
        -activeIndex: Int
        +launch(ghostty:)
        +newTab(ghostty:)
        +addTab(controller:)
        +selectTab(at:)
        +closeTab(at:)
        +toggleSidebar()
        +positionChildWindows()
        -configureChildWindow()
        -syncTabVisibility()
    }
    
    class _KanbanRootView {
        +manager: KanbanWindowManager
        +sidebarWidth: CGFloat
        +selTabIndex: Int
        +sbVisible: Bool
        <<SwiftUI View>>
    }
    
    class _KanbanTabBar {
        +manager: KanbanWindowManager
        +selTabIndex: Binding~Int~
        <<SwiftUI View>>
    }
    
    class SidePanelView {
        +viewModel: SidePanelViewModel?
        +boardState: BoardState
        <<SwiftUI View>>
    }
    
    class TerminalController {
        +isEmbedded: Bool
        +window: NSWindow?
        +focusedSurface: Ghostty.SurfaceView?
        +surfaceTree: SurfaceTree
        +windowDidLoad()
        <<NSWindowController>>
    }
    
    class TabItem {
        +controller: TerminalController
        +title: String
        +id: UUID
    }
    
    class BoardState {
        +shared: BoardState
        +tasks: [KanbanTask]
        +isDarkMode: Bool
        <<ObservableObject>>
    }
    
    class SessionFileWatcher {
        -lastModificationDates: [String: Date]
        -cachedFilePaths: [String]?
        -parseCache: [String: ParseCache]
        +handleEvents(paths:)
        +parseIncrementalJSONL()
    }
    
    class SessionManager {
        +shared: SessionManager
        +sessions: [Session]
        +createSession()
        +updateSession()
        <<ObservableObject>>
    }

    KanbanWindowManager "1" *-- "many" TabItem : manages
    TabItem "1" --> "1" TerminalController : wraps
    KanbanWindowManager "1" --> "1" _KanbanRootView : content
    _KanbanRootView "1" --> "1" SidePanelView : left side
    _KanbanRootView "1" --> "1" _KanbanTabBar : top right
    SidePanelView --> BoardState : observes shared
    TerminalController --> BoardState : (data only)
    TerminalController --> SessionManager : creates sessions
    SessionFileWatcher --> SessionManager : updates sessions
    
    style KanbanWindowManager fill:#e8f4f8,stroke:#333
    style _KanbanRootView fill:#e8ffe8,stroke:#363
    style SidePanelView fill:#ffe0e0,stroke:#c44
    style TerminalController fill:#f5f5ff,stroke:#66c
    style BoardState fill:#fff3cd,stroke:#cc0
```

---

## 3. 详细尺寸与约束

```mermaid
%%{init: {'theme': 'base'}}%%
flowchart LR
    subgraph Dimensions["窗口尺寸关系"]
        direction TB
        Total("主窗口初始尺寸: 1100 × 700<br/>可自由缩放")
        
        subgraph Layout["布局公式"]
            SW("sidebarWidth<br/>默认 85px<br/>范围 60 ~ 50% 窗口宽度")
            TBH("tabBarHeight<br/>固定 28px")
            TW("terminalWidth = windowWidth - sidebarWidth")
            TH("terminalHeight = windowHeight - tabBarHeight")
        end
        
        SubWindow("子窗口位置: (sidebarWidth, tabBarHeight)<br/>子窗口尺寸: (TW, TH)")
    end
    
    style Total fill:#e8f4f8,stroke:#333,stroke-width:2px
    style Layout fill:#fff,stroke:#666
    style SubWindow fill:#f5f5ff,stroke:#66c
```

**关键约束：**

- `terminalWidth = windowWidth - sidebarWidth`
- `terminalHeight = windowHeight - tabBarHeight`
- 子窗口最小尺寸：`40 × 40`（小于时不更新布局）
- sidebarWidth 持久化到 `UserDefaults.standard(forKey: "kanban_sidebar_width")`
- 拖拽时实时更新子窗口位置（`positionChildWindows()`）

---

## 4. 启动流程

```mermaid
sequenceDiagram
    participant App as AppDelegate
    participant KWM as KanbanWindowManager
    participant W as 主窗口 NSWindow
    participant Root as _KanbanRootView
    participant TC as TerminalController
    participant CW as 子窗口 NSWindow

    App->>KWM: launch(ghostty:)
    KWM->>KWM: 初始化 sharedSidebarViewModel
    KWM->>W: 创建主窗口<br/>styleMask: [titled, closable, ...]
    W->>W: titlebarAppearsTransparent = true
    W->>W: titleVisibility = .hidden
    W->>W: tabbingMode = .disallowed
    KWM->>Root: 创建 NSHostingView(_KanbanRootView)
    Root->>SidePanelView: 左侧
    Root->>_KanbanTabBar: 右上
    KWM->>W: contentView = hosting
    W->>W: makeKeyAndOrderFront
    
    KWM->>TC: TerminalController(ghostty, withBaseConfig: nil)
    TC->>TC: init → 加载 NIB
    TC->>TC: windowDidLoad()
    TC->>TC: 创建 TerminalView(terminal only)
    TC->>CW: 子窗口 (borderless, 不显示)
    
    KWM->>KWM: configureChildWindow(controller)
    KWM->>CW: styleMask = []
    KWM->>CW: tabbingMode = .disallowed
    KWM->>W: addChildWindow(cw, ordered: .above)
    
    KWM->>KWM: addTab(controller)
    KWM->>KWM: syncTabVisibility()
    KWM->>CW: orderFront (第一个 tab 显示)
    KWM->>KWM: positionChildWindows()
```

---

## 5. Tab 切换流程

```mermaid
sequenceDiagram
    participant User as 用户
    participant TabBar as _KanbanTabBar
    participant Root as _KanbanRootView
    participant KWM as KanbanWindowManager
    participant OldCW as 旧子窗口
    participant NewCW as 新子窗口

    User->>TabBar: 点击 Tab 2
    TabBar->>Root: selTabIndex = 1
    Root->>KWM: selectTab(at: 1)
    
    KWM->>KWM: activeIndex = 1
    KWM->>KWM: syncTabVisibility()
    KWM->>OldCW: orderOut (隐藏)
    KWM->>NewCW: orderFront (显示)
    KWM->>KWM: positionChildWindows()
    KWM->>NewCW: setFrame(x, y, w, h)
```

---

## 6. 新建 Tab 流程

```mermaid
sequenceDiagram
    participant User as 用户
    participant TabBar as _KanbanTabBar
    participant KWM as KanbanWindowManager
    participant TC as TerminalController
    participant CW as 新子窗口
    participant MW as 主窗口

    User->>TabBar: 点击 "+"
    TabBar->>KWM: newTab(ghostty:)
    
    KWM->>TC: TerminalController(ghostty, withBaseConfig: nil)
    TC->>TC: windowDidLoad()
    TC->>TC: TerminalView(terminal only)
    
    KWM->>KWM: configureChildWindow(TC)
    KWM->>CW: styleMask = []
    KWM->>MW: addChildWindow(CW, ordered: .above)
    
    KWM->>KWM: addTab(controller: TC)
    KWM->>KWM: tabs.append(...)
    KWM->>KWM: activeIndex = tabs.count - 1
    
    KWM->>KWM: syncTabVisibility()
    KWM->>CW: orderFront
    KWM->>KWM: positionChildWindows()
```

---

## 7. 数据流

```mermaid
flowchart LR
    subgraph UserActions["用户操作"]
        Add["添加任务<br/>(board.html → addTask)"]
        Move["移动任务<br/>(drag → moveTask)"]
        Toggle["切换展开<br/>(click → toggleExpand)"]
        SideAction["侧边栏操作<br/>(themeToggle, addSession, etc.)"]
    end
    
    subgraph JSBridge["JS → Swift Bridge"]
        WK["WKWebView<br/>window.webkit.messageHandlers.kanbanBridge"]
        Coordinator["KanbanWebView.Coordinator<br/>userContentController()"]
    end
    
    subgraph BoardState["数据层"]
        BS["BoardState.shared<br/>@Published var tasks"]
        Save["Persistence.shared.save()<br/>→ ~/.config/ghostty/tasks.json"]
    end
    
    subgraph ViewUpdate["Swift → JS"]
        SendState["sendBoardState()<br/>updateBoardState({ tasks })"]
        DarkMode["setDarkMode()"]
    end
    
    subgraph Session["Session 管理"]
        SM["SessionManager.shared<br/>@Published var sessions"]
        SFW["SessionFileWatcher<br/>(增量 JSONL 解析)"]
        Claude["~/.claude/projects/*.jsonl"]
    end
    
    UserActions --> JSBridge
    JSBridge --> Coordinator
    Coordinator --> BS
    BS --> Save
    BS --> ViewUpdate
    ViewUpdate --> WK
    
    Claude -->|FSEvent| SFW
    SFW -->|mtime + 增量解析| SM
    SM -->|Combine 300ms debounce| BS
    
    style UserActions fill:#ffe0e0,stroke:#c44
    style JSBridge fill:#e0e0ff,stroke:#44c
    style BoardState fill:#fff3cd,stroke:#cc0
    style ViewUpdate fill:#e0ffe0,stroke:#4a4
    style Session fill:#f5f5f5,stroke:#666
```

---

## 8. 性能优化策略

```mermaid
flowchart TD
    subgraph FSEvent["FSEvent 触发"]
        Event["~/.claude/projects/ 文件变化"]
    end
    
    subgraph Optimization["SessionFileWatcher 优化 (3 层)"]
        Layer1["第 1 层: mtime 过滤<br/>只处理修改时间变化的 .jsonl 文件"]
        Layer2["第 2 层: 路径缓存<br/>目录枚举结果缓存 30 秒"]
        Layer3["第 3 层: 增量字节解析<br/>FileHandle.seek(byteOffset)<br/>只解析新增行"]
    end
    
    subgraph Result["结果"]
        Before["改前: 每次事件扫描 1135 个文件 / 548MB"]
        After["改后: 只处理变化的文件 + 只解析新增字节"]
    end
    
    Event --> Optimization
    Optimization --> Result
    
    style Before fill:#ffe0e0,stroke:#c44
    style After fill:#e0ffe0,stroke:#4a4
    style Optimization fill:#e8f4f8,stroke:#333
```

---

## 9. 架构演进决策树

```mermaid
flowchart TD
    Q0["目标: sidebar 与 tab bar 同层 + 跨 tab 共享"] --> Q1{"如何实现?"}
    
    Q1 -->|"不改原生 tab"| A1["Inline + 单例"]
    Q1 -->|"脱离原生 tab"| A2["自定义单窗口 ✅"]
    
    A1 --> Q2{"sidebar 层级"}
    Q2 -->|"内容区 + fullSizeContentView"| A1a["❌ tab bar 永远在上面"]
    Q2 -->|"浮层面板"| A1b["❌ 两个独立窗口"]
    Q2 -->|"Theme Frame Overlay"| A1c["❌ 覆盖 terminal"]
    Q2 -->|"Titlebar Accessory"| A1d["❌ 被裁剪"]
    
    A2 --> Q3{"如何托管 terminal"}
    Q3 -->|"子窗口 borderless"| Final["✅ 最终方案"]
    Q3 -->|"reparent SurfaceView"| Abandoned["❌ 过于复杂"]
    
    style Final fill:#e0ffe0,stroke:#4a4,stroke-width:2px
    style A1a fill:#ffe0e0,stroke:#c44
    style A1b fill:#ffe0e0,stroke:#c44
    style A1c fill:#ffe0e0,stroke:#c44
    style A1d fill:#ffe0e0,stroke:#c44
    style Abandoned fill:#fff3cd,stroke:#cc0
    style Q0 fill:#e8f4f8,stroke:#333
```

---

## 10. 文件清单

| 文件 | 作用 | 关键类/结构 |
|------|------|-------------|
| `SidePanel/KanbanWindowManager.swift` | 主窗口 + tab 管理器 | `KanbanWindowManager`, `_KanbanRootView`, `_KanbanTabBar` |
| `SidePanel/SidePanelView.swift` | Sidebar SwiftUI 视图 | `SidePanelView` |
| `SidePanel/KanbanWebView.swift` | JS ↔ Swift 桥接 | `KanbanWebView.Coordinator` |
| `SidePanel/KanbanBoardState.swift` | 任务数据单例 | `BoardState.shared` |
| `SidePanel/KanbanModels.swift` | 数据模型 | `KanbanTask`, `Session` |
| `SidePanel/SessionManager.swift` | Session 管理单例 | `SessionManager.shared` |
| `SidePanel/SessionFileWatcher.swift` | JSONL 文件监听 + 增量解析 | `SessionFileWatcher` |
| `SidePanel/SidePanelViewModel.swift` | Terminal 桥接 | `SidePanelViewModel` |
| `SidePanel/Persistence.swift` | JSON 持久化 | `Persistence.shared` |
| `Features/Terminal/TerminalController.swift` | Terminal 控制器 | `TerminalController`, `KanbanSidebarContainer` |
| `Features/Terminal/TerminalView.swift` | Terminal SwiftUI 视图 | `TerminalView` |
| `Features/Terminal/TerminalViewContainer.swift` | Terminal NSView 容器 | `TerminalViewContainer` |
| `App/macOS/AppDelegate.swift` | App 入口 | `AppDelegate` |

---

> 最后更新: 2026-04-29
> 对应 commit: `0b0b53486`
