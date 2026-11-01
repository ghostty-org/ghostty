# Oh My Ghostty 插件与原生扩展架构

- 状态：已采纳，进入实施
- 日期：2026-08-21
- 范围：macOS 首批功能；共享 Zig 核心仅在没有可靠上层接入点时修改

macOS 终端继承宿主环境时，会移除空值的 `NO_COLOR`，避免仅检查变量存在性的工具（如 eza）意外禁用颜色。非空 `NO_COLOR` 保留；用户的 `env` 配置和 surface 环境覆盖在继承过滤之后应用，因此仍可显式禁用颜色。开发安装启动也应避免继承构建工具自身的 `NO_COLOR=1`，例如使用 `env -u NO_COLOR` 运行安装脚本。

## 1. 最终裁决

首批 Sidebar、Agent 状态提醒和 Pi 集成全部使用 SwiftUI/AppKit 原生渲染。首批不链接、不初始化 WKWebView，也不引入前端框架。

WebView 不是首批架构依赖。它只可能在第三方生态开放后作为按插件启用、按插件懒加载、默认关闭的可选 UI 后端返回。

以下核心方向维持不变：

- 插件逻辑运行在 Ghostty UI 进程之外。
- macOS 宿主与插件通过 Unix domain socket 通信。
- Ghostty API 按能力授权，写能力默认拒绝。
- 改动集中在 fork 自有目录和稳定接入点，降低跟随 upstream 的冲突。
- Sidebar、状态插件和 Pi 按独立功能交付，共享同一协议与进程监管底座。

## 2. 仓库事实

当前仓库已具备以下可复用链路：

- 每个 `Ghostty.SurfaceView` 都有 UUID，可作为运行期和恢复后的 surface 标识。
- OSC 标题最终更新 `SurfaceView.title`，聚焦 surface 的标题再进入 `NSWindow.title`。
- OSC 9;4 已在 Zig 核心解析，并作为 `progressReport` 到达 macOS `SurfaceView`。
- `Ghostty.Surface.foregroundPID` 已通过公开 C API 读取 PTY 前台进程组 PID。
- `SplitTree<Ghostty.SurfaceView>` 已表达单个 tab 内的 pane/split 树。
- `Ghostty.Surface.sendText` 已能向 PTY 输入端发送文本，但它是控制能力，不是终端显示注入能力。

这些事实降低了原生实现成本，但不等于已有完整插件事件总线。

## 3. 术语与标识

协议中的 `session` 明确定义为一个 terminal surface/pane，对应 `SurfaceView.id`。它不是 AppKit tab，也不是 window。

- Session ID：`SurfaceView.id`，UUID。
- Tab：一个 `BaseTerminalController` 管理的窗口/标签，内部可以包含多个 session。
- 聚焦 session：决定当前 tab 标题和大部分快捷操作的 surface。
- Vertical tab item：一个 `TerminalController`/`NSWindow` tab，与 `NSWindowTabGroup.windows` 1:1；split/session 不额外生成 tab 行。

首版不承诺 ID 跨设备或跨一次被删除后重新创建的 session 保持不变。

## 4. 进程模型与传输

### 4.1 进程拓扑

宿主为每个已启用插件启动一个受监管子进程。首版不把多个插件装入同一个共享进程，避免一个插件崩溃拖垮其他插件。

首版只允许随应用签名和发布的官方插件。第三方可执行代码必须等到系统沙箱、签名校验、安装与升级策略完成后开放。

独立进程只提供故障隔离，不自动提供安全沙箱。Ghostty 能力授权可以阻止未授权 IPC 调用，但无法单独阻止一个普通子进程读取用户文件或访问网络。

### 4.2 Socket

- 每次 Ghostty 启动创建私有运行目录，目录权限为 `0700`。
- 每个插件使用独立 socket，socket 权限为 `0600`。
- 路径和一次性随机 nonce 只通过子进程环境传递。
- 宿主校验连接方 UID、预期 PID 和握手 nonce；未知连接立即关闭。
- wire format 是 4 字节网络字节序长度加 UTF-8 JSON payload。
- 单帧上限 1 MiB。队列必须有界；慢消费者不能阻塞 UI 或 terminal I/O。
- 握手协商协议版本和能力。版本不兼容时拒绝启动，不做猜测性降级。

### 4.3 生命周期

宿主负责启动、握手超时、心跳、退出检测、有限次数退避重启和禁用。插件断开时，宿主立即撤销该连接的状态 lease、订阅和待处理控制请求。

## 5. API 边界

### 5.1 Terminal Event API

稳定首版事件：

- session opened/closed
- title changed
- OSC 9;4 progress changed
- foreground process changed
- focus changed

前台 PID 当前是读取接口，不是推送源。首版由宿主低频采样，仅在值变化时发事件；应用不活跃或 session 不可见时降低采样频率。

原始 terminal output 不属于稳定首版。它需要修改高吞吐路径，并必须先解决背压、敏感输入、密码模式、日志留存和每插件授权。未来若实现，能力名为实验性的 `rawTerminalOutput`，默认拒绝，丢弃策略优先于阻塞 terminal。

状态识别优先级：

1. Agent/CLI 显式结构化事件或适配器。
2. OSC 9;4 进度事件。
3. 前台进程和生命周期信号。
4. 明确授权后的实验性输出识别。

通用输出启发式不能承诺准确识别“等待用户”。

### 5.2 Declarative Native UI API

稳定首批能力：

- `setSessionStatus`
- `clearSessionStatus`
- Sidebar 只读数据模型
- QuickInput 的展示请求和提交结果

`setSessionStatus` 以 plugin/session/revision 为所有权键。revision 必须单调递增。状态在插件断开、session 关闭、显式清除或 TTL 到期时撤销，防止崩溃后留下陈旧 UI。

首版只授予一个官方状态插件可见状态写 lease。未来多来源状态进入 Sidebar 前再定义仲裁规则，不把“最后写入者获胜”固化为稳定行为。

标题渲染只组合宿主拥有的数据：agent、原始/用户覆盖标题、状态。它不访问私有 `NSTabButton`。有 split 时，垂直 tab 行只显示该 tab 聚焦 session 的标题与状态。

### 5.3 Terminal Control API

该 API 是实验能力，首版只授予官方 Pi 集成。所有 PTY 写请求必须：

- 绑定目标 session 和插件身份。
- 展示完整或可检查的待写内容。
- 每次由用户确认，不能以“本次会话允许”绕过。
- 确认时再次校验 session 仍存在且仍是预期目标。
- 写入审计日志，记录时间、插件、session、摘要、长度和结果；默认不持久化密钥或完整敏感文本。
- 在 secure input/password input 状态拒绝自动发起。

`sendText` 是 PTY 输入，不是终端显示输出。首版不增加绕过 PTY、直接喂 terminal parser 的“伪输出”API。

## 6. 首发功能

### 6.1 Agent 状态提醒

