# OMG 原生 Session Runtime 设计提案

状态：内部实现与验收契约；`session-runtime/` 已提供多会话 daemon、SSH relay 和原生 snapshot backend。2026-11-01 的重构增加稳定 relay、自动重连、并列本地/SSH tabs，并继续完善默认本地持久会话、独立 holder 与原生会话库。验证记录见 `docs/plans/ssh-session-runtime-2026-11-01.md` 和 `docs/plans/local-session-runtime-completion-2026-11-01.md`。公开发布仍需真实 SSH、Agent 与跨平台验收。目标：保留完整 Ghostty macOS host，本地与远程共享会话模型和协议，不依赖 tmux 或嵌套终端代理 PTY。

## 源码依据

本次核查的 upstream revision：

- Termio：`dba6395a674aa63da1ac25089c2855ed7cbf3b68`
- Kero：`cd340bda44bdca98a4e82195ae7fd392dc543f73`
- Herdr App：`07ba77e87a8d809ef5a486e09e4ac44cade2c39a`
- Herdr Core：`572fdf5c82ef2de5d725b0161f1bdc2ebfe3fee0`

Termio 的 `termiod/src/session.rs` 采用独立 session actor、原始字节分发、SnapshotPending 屏障和有界 VT sidecar；`termiod/vt/src/lib.rs` 包含原生快照和 ANSI 恢复路径。`termiod/ARCHITECTURE.md` 仍有 snapshot 为 later 的旧描述，应以对应源码为准。VT crate 使用其 fork 的 libghostty Rust bindings，固定 Ghostty revision；不能假定可直接连接 OMG 当前 ABI。

Kero 的 `internal/daemon/pty_unix.go` 由 daemon 持有 PTY；`internal/daemon/session.go` 使用服务端 terminal 与每个 attachment 的 `terminal.Mirror`，通过 `Frame()` 同步。慢客户端队列满时结束 attachment，重新 attach 获取首帧。持久化 history 是新 shell 上方的历史恢复，不能等同于 daemon 重启后的原进程存活。其终端查询由服务端回答，客户端只处理特定的剪贴板请求。

Herdr 的本地窗口与远端访问复用 core、稳定 terminal address 和会话 inventory；独立 holder 持有 PTY，core 重启后重新 adopt。关闭窗口/退出 detach，显式关闭 tab/pane 才结束会话。本轮借鉴其所有权划分和原生入口，继续复用 Ghostty 的启动准备、VT 与渲染；没有引入 GPUI 或第二套终端 UI。Herdr 两个仓库使用 Apache-2.0，移植源码必须保留适用的许可证与 notices。

这些项目可以作为生命周期和同步机制的参考，不应将其数据路径混为一谈，也不承诺直接兼容协议。

## 目标结构

```text
Ghostty macOS host
  ├─ OMG SessionCoordinator / HostConnection
  └─ Ghostty Termio: OmgSession backend
       └─ 每 host/account 一条逻辑连接，多 session stream
            ├─ SSH pipes → omgd bridge → Unix socket
            └─ Unix socket（本地后台会话）
                          ↓
                 omgd
                   ├─ Session registry / attach ownership
                   ├─ Session actor → PTY → shell / agent
                   └─ authoritative terminal state / snapshots
```

SSH 子进程使用普通管道与 `ssh -T`，它不持有 Agent PTY。Bridge 仅转发协议，stdout 专供协议、stderr 专供诊断。Daemon 不绑定 SSH 生命周期。Session ID 不依赖 GUI window、pane 或连接。

默认交付远程 Linux；内部从 Unix socket 验证。Rust 是 daemon/bridge 的推荐实现语言，服务端 VT 优先复用与 OMG 同 revision 的 Ghostty 核心，通过受控 FFI 接入；这是服务端解析器复用，不是用 libghostty 重写 macOS App。首个技术验证必须确认 snapshot、跨平台构建和 ABI 成本，再冻结依赖结构。

## OMG 接入

`src/termio/backend.zig` 的 `exec` 和 fork-owned `OmgSession` backend 共用完整 Ghostty host；backend union、surface 初始化、配置/API 边界只做适配。保留原有键盘、IME、鼠标、选区、渲染路径。

`macos/Sources/Features/Terminal/SSHRecovery.swift` 为普通 system SSH 保留新 PTY/重执行命令的恢复路径；不把这条路径当作 durable session attach。既有普通本地 session 继续 Exec；新本地窗口/tab/split 默认使用 runtime，可用 `sessions.localRuntimeEnabled` 为后续新终端关闭。新本地进程由独立 holder 持有，SSH 由远端 host 的 session thread 持有；两者共享协议和 snapshot backend。Ghostty 通过原有 Exec 准备路径解析本地 argv/env/cwd/shell integration，传递首次尺寸与初始输入，但不额外创建 GUI PTY。launch 仅存内存，首次创建后释放，重连不得重放；SSH 拒绝该本地 payload。

