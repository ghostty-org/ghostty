# Workspace 切换核心：AppKit 审查与下一步方案

**后续实施状态：** queued 请求的完成反馈、取消和最终失败回传已补齐；
窗口 host 的 tab 方向及全屏期间方向请求也已接入。见
`overnight-completion-2026-10-31.md`。纯窗口变更计划和旧格式清理仍为后续方案。

基线：`0e9d20dde`。本轮审查切换核心，修复两个已验证的调度边界；
下述整体结构调整是实施方案，不代表已经全部完成。Tab/sidebar 实现已提交，
但此前前台点击、系统拖放与全屏桌面验收的缺口仍然保留。

## 结论

当前 workspace 切换已经以 AppKit 为执行层，不需要再做一轮“SwiftUI 换
AppKit”。应保留 Ghostty 的 NSWindow、TerminalController、Surface/PTY，
将重构重点放在命令调度、最小窗口变更、提交/发布边界和焦点策略。

建议渐进收敛当前核心，不改成一个新窗口反复搬运 SurfaceView 的自建终端宿主。
那会扩大到 Ghostty responder、window delegate、fullscreen 和恢复生命周期，
超出 workspace 整理应承担的责任。

## 已有能力与应保留的边界

- `TerminalWorkspaceState` 保存逻辑 window、workspace、group、tab 的归属。
  非活动 workspace 的窗口会被隐藏/拆散，不能仅从当前 NSWindowTabGroup
  反推全部归属。活动 tab 的真实窗口顺序仍从 AppKit 接收并回写模型。
- `TerminalWorkspaceCoordinator.perform` 已具备旧状态、draft、预检、原生执行、
  校验、提交与失败补偿。应整理这个事务，不撤掉它。
- `TerminalWorkspaceNativeAdapter` 已集中调用 attach、show、orderOut、
  native selection 和 fullscreen 通知。原生全屏保持“目标先加入，源再退出”，
  避免短暂清空全屏容器。
- `TerminalController+TabPresentation` 保留 Ghostty 的 layout/IOSurface 绘制
  和 first responder 接入。运行中的 Surface、PTY、Agent、SSH runtime
  不因 workspace 切换重建。
- 弹窗与关闭弹窗后执行命令的边界已经原生化，下一步只调整结果反馈契约。

## 本轮已复现并修复

### 旧的延迟切换覆盖更新的用户意图

`switchWorkspace` 在判断“当前 workspace”后才处理延迟请求，也没有在普通
切换开始时淘汰旧队列。因此存在两条可复现路径：

1. A 的全屏过渡中请求 B，再请求留在 A；过渡完成仍切到 B。
2. 请求 B 被延迟；原生完成通知已到、队列尚未 drain 时立即切到 C；
   稍后旧 B 又覆盖 C。

现在每个新的有效切换请求先替换该 logical host 的旧意图；选择当前 workspace
会取消旧请求并清理操作错误。过渡中连续 B→C 仍只执行最后的 C。

### 全屏失败回调会同步 drain

成功完成通知原本延迟到下一次主队列执行，但
`fullscreenTransitionFailed` 同步调用 `transitionCompleted`，可能在 AppKit
尚未退出失败通知栈时执行窗口重组。现在成功/失败共用延迟完成路径，并重新检查
该 host 是否已开始另一轮 native transition。

修复前的三个测试全部失败，共五条断言；修复后加上正向“最后目标仍执行”和
“新过渡阻止旧完成回调”的测试，相关三组共 **34/34 通过**。
这是原生通知/调度与真实 controller 测试，不等同真实 Spaces 全屏验收。

日志：`/tmp/omg-workspace-scheduling-before.log`、
`/tmp/omg-workspace-scheduling-after.log`。

补充的 workspace integration/presentation 两组 **29/29 通过**，本轮常规验证共
63 项通过。显式运行了 workspace 桌面全屏套件，三个方法、五个场景均停止在
`NSApp.isActive && window.isKeyWindow` 前置条件，未算通过。日志：
`/tmp/omg-workspace-switch-regression.log`、`/tmp/omg-workspace-switch-desktop.log`。
三个 Swift 文件的 strict lint、文档契约和 diff whitespace 检查通过。

## 下一阶段优先级

### 1. 每个 logical host 的命令调度与明确结果