官方状态层由 bundle manifests 驱动，覆盖 Codex、Claude Code、Pi、Qoder CLI、Reasonix、OMP、OpenCode、Amp、Antigravity、Cline、Copilot、Crush、Cursor Agent、Droid、Grok、Hermes、Kimi 与 Qwen Code，并将各自 hook/plugin/TOML/scripts/screen signals 归一为 `idle`、`working`、`needsAttention`、`done`、`error`。事件使用 `omg-agent-<tool>-<numeric-instance-id>` 的 bounded OSC 3008 presentation context，并以 `omg_liveness=pid|pgid` 区分 Plugin 进程 PID 与 shell/config/foreground synthesis 的进程组 ID；事件由 agent 所在 TTY 接收，因此 Local 和 SSH Pane 使用同一 Surface correlation，hook 可附带经过白名单校验的 `omg_conversation` 用于精确恢复。部分 agent 版本会延迟或不发送 `SessionStart`，因此 macOS Host 每秒只读取一次 Ghostty 已有的 foreground process-group PID；仅当 PID 改变时，才在 utility queue 执行一次 `ps`，识别本地 `codex`/`claude`/`pi` 并合成 `idle`。唯一实例 ID 阻止旧 session 的 `end` 清理新 session；Local 启动有 4 秒 handoff grace，之后按声明的 PID 或 PGID 检查存活性。PID-backed Plugin 在子工具改变 foreground process group 时仍保持有效，只有声明的进程本身退出才进入 `error`。SSH 不从本地进程名猜测远端 Agent；但 Host 会保守识别 Surface 前台进程组中的交互式 OpenSSH transport（排除端口转发、control/no-command 模式和显式远端命令），使普通 `ssh host` 自动进入 inferred SSH context。此前台进程组回到本地 shell，或 matching typed `omg +ssh` lifecycle 结束时，Host 原子清理 live remote Agent 展示和恢复状态，可恢复断线前先把 exact conversation 移入独立的离线 SSH 恢复描述；下一个 authenticated remote Fish/bash/zsh prompt 仍作为额外的异常残留清理信号。远端不依赖 OMG executable。普通交互式 `omg +ssh` 的本地 CLI 已构造一次性远端 Fish `-C` 或 Bash/Zsh 临时启动文件以发送 SSH context/cwd；同一路径加载与本地相同的 Bash/Zsh 集成源文件及共享 Fish 命令模块，注入 OSC 133 A/B/C/D 命令边界；`ssh.zig` 只做传输与启动适配，不维护第二套精简 hooks，不需要用户额外安装常驻远端 OMG 进程或修改远端 dotfiles。远端既有无标记输出不能反推命令；非交互式 SSH 和未知 Shell 不强行接管。

Vertical Tabs 的 logo、title、cwd 和 working ring 严格消费 focused Surface；同 Tab 的其他 pane 只能贡献 trailing `needsAttention`/`error`/`done`。Agent manifests 提供 optical scale，使品牌 glyph 与 terminal/cloud 图标保持一致视觉尺寸。Agent 启动时 OpenAI/Claude/Pi template glyph 替换 terminal/cloud；idle 不显示 ring，working 使用旋转的四分之一圆 progress indicator；等待审批、完成和失败继续使用右侧 status slot。正常完成即使发生在当前 focused Tab 也保留 `done`；Tab 选择或 pane focus 本身不 acknowledge，只有 owning focused terminal 收到鼠标点击或键盘输入才清除 `done`/`error`。Agent 在 `working`/`needsAttention` 时意外退出会转为 `error`，不会静默消失。Agent context 清理后恢复 canonical terminal/cloud icon。Horizontal Tabs 保持 Ghostty 原生 presentation，不注入自定义状态 UI。Hook 只能改变展示状态，不获得 Terminal Control、文件系统或网络能力。

Settings 根据 manifest 显式安装/移除 nested/flat JSON hooks、Pi-compatible/OpenCode/Amp plugins、Kimi TOML block 或 Cline scripts，并保留所有非 OMG 配置。SSH 上可导出 Python 3 installer，由用户审阅、传输并在 agent 实际运行的远端账户显式执行；本地 App 不登录或静默修改远端 dotfiles。

每个内建 Agent 由 bundle manifest 声明 command、icon、process markers、hook dialect/events/identity fields 和 resume/store 机制。Host 只实现固定机制，manifest 不能携带任意代码。Terminal restoration v9 在每个 Surface 上保存 typed `AgentResumeDescriptor`；默认 `sessions.startupMode=restoreSessions` 让 AppKit 恢复原有 window/tab/split tree，并对退出 OMG 时仍运行的 Agent 使用 exact conversation ID；`restoreTabs` 仅恢复布局和本地目录，以新本地 Shell 启动每个 pane，不恢复输出或 Agent/SSH 进程，`newTerminal` 则不恢复旧 tab。Local 只生成 allowlisted resume argv；SSH 只重放 original OpenSSH argv、cwd 和 typed agent/session options。Agent 已 `/quit` 回 shell 时 descriptor 被清除；conversation ID 缺失时 SSH 恢复不携带 `--remote-agent`，pane 回到远端 shell 而不是本地 shell。每个处于活跃 `omg +ssh` 连接的 Surface 额外保存 typed `SSHResumeDescriptor`（validated replay argv、ready remote cwd、pre-SSH local cwd），恢复时无可用 Agent descriptor 的 pane 重放 `+ssh` 连接，纯 SSH 标签页不再退化为本地 shell。恢复命令统一包在 `/bin/sh -c '<command>; exec <login shell>'` survival wrapper 中，避免 macOS `exec -l` 丢弃命令尾，Agent 或 SSH 退出后 pane 回到可交互 login shell 而不是随子进程关闭。

未进入 Session Runtime 的普通 system SSH 断线恢复仍以 Surface 为单位，不增加 workspace UI：typed `+ssh` 的 status=255 保留 `SSHResumeDescriptor.awaitingReconnect`（也包括认证/配置失败，不能据此断言网络故障），其他退出码清除；普通交互式 SSH 在取得 exact argv 时也保留手动恢复入口，因进程检测无退出码，正常 logout 也可能出现入口。离线 pane 重启只恢复本地 shell 与待重连提示，不发起周期性连接。用户选择“Reconnect in New Tab”后以新 PTY 重放原参数、最后远端 cwd 和已知 Agent exact conversation，旧 pane 保留输出与本地进程；“Keep Local”清除待重连信息。新目标继承恢复信息以承受连续失败，但新的远端 prompt 会清理旧 Agent 备份，由新 hook 确认 live identity。离线信息不启用远端 Files/Git，也不替代 tmux 等远端进程保活机制。

Session Runtime 的本地后台会话与 SSH 会话共享 descriptor、daemon、snapshot 和关闭语义，SSH 仅是连接远端 host 的传输层。支持的交互式 SSH handoff 和设置页连接在当前工作区添加原生 tab，不移除原本地 Surface；发起连接的 shell 立即恢复可交互。relay 在网络断开时保留本地客户端 socket，后台退避重连；认证/配置与会话丢失显示 pane 内状态。原 Surface 原位恢复快照并重新取得 writer，UUID 与仍存活的远端 PID 保持不变。输入在入队时绑定连接 generation，断线输入不重放；snapshot ACK 也受 generation 限制。手动重试唤醒 relay，不重建 Surface 或中断健康的 sibling panes。普通既有本地 Exec 不迁移；新本地窗口/tab/split 默认走 runtime，可通过 `sessions.localRuntimeEnabled` 关闭。独立本地 holder 保留 PTY/VT，broker 重启后通过私有能力验证收编；远端保持单 host daemon 与 session threads/cgroup。Ghostty 自己准备本地命令、环境、目录和一次性 input，本地进程信息与 Secure Input 沿用原生行为，不获得 SSH context 或远端文件路由。关闭窗口/退出是 detach，显式关闭 tab/pane 是 durable close；原生会话库可查询、attach 或结束后台 session。详见 `docs/architecture/session-runtime.md`。