SSH handoff 使用当前窗口/工作区的原生 sibling tab，保留发起连接的本地 Surface 和 shell；helper 得到接受确认后立即返回本地 prompt。连接掉线只更新 pane 状态，relay 保持客户端 socket，自动重新建立传输并 attach 原 UUID。snapshot 恢复和 writer 确认完成前不接受输入；连接 generation 拒绝旧输入、resize、writer 与 snapshot ACK。失败信息走原生状态呈现，不写入终端输出污染保留的画面。用户手动重试只唤醒既有 relay，不替换 Surface 或中断健康 sibling panes。

重点审计 surface deinit、关闭 tab、退出 App、进程退出展示和 restorable state。关闭窗口或退出 App 是 Detach；用户显式关闭 tab/pane 则持久化 CloseSession。Window 菜单和设置页均可打开原生 Session Library，按 endpoint 查询、聚焦或 attach 原 UUID，以及确认 End；只读查询不延长脱离视图后的 TTL。元数据记录 host/account 身份、session ID 和 daemon instance epoch。重连找不到 session 时显示明确状态，不自动创建同名进程冒充恢复。

## 协议与生命周期

- Hello 协商协议、VT snapshot schema、能力和最大帧大小。
- Create 使用 request ID / 幂等键，防止网络重试重复启动 Agent。
- List / Attach / Detach / Input / Resize / CloseSession / ClaimWriter。
- Exit / Output / Snapshot / Gap / WriterChanged / SessionGone 事件。
- 一个连接复用多个 stream；每流有界字节预算、公平发送和控制消息优先级。不可只限制消息个数。
- 会话输出序号、attachment generation、daemon epoch 各自独立；重连拒绝旧 generation 的写入。输入不盲目自动重传，避免重复执行命令。
- 单 writer、多 observer；输入和 resize 都验证 writer generation。无人连接保留最后有效尺寸，不停止读取 PTY。
- CloseSession 先在客户端持久化，再由远端持久化 UUID 关闭标记；后台重试直至远端确认。关闭是整个 pane UUID 的永久撤销，禁止后续自动 resume 或重建，因此不会因 generation 更新漏掉已经关闭的 pane。仍保留原 attached `K` 供旧版本使用，但旧 host 不支持确认时请求保持待确认。
- Linux systemd/cgroup v2 监管模式中，每 Session 一个 cgroup、仍由同一个 omgd 的线程持有 PTY。子进程在 exec 前加入 cgroup，普通 setsid/nohup/double-fork 不改变归属。退出时清理该组并检查 populated=0；daemon SIGKILL 则由 systemd KillMode=control-group 清理整个服务。macOS 或无监管能力的主机仍只有进程组清理保证。
- SSH 配置负责路由；host ID 加远端账号/daemon namespace 负责身份。克隆机器可能复制 host ID，不能替代 SSH 主机认证。

## VT 状态恢复：首要技术验证

快照必须覆盖主屏、备用屏、scrollback、光标/保存光标、属性、终端模式、tab stops、字符集、鼠标和键盘协议，以及 parser continuation。任意输出块结尾可能落在 UTF-8、CSI、OSC 或图像控制序列中间。仅保存可见 cell 不足以继续处理未来字节。

采用严格的 snapshot → live 屏障：

1. 在 session 的有序事件流内确定 N，快照代表已解析至 N 的状态，并同时建立后续订阅。
2. 原子应用 snapshot，避免与 renderer 或旧 attachment 输出竞争。
3. ACK 带 snapshot ID 和 attachment generation；仅随后播放 N 之后的输出。
4. 接收队列溢出发 Gap/中断该 attachment，并重新同步；绝不静默丢字节。
5. Resize 与输出、snapshot 在同一有序域内。连接恢复过程中的 resize 不越过屏障。

N 应定义为输出字节偏移或明确的有序事件位置，不能含糊地只用网络包编号。若 VT 解析异步落后，必须等待解析水位到达 N，不能用 PTY 已读取位置标记旧快照。

原生 snapshot 格式必须版本化、限制大小并验证输入；不直接复制内存结构。当前仓库已有 `src/terminal/snapshot/`，但完整状态覆盖、恢复到现有 surface 的线程边界及跨版本行为仍需实证。ANSI 回放不作为绕过完整状态验证的退路。

## 终端响应归属

