# 水平 tab：布局设计与原位切换方案

**实施状态更新：** 运行期方向切换、水平 workspace titlebar 入口、水平 Inspector
内部导航及共用 Agent/split 状态区已在后续补齐。实现采用现有窗口类的动态呈现
策略，保留垂直模式已完成的导航位置；详见
`overnight-completion-2026-10-31.md`。下文保留初始设计推导，不代表仍全部待实现。

基线：`1d616788d`。本轮产出是代码审查、确定的布局方案及交互设计稿，
不是运行时功能已经完成的声明。设计稿：
`horizontal-tabs-design-2026-10-31.html`。

## 推荐布局

普通/透明标题栏样式：

```text
标题栏   [红黄绿] [⌂ Personal ▾]                         [Inspector 开关]
原生 tabs [项目名 · Agent/split · ⌘1] [项目名 · 状态 · ⌘2] ... [+]
内容区   [终端 / 编辑器 / Quick Input]   │ [Files History Git Info 导航]
                                       │ [当前 Inspector 内容]
```

1. **水平模式的 workspace 放标题栏左侧**，紧接窗口按钮区域。显示图标、短名称、
   小箭头；限制宽度，窄窗口截断名称。移除终端顶部现有 32pt workspace 横条。
   垂直模式继续将 workspace 放 sidebar header；任何时刻只有一个可见入口。
2. **Inspector 的导航放到 Inspector 内部第一行**。标题栏右侧只保留显示/隐藏
   按钮。面板折叠后不会留下空导航区；展开后导航、分隔线与内容严格共用宽度。
   两种 tab 布局采用相同 Inspector 导航位置，切方向不再搬动这一组操作。
3. **水平 tab 保留原生整窗条**。每个 tab 的终端和 Inspector 本就属于同一个
   TerminalController，横条跨整窗是合理的。不要为了让 tab 条只覆盖终端区域，
   再通过私有视图树裁切/改造系统 tab bar。
4. **不再重复显示一个大号 cwd 标题**。保留 window.title 的辅助功能、窗口菜单
   和系统用途；可见 chrome 优先提供 workspace 和 tab 信息。

对于 Ghostty 的 `macos-titlebar-style=tabs`，继续保留其原生合并标题栏行为，
不强制增加第二行。workspace 控件压缩为更短的前导 accessory；可用宽度交给
Ghostty/AppKit 的现有 tab 布局和溢出处理。设计稿展示普通双层样式，
不能作为已验证特殊标题栏/全屏几何的证据。

## 当前三个问题的代码原因

### 布局方向被当作窗口创建参数

`TerminalController.tabLayout` 是 `let`；
`windowNibName` 按方向选择 `TerminalVerticalTabs` 或不同的水平窗口样式。
`VerticalTabsTerminalWindow` 又无条件拒绝 native tab-bar accessory。
设置文案也明确写着“仅对新创建的窗口生效”。

所以这不是漏了一次刷新：只把属性改成 `@Published var`，仍会遇到旧窗口类
拒绝 tab bar、标题装饰和 accessory 安装路径不匹配的问题。

### 导航布局分散在两个坐标系

`TerminalInspectorLayout.body` 在水平模式的 center 内容里额外插入 workspace
横条；`installInspectorToggle` 则在标题栏塞入按 inspectorWidth 扩展的导航。
中间再夹一层 native tab bar，形成截图中的纵向错位和重复占位。

### 水平 tab 没有共用新的原生状态呈现

`TerminalWindow.awakeFromNib` 给 `NSWindowTab.accessoryView` 放的是 tab 色标、
快捷键和 split-zoom 重置按钮。Agent/split 的完整展示现在集中在
`NativeTabIconView` 与 native sidebar 中。BaseTerminalController 的 title
拼接状态文本，并不能替代图标、分屏结构及工作动画。

## 原位切换：实现边界

### 不更换窗口或 Surface

窗口类由 Ghostty 的 titlebar/decorations 样式决定，布局方向成为运行期呈现策略。
同一个 NSWindow、NSWindowTabGroup、TerminalController、Surface/PTY 保持不变。
禁止通过序列化/重建窗口、“开新窗口后关闭旧窗口”或动态替换 Objective-C
class 来模拟原位切换。

统一的窗口呈现 adapter 负责：

- 垂直：隐藏 native tab strip、挂载已有 AppKit sidebar；
- 水平：卸载 sidebar 的可见承载、恢复 native tab strip；
- 同步前导 workspace accessory、标题可见性及右侧 Inspector 开关；
- 让 NativeTerminalShell 调整左右宽度，保持 center 的编辑器/终端身份。

去掉按布局方向选择专用 nib 的分支，整理 VerticalTabsTerminalWindow 的专属
规则。Ventura/Tahoe titlebar-tabs 子类的异步 setup 回调也必须检查当前方向和
generation，防止旧回调在切换后重新插入错误的 tab bar。