本地普通 Shell Pane 的正常退出恢复与 Agent 逻辑分开：AppKit 保存 tab/split/cwd；host-owned 小型导出适配器从 Ghostty formatter 保存受限 VT scrollback，fork-owned shell integration 在新 PTY 第一次 prompt 前回放并移除快照。旧进程不会被复活；旧命令的 OSC 133 区域由 tracked Pin 导出并在回放时重新建立锚点；锚点若因回放/覆盖失效，旧命令仅显示为不可跳转的只读记录。成功跳转仅短暂高亮实际锚点所在行，不全文搜索。持久化文件只放于 channel 专用、用户私有目录，快照损坏、超限、未完成或 Agent/alternate-screen 场景优先跳过；普通 SSH Pane 也可保存同 Surface 的旧输出，但必须在重连前本地回放；新快照 v4 为同一 Surface 所有仍有效的本地/SSH 段保存 occurrence ID，并在 VT 中给 OSC 133 B 加 aid 标记；切换连接只变更新命令的 epoch，不销毁历史 Pin，回放完整逐条校验后各段都可跳转；只有缺失/失效锚点的旧命令只读，来源与旧 epoch 始终保留，不触碰插件的 PTY 控制能力。

Right Inspector 的 `builtin.agent-history` 复用同一份 manifest resume/store 真相源，只扫描同时具备本地 JSONL store/discovery 与非空 allowlisted resume arguments 的 Agent。Host 在 utility task 中限制枚举数量、header、消息数和单条消息长度，跳过 symlink，并验证 `AgentConversationID` 与日志元数据；版本化 mtime cache 只重解析新增或改变的 session，`agents.historyLimit` 默认索引 10,000 条；只注册但从未打开该 pane 时不启动 scan、timer、watcher 或 helper process，最后一个可见实例消失时取消未完成任务。外围搜索经 debounce 后先返回标题/元数据，再返回缓存正文摘要，最后按最近会话顺序在后台渐进检索完整 user/assistant 正文，并返回可高亮的 bounded snippet；点击结果会把搜索词带入 transcript，以匹配消息及前后上下文打开。长会话使用 AppKit `NSTableView` 行复用和自动高度缓存，不再让 SwiftUI 对整段动态文本列表持续重新测量。UI 同时提供 Agent 过滤、project/Agent/date 分组、排序、copy、原生 fork、用户/Agent transcript 和手动刷新。Resume 优先定位已有 live Surface，否则构造 typed `AgentResumeDescriptor` 并在新 Tab 中进入 exact conversation。首版不猜测未声明的 CLI flag，不扫描远端 home，也不执行 transcript 内容。

退出时按 `tabSessionID` 额外保存每个原生 window group 的选中 tab 与前台终端 tab，在退出确认/销毁窗口前冻结；取消退出会解除冻结。恢复完成后按已恢复成员身份重新选择，不用窗口创建顺序或 tab 数字推断；后台 pane 的延迟 focus 回调不得把其他 tab 拉到前台，用户主动操作会取消待执行的恢复选择。

### 6.2 Tab Layout

Vertical Tabs 不是独立 Sidebar 产品，而是 Ghostty tab bar 的另一种 orientation。`macos-tab-layout` 支持：

- `horizontal`：使用 Ghostty 原有 window nib、titlebar style 和 native horizontal tab UI。
- `vertical`（默认）：同一 `NSWindowTabGroup.windows` tab model 由左侧 vertical tab bar 呈现，native horizontal accessory 在加入窗口层级之前被拒绝。

两种 layout 共享 `TerminalController`/`NSWindowTabGroup` 的新建、关闭、选择、恢复、顺序、标题和快捷键路径。Vertical presentation 消费统一的 title/shortcut/icon/selected/hovered metadata；插件未来只能提供可选 icon/metadata override，不能控制 tab bar view。split 继续由 terminal 内容区管理，不生成额外 tab 行。

每个逻辑 `(windowSessionID, workspaceID)` 标签组只保留一份 live vertical sidebar hosting view。各 NSWindow 的 shell 预留 sidebar 容器，提交选择或关闭当前 tab 时移动同一份 view，保留行身份与滚动状态；旧窗口最多保留上一帧静态图像，不能以清空/重建行树优化后台开销。纵向模式下多个 workspace 可以共用一个物理原生组，只有当前 workspace 的 host 参与呈现。拖出新窗口会复制布局偏好并建立独立 presentation，合并后回到目标组。连续新建按最新待显示 tab 计算插入位置，过期显示任务不能重新抢焦点；选中变化把对应行滚入可见区域。

后台 tab 可以保留旧尺寸的 IOSurface 并停止自动重绘。窗口放大后关闭或切换 tab 时，Host 先同步即将显示窗口的尺寸和布局；仅当该 tab 的保留图像尺寸不匹配时，通过 app-thread 的显式 `ghostty_surface_draw` 同步准备一帧，再交给 AppKit 显示。普通隐藏层的 display 回调仍跳过绘制，不在 resize 时刷新整组后台 tab；恢复可见时先更新 renderer visibility，再立即重建并绘制，避免首帧被 hidden guard 丢弃。该准备路径沿用 renderer 的背景色和透明度，不叠加不透明兜底层。

Layout 配置只对新窗口生效。运行时更换 orientation 需要替换 NSWindow class/titlebar hierarchy，当前不安全，因此不会重建已有 PTY、surface 或 scrollback。

### 6.2.1 Named terminal workspaces

工作区是原生 Tab 之上的宿主归属层，默认创建 Personal；左上角原 TABS 标题替换为图标、名称和下拉入口。入口支持搜索、新建、改名、图标/低饱和颜色选择和移动当前完整 Tab。折叠 vertical sidebar 时工作区入口随侧栏一起隐藏，快捷键仍可通过窗口内容锚点唤出；horizontal tabs 在内容区顶部保留紧凑入口。默认 `⌃⌘W` 打开切换器、`⌃⌘1…9` 按固定目录顺序切换，Settings > Shortcuts 支持修改并提示工作区、OMG 面板、菜单及 Ghostty binding 冲突；第三方全局快捷键不保证能检测。切换器默认选中当前窗口的上一个工作区，确认后才切换。管理入口关联具体行：顶部新建进入预览表单，“创建并打开”在原生呈现成功后一次提交目录与终端；每行菜单可编辑/删除未激活工作区。移动当前标签进入可搜索目标页，删除确认显示实际默认目标和标签数；失败保留表单与具体原因，不再只响提示音。

运行期切换保留 TerminalController、Surface、PTY、SSH 与 Agent，不通过序列化重建。纵向模式将同一用户窗口已加载的 workspace 标签保留在一个 `NSWindowTabGroup` 中，切换只选择目标窗口并发布当前 workspace 的逻辑标签列表，不在每次往返时拆散、重建整个组。快捷键、拖放、排序、关闭和脚本接口使用逻辑列表，不能把物理组里的其他 workspace 当作当前标签。横向模式及非原生全屏仍使用分开的 workspace 组；关闭当前窗口、关闭最后一个活动标签或进入这些模式前，先隔离当前 workspace，避免关闭其他工作区的会话。后台标签显式关闭时只移除自身。