推荐由 daemon 的 authoritative VT 回答 DA/DSR、终端能力等协议查询，以便没有 GUI 时 Agent 仍能正常工作。GUI 的同类自动响应必须被抑制，并将真实用户输入与终端自动回复分成不同来源。

剪贴板、通知等本机副作用通过独立、受限的事件处理；snapshot 回放不能重复触发 OSC 52、通知或其他历史副作用。终端对外宣告的能力取决于 daemon 与客户端共同支持的能力，不能因为 GUI 支持就无条件宣告。

Termio 的 VT sidecar 注释说明它不注册 `on_pty_write`，主要由 writer surface 回答，并有 SupportQuery 特殊路径。该策略不能直接证明无人连接时所有查询都能正确完成；本方案对此设独立验收。

## 背压与服务管理

客户端慢不能阻塞 PTY actor；VT 解析器慢则是不同问题。首版优先验证单个有序 authoritative VT 路径，测量持续输出下的吞吐、RSS 和输入延迟。若必须拆 sidecar，需定义解析积压上限及失去同步后的真实恢复办法。不能丢弃解析字节后再从已损坏的状态生成“正确快照”。对于无限输出，不承诺有限内存下永不发生生产者背压。

Unix socket 位于用户私有目录，校验 owner/peer credentials，限制帧、快照和会话配额。远程安装按 OS/arch 检测、原子落盘和版本校验，禁止在 bridge 建连时替换正在持有 PTY 的 daemon。

Linux root 账号使用 systemd 系统级临时服务；普通账号仅在用户管理器可用且已启用 linger 时使用用户临时服务。不会自动开启 linger 或请求提权；不满足条件则明确记录 process-group-only 模式。服务按 runtime directory 隔离，Delegate=yes，KillMode=control-group，Restart=no；下一次连接再启动，避免重复崩溃循环。监管模式启动失败不能偷偷降级绕过监管。未来 macOS launchd 的退出登录语义另行验证。远端 daemon 崩溃和主机重启不保证 PID 不变。本地 broker 重启通过私有控制探针核对 UUID、generation 与 capability 后收编仍存活的 holder，PID/PTY/VT 保持不变；holder 或主机丢失仍必须明确报告 Lost。

远端启动和周期维护把没有 actor 的运行中记录改为 Lost；本地先验证独立 holder，仅在没有可验证 holder 时标记 Lost。失效 socket 按所属 UUID 清理，不按历史 PID 发信号；adoption 探针不 attach，也不刷新 TTL。待关闭请求保存在 App Support 的 session-runtime/pending-closes.json，App 启动及运行中重试；设置页显示未确认数量。空 relay 在 30 秒无客户端后退出，host 仍按存活 actor 和既有空闲策略管理。旧版本 daemon 保持原版本；本地 broker/holder 从 descriptor 固定版本的缓存 helper 启动，不跨版本收编；不支持新关闭能力的旧版本仍有待确认限制。高权限进程主动迁移 cgroup、通过外部服务创建任务不在自动回收保证内。

## 实施顺序与验收

1. 原生 vertical slice：一个 session，通过 Unix socket 驱动现有 Ghostty surface；detach 后持续读取，attach 恢复完整状态；验证查询归属和 parser continuation。通过后冻结 VT 方案。
2. Runtime 协议：多 session、writer、幂等 Create、退出回收、流控、重同步、断线状态机。
3. SSH 产品交付：部署/bridge、主机身份、连接复用、持久化 session reference 和 GUI 重连。
4. 本地产品接入：复用同协议/runtime，增加本地服务管理和迁移入口。

验收矩阵：Codex/Pi/Claude 与普通 shell；GUI 退出、Mac sleep、SSH kill/反复断连后 PID 与 session ID 不变；当前 TUI 和交互正确。覆盖 alternate screen、宽字符/emoji、括号粘贴、鼠标、键盘模式、跨块 escape sequence、频繁 resize、慢 observer、大量输出、输出与 attach 竞态、无人连接时的查询响应，以及 daemon kill 后明确报告会话丢失。

原型已执行真实 PTY 断连重连、PID 保持、原生快照 continuation、无人连接查询响应和 resize 测试；GhosttyKit 与 Debug App 已编译通过。GUI backend 仅通过逐 pane 的连接描述启用，全局实验 socket 与固定主机入口已经删除。桌面视觉验收、真实 Agent 与 Linux/SSH 验收尚未完成。验证细节见 `session-runtime/README.md`。正式实现需要依据 `docs/TESTING.md` 选择相关 Zig/Swift 测试并串行执行；若改动插件 API、生命周期或 Inspector 契约，同时更新插件文档与测试。