### “当前窗口”的范围

建议定义为**发起设置操作的 logical window host**：

- 同组所有 tab 一起切换；
- 同 host 的 parked workspace 也继承该方向，避免切 workspace 后又跳回旧布局；
- 其他独立窗口不被突然改变；
- 设置值同时作为以后新窗口的默认值。

Settings 获得焦点后不能用 `NSApp.keyWindow` 猜目标。打开设置时显式保存来源
host/controller，执行时重新校验它仍存活。来源已关闭时只更新默认值。
如果产品决定所有窗口都同步，应明确改成广播策略，不能依赖每个 controller
偶然收到同一个设置通知。

切到垂直时展开 sidebar 并恢复宽度；方向与随后手动折叠 sidebar 是两个动作。
原生全屏过渡期间按 host 保存最后一次方向意图，等 AppKit 完成后应用。

## 水平 tab 的状态设计

采用**标题 + 固定尾部状态区 + 快捷键**，不把状态塞成 emoji/π 文本前缀。

第一版使用公开的 `NSWindowTab.accessoryView`。本地 SDK 的
`NSWindowTab.h` 明确规定它自动垂直居中、靠右；因此不承诺通过这个 API 把动画
图标放到标题最左边。这个原生位置比侵入 `_NSTabBarItemView` 等私有布局稳妥。

状态区复用 `NativeTabIconView`：

- 单 pane：Agent logo 或 terminal/workspace 图标；
- split：相同的紧凑 pane 组合和按 pane 归属的状态；
- working：Core Animation 呼吸，遵循 Reduce Motion、可见性及最小化状态；
- attention/error/done：颜色和明确的符号/提示，不能只靠颜色；
- split 预览在水平模式向下、垂直模式向右，内容及操作共用原生 controller；
- 保留 Ghostty 的快捷键与 zoom-reset accessory 行为，关闭/拖放/溢出仍由
  native tab bar 处理。

窗口标题与 tab 短标题分开：用户 titleOverride 优先；默认短标题、远端 breadcrumb、
Agent 状态从同一个 presentation model 得出。不要让 BaseTerminalController
拼一次状态、horizontal bridge 再拼一次。

## 推荐代码组织

- `TerminalTabPresentation`：抽出目前 sidebar 私有的 title/icon/pane/activity
  推导，供垂直行和水平 accessory 共用；按 tab/Surface 订阅并合并更新。
- `TerminalTabLayoutCoordinator`：host 级方向意图与 generation，协调全部成员；
  不能在每个 tab 上保存互不关联的方向副本。
- `TerminalWindowChromeController`：持有原生标题栏 accessories 和 tab-status
  accessory，提供明确的安装/移除/更新入口。
- `InspectorNavigationController`：将当前顶部导航迁入面板内部，沿用 registry、
  selection、快捷键和宽度策略，不改 Inspector provider 生命周期。

这些是职责边界建议，不要求机械地创建四个新类；能复用现有 controller 的地方
应直接收敛进去。默认不引入第二套自绘水平 tab bar。

## 实施顺序及验收

1. **原位方向切换骨架**：先解决窗口类/布局耦合。测试切换前后 window、native
   group、Surface、PTY、编辑器文档和 Quick Input 草稿身份一致；新 tab、
   workspace 切回及关闭/撤销后方向正确。更新设置说明。
2. **重新布置 chrome**：workspace 前导 accessory、Inspector 内部导航、删除
   center 横条。覆盖窄窗口、Inspector 开关/宽度变化、标题栏样式、全屏、
   窗口缩放及拖动区域。窗口按钮、tab 关闭按钮不能被透明 accessory 遮挡。
3. **共用 tab presentation 与原生状态区**：覆盖单 pane、2/4/deep splits、
   后台 Agent、待确认/错误/完成、titleOverride、远端标题和缺失图标。
   复用/关闭后取消订阅，隐藏后停动画，不用定时器重绘整个 tab bar。
4. **真实桌面验收**：快速水平↔垂直、切 workspace、全屏进出、tab 重排/拖出、
   终端输入、编辑器选择/滚动保持；照片/离屏截图不能替代这些测试。

本轮只完成方案与可交互设计稿，未修改窗口布局或 tab 状态的产品实现，也没有
把前述项目标成测试通过。此前桌面前置条件的阻挡仍需在实际验收时处理。

设计稿验证：桌面宽度下检查了水平/垂直、紧凑窗口、深浅主题、Inspector 折叠、
tab 状态与示例内容切换；HTML 标识符唯一性、JavaScript 语法和仓库文档契约检查
通过。没有为文档/设计稿运行 Swift 产品回归。