每个用户窗口有独立稳定 ID，按 `(windowSessionID, workspaceID)` 管理稳定 tab 组、顺序、选中项和滚动位置；切换只查找当前窗口的组，其他窗口显示相同工作区时不抢焦点、不搬动其 tab。首次进入目标工作区时创建当前窗口自己的组，复用普通 new-tab 的本地启动配置和目录继承策略，在首帧提供已知目录信息；SSH/runtime 沿用既有本地目录回退。后台会话继续占用进程资源。完整 Tab 移动保留 Surface/tab 身份，原工作区最后一个 Tab 被移走后创建空终端。保留纵向物理组时 tabbingIdentifier 使用用户窗口 ID，隔离模式再加 workspace UUID，始终避免系统自动合并独立用户窗口。原生 tab 拆窗创建新窗口身份，合组和撤销同步更新归属。

`TerminalWorkspaceState` 统一保存已提交的 workspace/window/group/tab 归属与顺序；Coordinator 的 live registry 保留运行对象，Controller 字段和原生组只作为投影。switch/move/delete 整体预检、冻结旧图，经 `TerminalWorkspaceNativeAdapter` 完成原生操作后一次提交；失败补偿旧拓扑，删除按窗口合并组，不隐藏其他窗口当前 workspace。原生全屏过渡按实际 NSWindow 身份跟踪，结束/关闭清理，不随逻辑窗口 ID 变化残留。全屏进入/退出期间推迟切换，延迟呈现回调携带 generation，避免快速往返后旧回调抢回焦点或重挂 sidebar。非原生全屏不具备 native tab 能力，adapter 在同一呈现事务内规范化旧窗口、重组目标、再让目标进入原模式；全屏期间 sidebar 消费逻辑组，退出后重建原生组，模式随窗口持久化。共享 workspace 布局偏好即时同步到各窗口，order/selection/scroll 保持窗口独立。布局观察只发布实际改变的 sidebar/Inspector 字段，Quick Input 状态不触发无关几何发布。workspace popover 由 Controller 命令直接呈现，SwiftUI 只登记锚点，不依赖视图重绘触发打开。Quick Input 普通打开不覆盖旧帧截图；仅实际外部编辑器草稿握手可保留短时 TUI 截图，pane resize 立即使其失效。编辑框原生视图就绪后一次移交 first responder，Controller 保存的 pane 选择负责视觉高亮。

工作区目录与纯 tab/split/Agent/SSH/runtime 描述共同写入 channel-specific Application Support 的 `workspaces/state.json` v2 envelope，包含 generation，私有后台串行 writer 合并请求并原子替换，保留 `state.json.previous`。旧 `catalog.json`/`sessions.json` 只作迁移输入。恢复先校验纯数据及全部归属引用，再创建 Surface；损坏新快照回退上一代，未知旧 workspace 迁入默认组。有效非空快照及用户明确清空的 v2 快照优先于 AppKit，空或不可用 v1 不抢占恢复。结构变化触发提交，每秒只检查目录/标题/恢复描述变化；无变化不落盘，采样不再修正归属。窗口关闭保留、显式 tab 关闭删除，Undo 同时恢复持久化资格。旧快照按已有原生组迁移独立窗口，不猜历史窗口关联；kill 恢复最后成功提交，不承诺任意进程内存。工作区只隔离标签组织和窗口展示，不隔离 shell 环境、磁盘、凭据或网络。测试计划在启动前设置 `OMG_TESTING=1`，workspace 单例不读写用户目录，显式持久化 fixture 只用临时路径，不按测试风格名称清理用户数据。详见 `docs/WORKSPACES.md`。

### 6.3 Pi

Pi 不依赖 Sidebar 或状态插件，但依赖 IPC、QuickInput 和 Terminal Control。

首版采用 CLI 适配：QuickInput 收集内容，用户确认后写入目标 PTY，由 Agent CLI 自己产生正常 PTY 输出。这样不需要终端伪输出通道，也不让 Ghostty 持有 Agent API key。

