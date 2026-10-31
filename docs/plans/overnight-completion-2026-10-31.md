# 四轮委托的完成度复核与补齐

审查基线：`7cf46b0a8`。这里的“四轮”按本会话最近四项工作核对：
绘制/hover 回归、原生 tab sidebar、workspace 切换、水平布局。
应用中没有发现另一个正在修改同一 main 的相关任务。

## 发现的未完成项

| 工作 | 审查时状态 | 本轮处理 |
| --- | --- | --- |
| 控件与 diff 绘制 | 已有实现和定向测试，桌面验收不足 | 重跑控件、diff、completion 相关测试；修复隐藏 completion popup 的零尺寸约束冲突 |
| 原生 sidebar | 已实现；真正鼠标/全屏验收未完成 | 回归 native sidebar 身份和 split 保留；水平状态区复用其原生图标 |
| Workspace | 修复了旧意图覆盖，但 UI 仍把 queued 当失败 | 增加 committed/superseded/failed 完成回调；队列等待不再弹失败，最终失败仍返回管理页面；关闭/退出取消待办 |
| 水平布局 | **只有文档和 HTML 设计稿** | 本轮补入运行时代码，见下文 |

## 本轮实现

### 当前窗口原位改变方向

`tabLayout` 不再是仅创建时的常量。设置修改通过 Ghostty 已有的 last-main
terminal 选择目标 logical host，更新该 host 的活动和 parked controller；
其他独立窗口不跟随变化。方向同时写入 host catalog，后续重建/恢复成员不会
重新读取旧方向。新窗口仍使用设置的默认值。

NSWindow、native group、TerminalController、Surface 和 PTY 保留；新 tab
继承父窗口的创建样式，避免切完方向后新 tab 突然换一种窗口皮肤。
原生全屏过渡中只保留最后一次方向请求，结束后应用；旧 presentation generation
失效。窗口类保持不变，现有 Ghostty 窗口样式改为按当前方向决定 native tab bar
是否允许显示，没有运行期换 class 或重建终端。

### 水平 chrome 和状态

- workspace 使用原生前导 titlebar accessory，删除正常标题栏下重复的 32pt
  center 横条。无标题栏/borderless 模式保留内容区的可用入口。
- 水平模式中 Inspector 的 pane 导航位于面板内，titlebar 只保留开关；
  垂直模式保留此前已实现的标题栏导航，不在这次补齐中扩大改动。
- `NSWindowTab.accessoryView` 增加原生 Agent/split 图标，保留快捷键及 zoom
  reset。标题、远端 breadcrumb、图标和 activity 推导已从 sidebar 抽成
  `TerminalTabPresentationResolver`，两种方向共用。
- `NativeTabIconView` 的水平预览朝下；更新颜色/边框时关闭隐式动画，
  工作呼吸仍由原来的 Core Animation 生命周期控制。
- accessory 使用原生独立承载来容忍 AppKit 临时给出的零尺寸，不让内部按钮
  产生 required constraint 冲突。

### 复核发现并修复的边界

非原生全屏会暂时移除 `.titled`。在这种状态下，连读取
`titlebarAccessoryViewControllers` 都可能抛 AppKit 异常。已在新 chrome、
sidebar accessory 和 Inspector 安装入口保护该状态，并通过 style-mask
通知在恢复后同步。原生 tab bar 显隐也不与 workspace/native fullscreen
事务竞争。

## Workspace 后续方案的边界

之前文档中的“纯变更计划、进一步减少无关窗口操作、删除旧格式迁移”仍属于
后续架构/性能整理，不能称为已实现。它们不作为上述用户可见切换功能已经可用的
前提。本轮优先补齐实际遗漏的水平功能和 queued 结果反馈，而没有冒险重写已在
使用的 workspace 状态图和持久化恢复。

## 验证与验收状态

已新增/扩展测试覆盖：

- 同一 window/content/Surface 身份在水平↔垂直之间保持；
- parked workspace 方向、host catalog 编解码、设置只作用于 last-main host；
- 新 tab 保持父窗口样式，水平 tab accessory 安装、native tab bar 显隐；
- 两种方向 Inspector 生命周期与水平内部导航位置；
- queued workspace 无误报、最终失败返回表单，以及旧请求取消；
- 控件实际绘制、native sidebar、diff 编辑器保持和 completion 生命周期。

本轮全量首次执行 1,250 项：1,242 通过、7 失败、1 跳过。包含一个因 AppKit
NSAnimation 阻塞达到 75 条 dispatch 线程软限制而被终止的测试进程，以及上述
标题栏异常。修复后的边界复跑执行 50 项，49 通过；仅真实 modal 按钮点击用例
仍失败，原生全屏相关异常不再出现。全量不是全绿，不能以复跑替换原始结果。

后续不包含受锁屏影响 modal 用例的功能验收 **50/50 通过**；最后一次代码变更后，
方向切换、原生组加入、Agent 状态、queued workspace 和 Inspector 三组
**14/14 通过**（含参数化场景）。21 个 Swift 文件 strict lint、41 项选择器契约、
文档契约和 diff 检查通过。并未删除或跳过原始失败断言。

读取当前 GUI session 得到 `CGSSessionScreenIsLocked = 1`。真实鼠标、焦点、
全屏与 modal 交互目前无法可靠验收，不跳过断言或修改测试来伪装通过。
早晨验收应重点检查方向切换、水平图标/分屏预览、workspace 快速切换、
拖动/关闭 tab，以及终端/编辑器输入焦点。

日志：
`/tmp/omg-completion-regression.log`、
`/tmp/omg-completion-stall.sample`、
`/tmp/omg-completion-edge-check.log`、
`/tmp/omg-completion-acceptance.log`、
`/tmp/omg-completion-release-check.log`。

本轮修改的是产品运行时代码，不再只是水平布局设计稿。没有覆盖安装或推送。