目前队列只有 `deferredSwitches[host] = workspace`，状态还散落在
`applying/restoring/quitting`、native transition 集合和 presentation generation。
尤其切换已经入队却返回 nil，PickerModel 会按失败重新打开表单；“已接受、稍后
执行”与“拒绝”没有独立表达。

将结果区分为 `committed`、`queued(ticket)`、`rejected(reason)`，并为 host
集中管理 idle、等待原生过渡、applying、presenting 的阶段及 generation。
只合并可替代的 switch 意图；move/delete/create 保留各自的事务语义。
关闭 host、退出应用、目标删除和失败结束时统一撤销对应 ticket。

验收：A→B→C、A→B→A、过渡完成前后交错、两窗口独立请求；UI 不把 queued
显示成“操作未发生”，最终失败也不能因弹窗关闭而失去反馈。

### 2. 生成无副作用的窗口变更计划

现在 `groups(state:hosts:)` 会枚举 host 下各 workspace 并绑定 layout；
adapter 会遍历所有非活动组，重复 cancel/park/orderOut。代码上可确认存在
无关组遍历，但尚未测得其具体性能占比，不将它直接称为卡顿根因。

引入纯值 `WorkspaceSwitchPlan`，明确：

- 哪些 controller/window 发生归属、顺序、可见性或选择变化；
- 哪些窗口无需操作；
- 目标布局、选中 tab、滚动位置和焦点意图；
- 失败后恢复哪些旧值。

计划构造不修改现有 layout 或 native topology。执行器只应用差异，并在提交前
校验实际 native membership/order/selection。普通窗口、原生全屏、非原生全屏
使用清楚的执行分支，共享同一个模型提交/补偿边界。

先增加 attach/detach/show/orderOut 计数和主线程耗时采样，再优化。多增加一个
未参与切换的 parked workspace，不应增加无关原生窗口操作。

### 3. 一次提交、一次 presentation 发布

`native.publish`、`refreshWorkspaceTabs`、sidebar mount、
`prepareWorkspaceFrame` 和 `finishWorkspacePresentation` 目前有重叠的刷新职责；
后者还最多补偿十次。先保留有效的首帧保护，再逐步把 readiness 接到原生
container 的 window/layout 生命周期，使用同一 generation 淘汰旧回调。

焦点成为计划的一部分：用户主动切换可进入目标终端；仅删除/整理后台 workspace
时，应保留未受影响窗口当前的 Inspector/编辑器输入焦点。现在 publish 的
key-window 分支直接 focus surface，是需要专项覆盖的代码路径风险，
本轮没有把它当作已复现的用户故障。

屏幕更新抑制只包住必要的 native mutation/首帧阶段，并用作用域/defer 保证配对。
它不能替代数据事务，也不能承担状态同步。

### 4. 按破坏性升级许可清理旧状态兼容

`membership/hiddenTabs/selectedTabs/parkedGroups` 等旧索引、optional windows
分支、v1 归一化和旧启动恢复交叉路径可以作为独立一批删除。先检查所有运行期
读取点，避免把仍被构造器查询的索引直接删掉。

新格式只保留明确的 ownership graph 与纯 session descriptor；不要把 AppKit
对象序列化成新的权威状态。同版本的完整 generation、原子写入、失败补偿和
`.previous` 损坏恢复仍需要保留，它们承担运行期可靠性，不是旧版本兼容。

## 不建议立即采用的替代方案

普通窗口模式可以试验“每个 workspace 保持独立 NSWindowTabGroup，只切显隐”，
减少拆组，但不直接定为统一方案：原生全屏 Space、Stage Manager、多个窗口和
焦点交接的行为尚未验证。先以小型原型比较，再决定是否替换现有可靠交接步骤。

## 验收要求

- 快速往返、创建、移动最后一项、删除后台 workspace：Surface/PTY 身份稳定，
  最后意图生效，其他窗口不隐藏、不换 workspace、不被抢焦点。
- 新 AppKit sidebar 的 controller/outline 身份、选择和滚动位置正确；
  快速切换不让旧 generation 的 header/首帧覆盖新状态。
- attach/show/rollback 注入失败：模型只提交一次，补偿失败有明确结果，
  UI 不声称“完全未变化”。
- 普通、原生全屏、非原生全屏分别验证；前台桌面测试单列，
  不以通知模拟代替真实全屏/拖放/输入。

建议下一批先做 **调度与结果契约 + 纯变更计划及计数测试**，然后再拆 presentation
发布和旧兼容状态。这样每一批都有可验证的行为改善，而不是换一组类名。