QuickInput 以聚焦 terminal 区域底部 dock 呈现，默认快捷键为 `⌘⇧E`，可在 OMG Settings > Editor > Quick Input 中录制修改；输入框配置与发送历史配置统一放在“快速输入”组，旧配置键保持不变。展开后它加入默认 `⌥⌘` 方向键焦点导航：最底层 terminal 可用 `⌥⌘↓` 聚焦输入框，输入框可用 `⌥⌘↑` 返回 terminal，并可用左右方向进入相邻 split。可选的 `agents.openQuickInputOnStart`（默认关闭）会在 focused Pane 首次进入 Agent activity context 时自动展开输入框，但不抢占 terminal 的键盘焦点。dock 是 terminal shell layout 的真实底部区域：展开或拖动顶部 8pt resize handle 会改变 terminal presentation height，使被挤出的行进入正常 scrollback，并可继续用滚轮访问。handle 与左右 Sidebar 共用 resize interaction、1pt divider width 和 renderer-derived divider color；三个边界的 8pt hit target 都以负 inset 覆盖在相邻内容内部，布局只占 1pt，不再形成透明 gutter。最后确认的 140–480pt 高度写入 `keyboard.quickInputHeight`。普通 draft 中，`⌘↩` 发送完整内容后再发送真实 Enter key event，`⌥⌘↩` 将 draft 加入入队时 Surface UUID 所有的内存 FIFO，Escape 关闭并保留 draft；编辑 queued item 时，`⌘↩` 原位保存而不发送，`⌥⌘↩` 保存并移动到队尾，Escape 放弃修改且保留原消息。Composer 使用 fork-owned `NSViewRepresentable` 包装原生 `NSTextView`/`NSScrollView`，由 first responder 原生处理 `⌘A/C/V/X/Z/⇧⌘Z`、selection、undo 和 IME marked text；为避免 terminal/window key routing 差异，Composer 还显式将 Option+左右映射为按词移动、Option+上下映射为按段移动，并为 Shift 组合选择对应的 modify-selection selector。Escape 在存在 marked text 时只交给输入法取消拼音组合；没有 marked text 时由 editor 消费并关闭 Composer，因此不会继续触发 macOS 退出全屏。纯图片粘贴复用 `NSPasteboard.imagePastePath()` 的 0700 目录/0600 PNG/7 天清理规则，把安全临时路径插入 draft；文本或文件 pasteboard 仍走原生粘贴。队列以 terminal shell 最底部的独立横向 lane 展示，不覆盖 terminal glyph；60pt lane 中的 44pt 卡片按 FIFO 从左到右排列，按内容估算宽度并受 136–420pt 与可用宽度约束，`resume` 等短消息不会占据不必要宽度。超出时水平滚动并自动跟随最新项。卡片左侧 Enter 图标可点击立即发送，右侧支持编辑、删除，三个按钮使用 30×30pt hit target，hover 切换为 pointing-hand cursor；只有中间消息文本区域 hover 300ms 后显示最多 4,000 字符的完整消息 popover，Enter/编辑/删除按钮区域不会触发预览；卡片保持弹性入队/出队动画；Composer 始终保留在固定 overlay 层级：terminal shell 一次性预留 dock/Queue 的最终高度，使 PTY/grid 只 resize 一次；dock 与分屏一样立即展开/收起，不配置移动或渐显动画，也不再等待 0.34 秒的 resize deferral；Queue 保留 compositor-friendly spring，不再逐帧动画 terminal layout。card reorder 使用独立 queue spring，避免长 scrollback 下反复 resize terminal 造成输入框展开/收起卡顿。输入正文与 Placeholder 优先解析 terminal family 的 Regular face 和实际 point size，字体不可用才回退 regular system monospaced；中文 fallback 显式使用 Regular，正文/caret 复用 terminal foreground，额外 line spacing 为 1pt，不强制 bold 或系统 label white。Placeholder 由 owning `NSTextView` 使用与正文一致的字体绘制。实现不能把 `textContainerOrigin` 当作真实 caret/glyph 起点：TextKit 还会应用 `lineFragmentPadding`，且现代 AppKit 的 caret 路径不会可靠调用 `drawInsertionPoint` override。Composer 因此不再修改 caret，而在真实 window/first-responder 状态下通过 `firstRect(forCharacterRange:)` 取得系统 caret rect，将 screen→window→editor 坐标转换后，从 `caretRect.maxX + 1 device pixel` 绘制 Placeholder；无 window 时才回退到 `textContainerOrigin + lineFragmentPadding`。marked text 一开始即隐藏。测试必须创建真实 `NSWindow`、first responder 和 text container，并断言 Placeholder 位于转换后的 caret rect 右侧；纯算术 offset 测试不能证明 AppKit 实际渲染路径。底部 Send、Queue（排队）、Cancel、Pin、History 都是可点击按钮，统一 12pt system 文案、8pt 快捷键符号（Pin/History 为 10pt）、6pt 图文间距、4pt 按钮间距及 hover/pressed 高亮；Pin 位于 History 左侧，两者只显示图标，help/accessibility label 保留说明。完整 padding 矩形都属于点击区域。Pin 仅阻止发送/排队/保存队列编辑后的自动关闭且保留输入焦点，主动 Esc/Cancel/唤出快捷键仍可收起；展开/关闭与固定状态由独立 `QuickInputGlobalPresentation` 在 OMG 进程内共享，既有/新建 Tab 和窗口保持一致且不跨重启保存；显式关闭或未固定时自动关闭全局同步，关闭某 Pane 不改变其他 Tab 的展示偏好，草稿/队列/历史归属与目标仍各自独立；Queue 统计仅显示静态 tray 图标与数字，不再绘制随深度变化的指针。History 面板按最近优先展示已成功提交到终端的内容，提供搜索、发送日期时间、条目分割线及有最大滚动高度的自适应布局；选择记录按 `keyboard.quickInputHistoryInsertionMode` 追加（默认，换行分隔）或覆盖 draft，不自动发送。`⌘⇧H` 唤出/关闭 History，重开恢复上次选择且滚动到该项，选择已过期或不在当前可见/匹配范围时才回退最近记录；鼠标 hover 与 ↑↓ 共用同一选中光标及轻量高亮，hover 直接移动选择但不触发滚动，后续键盘继续从 hover 项操作；鼠标打开同样支持。↑↓ 选择并跟随滚动，Enter 回填。列表态直接输入字符会进入搜索，复用始终挂载的 native input client 保留首字符及 IME；搜索态 Esc 先取消正在组合的 IME，否则退出搜索，再次 Esc 关闭弹窗；关闭/重开保留 query 和搜索模式。输入框的无修饰 ↑↓ 仅在 TextKit 判定的首/末实际显示行启动历史浏览：初次或修改/移动光标后需同方向两次独立按键，repeat 不满足首次确认；进入连续浏览后 repeat 和单次按键都直接切换。最新未发送 draft 与 UTF-16 selection 独立保存，向下越过最新记录恢复该草稿/光标；仅浏览不覆盖 Pane 存储草稿，修改回填文本才提升为最新 draft，原发送历史不可变。IME、修饰键、选区和队列编辑不接管。独立 fork-owned `QuickInputHistoryStore` 用 Surface UUID 和 tab-session UUID 归属记录，默认可见范围为 Tab，可在 Settings > Editor > Quick Input 切换 Pane 或全局；已有显式偏好不覆盖；Pane move 会重新关联目标 Tab，正常 session restoration 恢复原 UUID 后可找回历史，新建 Pane 不继承旧身份。默认历史保存 7 天并在退出后保留，可配置 1–365 天及退出不保留；关闭持久化会删除磁盘副本但保留当前进程内记录。关闭 Pane 的历史直到过期仍可从全局范围访问。历史在 channel-specific Application Support 的 `quick-input-history/history.json` 明文保存，以 0700 目录、0600 临时文件及原子替换写入；私有 serial queue 避免主线程编码/写盘，正常退出会 drain pending writes。过期记录立刻从查询中排除，启动、写入、设置变化、打开面板、每分钟及正常退出时清理；App 未运行时磁盘清理需等下次启动。每 Pane 最多 50 条，全局最多 1,000 条、8 MiB 文本；单条不超过 1 MiB。同 Pane 连续重复发送更新日期而不新增条目。直接发送、手动及自动出队发送共用成功提交记录入口，未发送的草稿、仅入队或失败提交不记入历史；提交成功不代表 Agent 已接受或执行。清空全部历史需确认且不影响草稿/队列；存储失败会提示但不阻止发送。队列仍不跨 Pane 关闭或 App 重启持久化，进程内 Pane move 会迁移队列状态。

自动出队只接受 owning Pane 新的归一化 `done` transition，不把 `needsAttention`、普通 shell prompt 或 idle 当作完成。每次完成最多发送一条，使下一条等待下一次完成。入队动作是用户对延迟 PTY 写的显式确认；实际写入前仍须重新校验 Surface 存在、1 MiB 上限和 Secure Input，失败时消息保留在队列中。

后续若改为插件直接调用模型 API，必须先选择并实现以下一种凭据方案：

- 独立、受信任且签名的 HTTP/credential broker 持有 Keychain 密钥，插件只调用受限模型 API；或
- 插件本身被定义为受信任组件并可读取专属 Keychain item，同时明确放弃“插件不可见密钥”的约束。

任意插件直接发模型请求却永远看不到所用 bearer key 在进程安全模型上不可实现。

### 6.4 SSH Pane 与 OMG CLI

每个 split 都拥有独立 PTY 和独立 SSH child，不能共享另一个 Pane 的 OpenSSH 进程。SSH Pane 的“复用”定义为复用原始 launch descriptor，而不是复制 resolved IP 或向终端模拟键盘输入。

`omg +ssh` 在最终 OpenSSH child 存活期间保存 owner-only、短生命周期的 exact argv descriptor。源 Pane 执行 split 时，`TerminalController` 以当前 connection ID 读取 descriptor，并通过 `SurfaceConfiguration.command` 启动新的 `omg +ssh`；ready remote cwd 作为独立、shell-quoted wrapper option 传入，使新的 Fish/bash/zsh session 从相同目录开始。因此 `ssh cloud` 继续由 OpenSSH 读取 alias、ProxyJump 和 IdentityFile；`ssh -J jump user@host` 则原样重放参数。child 结束后 descriptor 删除，超过 24 小时的残留 descriptor 拒绝使用。Ghostty 以 `/bin/sh -c` 执行 surface `command`，因此 SSH split 会在 replay 命令后追加 `exec <登录 shell>`：当远端连接因网络等原因断开时，split pane 回到一个可交互 shell 而不是随连接一起退出，行为与手动在该 pane 里执行 SSH 一致；shell integration 通过跨 `exec` 保留的环境变量继续生效。

