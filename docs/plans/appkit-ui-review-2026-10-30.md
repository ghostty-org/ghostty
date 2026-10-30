# OMG AppKit UI 替换范围审查 — 2026-10-30

范围：当前 checkout 的 macOS UI，排除已单独讨论的 workspace 与 terminal tab bar 实现。只做源码架构审查，未修改产品代码、未运行性能基准或 UI 回归；文中候选表示收益判断，不等于已经复现缺陷。另一 worktree 的 tab AppKit 实现未纳入本次代码事实。

## 裁决

不做全量 SwiftUI→AppKit 翻译。优先让 AppKit 拥有窗口内容容器、几何、first responder、选中项与 presentation 生命周期；SwiftUI 可以继续渲染不拥有这些职责的静态叶子页面。高频/大数据列表使用原生复用组件。保留现有 Ghostty host、Surface/PTY、编辑器文本引擎和各服务模型。

## 优先替换表

| 优先级 | 区域与证据 | 推荐目标 | 收益、约束 |
| --- | --- | --- | --- |
| A1 | TerminalShellLayoutContainer，RightInspectorHost.swift:462；SwiftUI GeometryReader/HStack 同时控制左右栏和底部 dock | fork-owned NSViewController，外层 NSSplitViewController/NSSplitView 或明确约束的 NSView 容器 | 唯一布局提交边界，主内容与 accessories 不因 body 重算重挂；与 workspace 固定窗口方案及另一个 tab worktree 必须统一设计，不能并行双写 |
| A2 | AgentQuickInputDock，AgentQuickInput.swift:794；透明高度占位+overlay，焦点交由另一个 representable | 原生 dock controller、Auto Layout 高度约束、现有 ComposerTextView/NSScrollView；队列可用 NSCollectionView 或小规模 NSStackView | 减少焦点/几何时序；不重写 drafts/queue/history/SSH桥；不要承诺 AppKit 自动解决 PTY reflow，仍需一个明确 resize commit |
| A3 | RightInspectorHost.swift:604；onAppear/onDisappear/onChange/onReceive 多入口发布 provider 生命周期；InspectorPaneDeck.swift:6 已原生缓存 hosting views | 原生 InspectorHostController，以明确 pane/context/visibility 状态驱动 child controller；扩展现有 deck | 消除 lifecycle 依赖 SwiftUI view identity，复用已有 Git/history 原生内容；不让插件拿 NSView/NSWindow，typed snapshot/action 契约保持 |
| B1 | InspectorFileTreeView/NodeView，RightInspectorHost.swift:2035/2065；顶层 LazyVStack，展开子树递归普通 VStack，button+double tap+context menu | NSOutlineView+NSTreeController（可选）/自有 data source，增量更新 | 原生树键盘导航、selection、右键、rename、行复用；保留异步 SSH 文件服务、compact folder、symlink规则；不把文件 I/O 放主线程 |
| B2 | QuickInputHistoryView.swift:27、125；native search editor+SwiftUI list+手动scrollTo | NSPopover/NSViewController + NSTableView + 现有 native IME input | 统一输入、上下键、hover与scroll；保留history model和插入策略，不能丢首字符/marked text |
| B3 | InspectorAgentHistoryView，RightInspectorHost.swift:904/1129；分组列表、分页、搜索、filter popover | 会话列表 NSTableView，层级分组可用 NSOutlineView；原生 filter presenter | 搜索后保持selection/scroll，避免分组分支创建大量行；正文 AgentHistoryTranscriptTable 已NSTableView，不重写；扫描/搜索性能需独立测量 |
| B4 | CommandPalette.swift:186/251；零尺寸Button拦截方向键，FocusState与下一轮focus，普通VStack列表；TerminalCommandPalette有responder injector | 窗口内AppKit overlay controller或明确归属NSPanel，NSSearchField/NSTableView | 统一IME、Escape、Return、键盘路由；优先窗口内overlay以减少全屏辅助窗口问题；保留匹配排序/命令表 |
| B5 | GitDiffReviewView.swift:39；LazyVStack每行Text、双列行高、折叠、按行textSelection | 单一只读原生diff document view + NSScrollView，或NSTableView复用；选择必须是跨行语义 | 大diff横纵滚动/长行/跨行复制更可控；不要误以为两列NSTextView天然对齐；保留diff算法、hunk/行锚点和syntax模型，先基准再选实现 |
| B6 | EditorWorkspaceHost.swift:31/91/519；terminal opacity与editor isHidden，保留所有文档host，反复清sizingOptions | PaneContentController+DocumentDeckController，原生document tab chrome；现有编辑器controller稳定挂载 | 生命周期/Undo/选区/预览切换更明确；不重写文本引擎，不用NSDocument强套SSH异步保存；与主shell迁移协调 |
| B7 | CodeEditorView.swift:95/105、EditorCompletionPopupView.swift:84；原生SourceEditor外层SwiftUI补全/搜索overlay | editor-owned completion NSView/NSPanel + NSTableView；find用原生bar，评估NSTextFinder适配能力 | 准确caret定位/滚动/IME与first responder归属；现有编辑器不是纯NSTextView，NSTextFinder并非直接替换；不要同时刷新候选和整个editor |
| C1 | GitHistoryScopePicker.swift:19/75；原生按钮+NSPopover+NSHostingController；GitRefListView嵌host；InspectorGitView pull/push popover | 保留现有native触发器，逐步把内容壳换NSViewController/NSStackView，复用GitCollectionView底层table | 已显式contentSize且有native lifecycle，优先级低于workspace/QuickInput；不需要重写整个Git面板 |
| C2 | SSHHostPicker.swift、EditorFilePicker.swift:5/169，AgentHistory filter | 原生搜索列表/树和明确sheet/popup owner | 本地文件继续NSOpenPanel；远端必须保留WorkspaceFilesystem驱动的自有picker，NSOpenPanel不能直接浏览SSH |
| C3 | SettingsView.swift:44/154、各种settings sheets/popovers | 暂保留SwiftUI表单；有具体focus/尺寸问题的控制器或弹窗局部换原生 | 内容低频、表单复杂，全量重写收益低；菜单trigger、数字控件等已有原生接入按需统一 |
| D | About、更新说明、静态帮助/空态、简单状态徽章 | 保留 | 无证据支持重写；更换框架不改善更新/网络/配置正确性 |