OMG 不另造第二个 CLI binary。现有 app executable `omg` 是统一 CLI 入口，Ghostty upstream actions 继续使用 `+ssh` 等兼容形式。后续面向用户的 `omg pane split`、`omg config get/set` 应建立在经过认证的 app IPC 上；在此之前，SSH split replay 是宿主内部 launch handoff，不是可由插件调用的 Terminal Control API。

剪贴板粘贴在没有文本/文件内容但包含图片时，会先把图片写成 `NSTemporaryDirectory()/omg-paste/omg-paste-<uuid>.png`；本地 Pane 把 shell-escaped 本机绝对路径作为文本粘贴。ready SSH Pane 则由 Host 使用该 Pane 保存的 exact OpenSSH destination 启动独立 `/usr/bin/sftp`，把 PNG 上传为远端 `/tmp/omg-paste-<uuid>.png`、强制 mode 0600，并仅在上传成功后粘贴远端 shell-escaped 路径；失败时保留原有本机路径回退，QuickInput 同时显示失败状态。普通 terminal paste 与 QuickInput 共用这条解析路径，不向插件开放 filesystem/network/clipboard 能力。独立 SFTP 会复用用户的 OpenSSH config、agent、ProxyJump 等配置，但不共享当前 Pane 的 TCP connection。局部目录强制 mode 0700、PNG 强制 mode 0600，并拒绝 symlink/非目录重定向；每次写入只清理超过 7 天的 regular PNG 文件。有文本/文件内容时行为不变，不会触发图片回退。

## 7. 权限模型

首版能力：

- `terminalEvents`
- `sessionStatus`
- `sidebarModel`
- `inspectorPane`
- `quickInput`
- `terminalControl`
- `rawTerminalOutput`（实验，默认拒绝）

能力由 manifest 声明、宿主静态 allowlist 和握手结果三者取交集。插件不能在运行期自行扩大权限。高风险能力升级需要重新确认并重启插件。

首版官方插件仍按最小权限授权。官方身份不是授予全部能力的理由。

## 8. 宿主边界与上游同步策略

以下原则是 OMG 的长期架构约束：

1. 继续使用 Ghostty 完整 macOS App 作为宿主，复用其 renderer、PTY、输入、IME、accessibility、窗口、Tab、Split、恢复与平台集成。
2. OMG 功能及其业务逻辑放入 fork-owned 文件；新代码优先位于 `macos/Sources/Features` 下的 OMG 模块和对应测试目录。
3. Ghostty 上游文件只保留小型 adapter、registration point 或上层缺失能力所必需的最小接入改动，不在其中扩散 OMG 业务逻辑。
4. 对 `TerminalController`、`AppDelegate`、`TerminalView` 等上游核心类型的修改应逐步压缩为协议边界、extension 或集中式 adapter，使 OMG 模块不直接依赖更多宿主内部实现。
5. 定期同步 `upstream`，小批量解决冲突并运行相关协议测试、macOS 构建及生命周期测试，避免长期积累一次性大合并。

OMG 基本不基于内部 `libghostty-internal` 或尚未稳定的 `libghostty-vt` 重写独立 App。只有 Ghostty 提供稳定、公开且覆盖完整 macOS embedder 能力的 API，并经过单独迁移评审后，才重新考虑独立宿主。首发仍不修改 renderer、不访问私有 tab view、不引入 WKWebView；只有实现上层事件确实缺少可靠接入点时才修改 Zig/C 边界，并为新增 C API 增加 Zig 测试。

## 9. 实施阶段与退出条件

### 阶段 0：协议与宿主底座

交付：版本化 wire contract、帧编解码、manifest/能力校验、每插件进程监管、私有 socket、握手和有界队列。

退出条件：拆包/粘包/超限/畸形消息测试通过；错误插件无法阻塞 UI；断开后资源和 lease 被清理。

### 阶段 1：状态提醒端到端

交付：session 事件桥、状态 lease/store、原生标题组合、官方状态插件。

退出条件：session 创建/关闭、插件崩溃、OSC 进度、PID 变化和 tab/split 聚焦切换均无陈旧状态；无外部插件时无额外子进程，内建 Agent Status 只保留 bounded foreground-PID 采样，PID 不变不得执行 `ps`。

### 阶段 2：Tab Layout

交付：默认启用以 AppKit tab group 为数据源的 vertical presentation，并保留 Ghostty 原生 horizontal tabs 作为显式可选 layout。

退出条件：两种 orientation 的新建、关闭、选择、重排、恢复和数字快捷键与 `NSWindowTabGroup` 一致；Vertical tab bar 的显隐/宽度不重建 surface、改变 tab 顺序或在切换 tab 时改变 terminal rows/columns。

### 统一远端 OMG 入口

`omg +ssh` 的 bootstrap 下发统一的 Python 3 远端命令到 `~/.local/share/oh-my-ghostty/remote/omg`。入口按需执行，不增加常驻 daemon；初始 protocol v1 管理会话启动/退出和 Quick Input 草稿导入。Bash/Zsh/Fish 在用户启动配置之后设置当前会话的 `VISUAL`/`EDITOR`，普通 editor 调用仍委托用户原有 editor。Host 使用保存的 exact SSH connection 创建短时请求，绑定 SSH context ID、request UUID 和远端 TTY，确认就绪后才发送 Agent 的外部编辑快捷键；草稿经 SSH 返回，限制为 1 MiB UTF-8 且拒绝 NUL，Agent 原文件不修改。旧 Agent 需重启或恢复会话才能继承 editor 入口。正常退出清除会话文件，异常退出的遗留目录在后续启动时按七天期限清理。

`SSHSessionTransport.run` 也把文件、Git、inventory、Hook 的既有辅助 shell 任务路由到该入口的 `exec` 子命令，保留各自协议、stdin、超时和输出上限；SFTP subsystem 继续使用 OpenSSH 原生 transport。未安装远端入口的普通 SSH 主机仍执行原有任务路径。具体业务脚本继续由各模块维护，统一的是远端执行入口与会话管理。普通 SSH 或未准备好的会话保持安全回退，不触发 editor 快捷键。

### 阶段 3：QuickInput 与 Pi CLI

交付：原生 QuickInput、逐次确认、审计、官方 Pi CLI 插件/适配器。

退出条件：取消、目标消失、secure input、插件崩溃和大输入均采取拒绝优先策略；未经确认没有 PTY 字节写入。

### 阶段 4：凭据 broker（按需）

仅在需要插件直连模型服务时开始。完成前不把 API key 交给普通插件进程。

### 阶段 5：第三方与可选 WebView

先完成系统沙箱、签名、安装/升级/撤销和权限 UI。声明式 API 连续两个版本仍不能覆盖主要第三方 UI，或头部插件因表达力受限无法迁移时，才评估 WebView 后端。

## 10. 当前不做

- 私有 `NSTabButton` 图标或旋转动画。
- 原始输出稳定 API。
- 任意第三方可执行插件。
- 直接向 terminal parser 注入插件响应。
- 富文本 agent blocks。
- WebView 容器和前端运行时。

本文是首批实现的架构基线。改变安全边界、session 语义、终端写确认规则或首批渲染技术时，需要更新本文并记录原因。

## 11. 实施状态

截至 2026-08-21 已完成：

- v1 wire contract、长度帧编解码和单帧上限。
- 官方插件 manifest/nonce/版本/能力授权规则。
- session 状态消息路由、ACK、所有权、revision、TTL、断线和 session 删除清理。
- 状态到原生 tab/window 标题的组合链路。
- `macos-tab-layout = horizontal|vertical` orientation 配置，默认 vertical；Horizontal 继续使用 Ghostty 原实现。
- 两种 presentation 与 `NSWindowTabGroup.windows` 共享 tab model、lifecycle、title 和 `⌘1…⌘9` shortcut 解析。
- Vertical window 在 `addTitlebarAccessoryViewController` 入口拒绝 native tab accessory，使横向 strip 从不进入窗口层级；不使用异步或延迟隐藏。
- Vertical tab bar 直接使用聚焦 terminal 的实际背景色，hover/active 仅由共享前景语义低透明度叠层派生，自动适配配置主题和 OSC 动态背景。
- `GhosttyTabPresentation`、`GhosttyTabStyle` 和 `GhosttyTabIconProviding`；默认 icon provider 可被插件 metadata provider 覆盖。
- `NSWindowTabGroup` 关联的 window layout state：显隐、176-480pt 宽度和 last-width 持久化；新 window 从 last width 初始化，同组 tab 不拥有独立宽度。
- 1pt divider + 8pt native `NSView` mouse tracking/cursor rect；selected tab 使用 frame-boundary 合并后的 live width（同一 runloop turn 内的 drag 事件合并为一次 apply，无固定 16ms timer 延迟），隐藏 tabs 保持 committed width；mouseUp 立即同步最终 width 到整个 tab group，settings/UserDefaults 写入延迟 200ms 并可被下一次拖动取消，不阻塞指针抬起。
- `SurfaceScrollView` 只在 framebuffer size 实际改变时调用 `ghostty_surface_set_size`，避免 duplicate layout pass 重复触发 renderer resize；连续 resize 不 remove/add view，也不重建 Surface。
- Host scrollback 默认启用 mouse smooth scrolling：precision trackpad 直接消费像素 delta 和系统 momentum，离散滚轮使用带摩擦 coast；renderer 保留连续 row position、额外绘制一行并以统一 shader `content_offset` 移动文字/背景/图片，跨整行时才推进 terminal viewport。alternate screen、mouse reporting 和 live PTY output 继续保持离散语义；空闲时不运行 animation timer。`smooth-scroll` 可分别控制 `mouse`、`key` 和 `jump`，默认仅启用 `mouse`。
- titlebar accessory 根据 close/minimize/zoom button 的实际 window-space centerY 布局 Sidebar Toggle 与 New Tab controls，不依赖固定 y offset，适配 fullscreen 和 display scale 变化。标题栏保持统一 chrome，不再复制左右内容区 divider；divider 只存在于 SwiftUI content shell 的 8pt resize boundary。Right Inspector 的 `sidebar.right` toggle 永久占据最右侧固定 44pt slot，结构上独立于 Plugin pane/overflow 区域，不随展开宽度移动，也不会折叠进 `…`；只有 Files 等 Plugin 项可以进入 overflow menu。共享 AppKit/SwiftUI titlebar bridge 负责纵向对齐，并发布首次窗口可靠挂载所需的最小 intrinsic width；每次展开/收起都同步更新 host Auto Layout constraint、accessory intrinsic width 与实际 AppKit frame，确保 Plugin 区获得完整展开宽度而不会溢出仍停留在 44pt 的旧 frame。Host 在更新 AppKit constraint 的同时显式发布 titlebar presentation width/visibility，SwiftUI Plugin controls 不再依赖 reopen 后可能停留在旧值的 `GeometryReader` proposal；左右 Sidebar 与 Quick Input 一样立即开合，取消 0.18s slide/fade 和延迟 collapse；同一轮同步更新 pane width、accessory width 和 controls visibility，收起时立即缩回 44pt toggle。Inspector 仍保留首次打开后已挂载的 native pane deck，隐藏时不接收点击或出现在 accessibility navigation，不改变 provider appeared/disappeared 语义。
- Vertical organization menu 支持 No Grouping、By Project、By Date、Created Time 与 Recently Used；grouping/order 存在 `NSWindowTabGroup` 共享 layout state，last-used mode 通过 UserDefaults 持久化，collapsed group 只属于当前 window state。
- By Project 从 cwd 向上查找 `.git` repository root 并按 cwd 缓存结果，非 Git cwd 回退到目录名；group presentation 使用可扩展的 title/icon/id 模型，不执行 `git` 子进程。
- `NSWindowTabGroup.windows` 是唯一 canonical tab order。Ghostty `move_tab`、Vertical drag、Horizontal native UI、`goto_tab` 和 shortcut labels 都消费同一顺序；Created/Recently Used 会先重排 canonical windows，开始手动 drag 时 ordering 切换为 Manual。
- Vertical drag 使用稳定 tab session UUID payload 和 host-owned DropDelegate；同一 derived group 内允许 reorder，跨 project/date group 拒绝，drop 不移动 Surface/PTY ownership。
- 每个 `TerminalController` 拥有可恢复的 `tabSessionID`，新 PTY 注入 `OH_MY_GHOSTTY_SESSION`；cwd/title 只用于 project presentation，不用于 status correlation。
- 尺寸 HUD 根因是旧 tab presentation 在切换时改变 content frame（per-tab width 与 native accessory 进入/退出布局），进而改变 terminal rows/columns；修复后快速切换前后所有 surface dimensions 保持不变，不隐藏 HUD 本身。
- 将 OSC 9;4 progress 生命周期映射为 running/waiting/completed/failed wire 状态，再归一为 host-owned idle/working/done/needsAttention/error activity model。
- Release 使用 `~/.config/oh-my-ghostty/settings.json`，Debug 使用 `~/.config/oh-my-ghostty-dev/settings.json`；Dev 首次单向复制 stable 设置，随后 settings、appearance overlay、plugin package/data、SSH replay、UserDefaults 与 restoration 全部按 channel 隔离。typed settings model、machine-readable schema 与原生 Settings Window 保持一致；Ghostty config 仅作为未显式设置项的 fallback。
- Host-owned tab icon/metadata/activity presentation contracts；plugin 只能贡献已验证的数据，不能访问 SwiftUI/AppKit/PTY/renderer 对象。
- Core-owned `InspectorRegistry` / `RightInspectorHost`；Horizontal/Vertical 共用 `NSWindowTabGroup` layout state，`InspectorPresentationStore` 持久化 UI state，titlebar pane switch 按宽度稳定收纳到 `…` menu 并预留 Git/SSH 扩展；Plugin Inspector 仅贡献经过 owner validation 的 typed snapshot/action，`builtin.files` 按稳定 tab ID 跟随 live cwd，node-scoped 异步合并 subtree，保留 scroll/selection/expanded identity，并提供递归 tree 与 type-aware icons。
- 修复 AppKit appearance KVO 自激：effective appearance observer 不再反写 app/window appearance，Debug idle CPU 从 83–93% 恢复至约 0.5–1.0%。
- Ghostty baseline + OMG Appearance overlay resolution；theme/font/size/opacity/blur/cursor 通过 Ghostty live config update 应用，Reset 只移除 OMG override，不改写用户 Ghostty config。
- Vertical Tabs 和 Right Inspector 使用 renderer-derived background color/opacity；移除 terminal content 上方的 opaque SwiftUI fill，保持 glyph/cursor/icon opaque 并恢复 upstream transparency/blur semantics。
- QuickInput resizable bottom dock、每 Surface 内存 FIFO、归一化 `done` 单条出队、Secure Input/目标/大小重校验，以及 Settings 可录制快捷键和持久化高度；dock 参与真实 shell layout，使缩小后的 terminal 行可通过正常 scrollback 访问，Queue 使用不遮挡 terminal 的底部横向 lane、从左到右卡片和 spring transitions。shell 立即预留最终 accessory 高度，dock 与左右 Sidebar 立即开合，只有 Queue 在 overlay 中保留 presentation animation。左/右/底三个 resize boundary 统一为 1pt layout divider + 向内容内覆盖的 8pt hit target，消除透明栏。Sidebar、Inspector、QuickInput 高度和横向/纵向 split 拖动采用 Otty 风格的 live resize：terminal model/renderer 在 IO 线程以短周期持续 reflow，AppKit/SwiftUI chrome 与内容同步跟随；child PTY 尺寸发布与视觉 reflow 解耦，连续移动时不产生 SIGWINCH/output redraw storm，网格稳定 50ms 或交互结束时才发布当前尺寸，mouseUp 不再重复 terminal reflow；视觉专用 resize 不启用 Ghostty 的 OSC 133 `prompt_redraw` 清除，因为此时 child 尚未收到尺寸信号，必须保留 Starship/powerline prompt cells 直至 shell 在已提交尺寸上自行重绘。Settings > Terminal 的 `terminal.resizeRendering` 默认使用 `onRelease`，在交互期间保持 terminal 内容为旧尺寸并只在 mouseUp/transition-end 执行一次最终 reflow；也可选择 `duringDrag` 使用上述连续 live reflow。
- 原生 Editor 的语言识别按“文件名/扩展名 → shebang/modeline → 内容结构”三级决定，保证 `flake.lock`、`build.zig.zon.json` 这类真实数据文件不在 plain text 里丢掉着色。已知别名按 Zed 的 `path_suffixes` 处理（JSON: `json`、`flake.lock`、`deno.lock`、`.prettierrc`；YAML: `yml`、`yaml`、`pixi.lock`、`clang-format`、`clangd`）；不泛化 `.lock`，避免把任意二进制锁文件当 JSON。仅当上面两级都没有结果时才做内容识别，且必须同时满足格式特征和 tree-sitter 结构节点（JSON 顶层 `object`/`array`、YAML 至少两个 mapping/sequence、TOML 至少一个 `pair`/`table`），源码类语言还需解析无错。普通散文、单个带冒号的句子和超过 512KB 的未识别文件保持 plain text。缓存为 plain text 的结果会被重新判定，以覆盖编辑器先于文档内容挂载的情况。
- Plugin capability audit 明确：codec/authorization/status store 是已测试组件，但 discovery、socket、peer credential、进程监管和真实 Agent adapter 尚未完成。