## Split 布局单独评估

`SplitView.swift:8` 用 GeometryReader/frame/offset和DragGesture表达二叉split；`TerminalSplitTreeView.swift:30` 用structuralIdentity挂载终端/编辑器叶子。可将渲染布局适配到嵌套 NSSplitView，但建议在固定窗口/shell稳定后再做，风险高于普通列表替换。

必须保留 SplitTree 模型与序列化、比例、zoom、拖入pane、双击均分、最小尺寸、像素取整和键盘focus导航。NSSplitView并不提供这些终端特有规则，也不会自动解决live resize期间的PTY通知。不要把外层sidebar布局迁移与整棵terminal split tree重写绑成一次大提交。

## 已经原生、应保留的实现

- Ghostty SurfaceView/SurfaceScrollView、Metal渲染、键盘/IME与终端I/O；不是需要转换的SwiftUI绘制器。
- ComposerTextView和AgentQuickInputTextEditor、QuickInputHistorySearchEditor：native文本输入已实现，替换的是外围dock/history list。
- GitHistoryTable、GitCollectionView、GitCollectionCell、GitGraphCellView：NSTableView/NSView行复用与绘制已具备。
- TerminalHistoryTable、AgentHistoryTranscriptTable：已经原生长列表。
- CodeEditorView中的SourceEditor/EditorCoordinator底层TextViewController：保留代码编辑、语法与Undo能力。
- MarkdownPreviewView：WKWebView是合适的原生WebKit容器，Markdown/公式/Mermaid不适合为了纯AppKit改成NSTextView。
- NSWindow/NSPanel宿主、NSMenu、NSAlert、NSOpenPanel和现有sheet本身；需要检查的是内容归属和生命周期，不是把名字再换一遍。

## 共同架构约束

1. 一个区域只有一个几何owner；SwiftUI叶子不反推外层窗口尺寸。
2. 操作绑定显式window/tab/pane ID，不能在异步回调里临时猜keyWindow。
3. selection、keyboard focus、hover分开；state/controller决定selection，responder链决定输入。
4. 数据服务/模型不重写：Git/SSH执行、文件树加载、Agent索引、history store、queue和插件typed contracts保持。
5. AppKit不是正确性的替代品：全量reloadData、主线程磁盘I/O、循环layout、重复observer同样能卡顿。必须做增量更新、取消过期请求和bounded cache。
6. 组件可以仍由NSViewRepresentable接入，但不能形成SwiftUI shell→native deck→SwiftUI root→native text controller的多层互相控制。逐步让native owner向下提供固定边界。

## 与tab worktree的排期

- 先核对对方负责的是NSTableView标签栏，还是固定NSWindow内的tab内容切换。当前未读取其worktree，不能假定。
- 主shell、workspace承载、tab selection、TerminalController/TerminalView由一条集成线负责。
- 可并行的独立工作：Files outline、history list、纯AppKit管理弹窗、command palette内容controller，但接入点由主线统一合并。
- 第一阶段：冻结window/tab/pane与presenter接口，完成主shell及Quick Input几何/焦点。
- 第二阶段：Inspector生命周期、Files树、history和command palette。
- 第三阶段：Editor宿主与completion/find，Git diff根据实测体量决定。
- 最后评估terminal split tree。Settings/静态页面不纳入强制替换清单。

## 验收而非“改完能编译”

主shell/dock：切换、展开/收起、resize期间不重建Surface，focus稳定，PTY尺寸提交次数可测；全屏与恢复真实桌面验证。
列表/树：10k条记录/深目录，selection与scroll保持、键盘/IME/右键一致，更新不阻塞主线程；本地/SSH异步返回目标校验。
编辑器：Undo、selection、scroll、输入法、find/replace、completion、preview和多文档切换保持。
Diff：长行、不同高度、跨行复制、hunk定位、左右滚动同步与文件切换。
所有迁移均保留旧模型测试，再增加native adapter和真实交互测试；不要用snapshot尺寸断言代表整个交互已通过。