下一实施块：

- 私有运行目录、Unix socket server、peer UID/PID 校验和每插件进程监管。
- `ghostty +oh-my-config` / status CLI，共用 settings descriptor registry 与 `OH_MY_GHOSTTY_SESSION`。
- Terminal Event bridge 与有界发送队列。
- 将官方 Agent reducer 放入受监管子进程，并增加 agent 身份识别适配器。
- 多窗口 tab group 的恢复、拖出/合并与重排专项验证。

在上述下一实施块完成前，Agent reducer 已可测试但尚未作为独立插件进程自动运行。

Vertical Tabs 验证截图：

- `docs/images/horizontal-tabs-native.png`：显式 Horizontal 使用 Ghostty 原生 tab UI。
- `docs/images/vertical-tabs-hover-active.png`：Vertical 8 tabs，⌘8 active、⌘3 hover。
- `docs/images/vertical-tabs-hidden-toggle.png`：Sidebar 隐藏后 titlebar toggle 仍可见。
- `docs/images/vertical-tabs-light-theme.png`：Ghostty 浅色背景下 Sidebar 与 terminal 融合。
- `docs/images/vertical-tabs-groups.png`：By Project 的 compact group header、collapse state 与 canonical-index shortcuts。
- `docs/images/vertical-tabs-reordered.png`：Manual reorder 后 A,D,B,C 的 position-based shortcuts，active C identity 保持。
- `docs/images/vertical-tabs-groups-status.png`：Mock agent 的 plugin icon 与 host-owned working indicator。
- `docs/images/settings-tabs.png`：原生 Settings Window 的七个 category 与 typed Tabs controls。
- `docs/images/settings-appearance.png`：Dark Appearance 下的 Ghostty inherited values、OMG optional override、effective source 与 Reset to Ghostty。
- `docs/images/settings-appearance-light.png`：相同原生 Settings hierarchy 的 explicit Light Appearance 验证。
- `docs/images/appearance-transparency-vertical.png`：Vertical Sidebar 与 terminal content 在相同 58% Ghostty background alpha 下保持一致。
- `docs/images/appearance-transparency-horizontal.png`：相同 opacity/blur config 下的 Ghostty 原生 Horizontal 对照。
- `docs/images/right-inspector-files.png`：Core-owned Right Inspector Host 挂载 owner-scoped `builtin.files` typed content。

### Inactive terminal GPU resources

An occluded Metal terminal keeps its most recent frame for immediate display,
but releases the other swap-chain frames after in-flight GPU work completes.
Their textures, cell buffers and render targets are recreated lazily when the
terminal draws again. This does not discard scrollback, restart the PTY, alter
terminal dimensions or reduce the visible surface's triple buffering. The
fork-owned implementation is `src/renderer/omg_memory.zig`; the generic renderer
only calls it at the existing visibility boundary. OpenGL is unchanged.

Synchronous layer-display requests also honor terminal visibility. Background
layout invalidations must not recreate the spare GPU frames after an occlusion
trim; the last presented image remains available until visibility resumes.

Vertical-tab mouse actions resolve the clicked controller's live AppKit window
and native tab group. Deferred sidebar controller arrays are presentation data,
not a gate for accepting a click. Selection explicitly orders the target window
front, matching keyboard tab selection even when key status or group projection
has not yet settled.

Application-local event monitors with weak owners fail open after owner teardown:
they return the original event, not `nil`. A live owner's explicit `nil` still
means the event was handled. This preserves mouse presses for tab rows and
modal confirmation buttons even while stale monitor callbacks are retiring.

Vertical-tab drag cleanup accepts the actual `NSEvent` and branches on its type
before reading keyboard-only fields. Reading `keyCode` from a mouse release
raises an AppKit exception, interrupts input dispatch, and leaves the source
monitor installed. Local and global release handlers share the same policy;
Escape or the next mouse press also retires a cancelled drag without consuming
the event. Cleanup runs after the destination drop callback and is scoped to the
drag generation, so an old queued release cannot clear a new drag. Removing the
sidebar finishes its source monitor. Regression coverage dispatches real AppKit
mouse events through `NSApplication`: real SwiftUI drags released in the source
row, rejected by the header, or committed to a different row, followed by 64 tab
clicks. Separate tests cover Escape, generation isolation, and modal buttons
after source cleanup; numeric policy arguments alone do not exercise this contract.
