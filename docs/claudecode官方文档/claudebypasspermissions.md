> ## Documentation Index
> Fetch the complete documentation index at: https://code.claude.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 选择权限模式

> 控制 Claude 在编辑文件或运行命令前是否询问。在 CLI 中使用 Shift+Tab 循环切换模式，或在 VS Code、Desktop 和 claude.ai 中使用模式选择器。

当 Claude 想要编辑文件、运行 shell 命令或发出网络请求时，它会暂停并要求您批准该操作。权限模式控制暂停发生的频率。您选择的模式塑造了会话的流程：默认模式让您在操作进行时审查每个操作，而更宽松的模式让 Claude 在更长的不间断时间内工作，然后报告完成情况。为敏感工作选择更多监督，或在您信任方向时选择更少中断。

## 可用模式

每种模式在便利性和监督之间做出不同的权衡。下表显示了在每种模式中 Claude 无需权限提示即可执行的操作。

| 模式                                                         | 无需询问即可运行的操作                                       | 最适合                   |
| :----------------------------------------------------------- | :----------------------------------------------------------- | :----------------------- |
| `default`                                                    | 仅读取                                                       | 入门、敏感工作           |
| [`acceptEdits`](#auto-approve-file-edits-with-acceptedits-mode) | 读取、文件编辑和常见文件系统命令（`mkdir`、`touch`、`mv`、`cp` 等） | 迭代您正在审查的代码     |
| [`plan`](#analyze-before-you-edit-with-plan-mode)            | 仅读取                                                       | 在更改代码库前进行探索   |
| [`auto`](#eliminate-prompts-with-auto-mode)                  | 所有操作，带后台安全检查                                     | 长时间任务、减少提示疲劳 |
| [`dontAsk`](#allow-only-pre-approved-tools-with-dontask-mode) | 仅预先批准的工具                                             | 锁定的 CI 和脚本         |
| [`bypassPermissions`](#skip-all-checks-with-bypasspermissions-mode) | 除受保护路径外的所有操作                                     | 仅隔离容器和 VM          |

无论模式如何，对[受保护路径](#protected-paths)的写入永远不会自动批准，保护仓库状态和 Claude 自己的配置免受意外破坏。

模式设置基线。在顶部分层[权限规则](/zh-CN/permissions#manage-permissions)以在除 `bypassPermissions` 外的任何模式中预先批准或阻止特定工具，`bypassPermissions` 完全跳过权限层。

## 切换权限模式

您可以在会话期间、启动时或作为持久默认设置切换模式。模式通过这些控制设置，而不是通过在聊天中询问 Claude。选择下面的您的界面以查看如何更改它。

<Tabs>
  <Tab title="CLI">
    **在会话期间**：按 `Shift+Tab` 循环切换 `default` → `acceptEdits` → `plan`。当前模式显示在状态栏中。并非每种模式都在默认循环中：

    * `auto`：当您的账户满足 [auto mode 要求](#eliminate-prompts-with-auto-mode)时出现；循环到 auto 会显示一个选择加入提示，直到您接受它，或选择**不，不再询问**以从循环中移除 auto
    * `bypassPermissions`：在您使用 `--permission-mode bypassPermissions`、`--dangerously-skip-permissions` 或 `--allow-dangerously-skip-permissions` 启动后出现；`--allow-` 变体将模式添加到循环中而不激活它
    * `dontAsk`：永远不会出现在循环中；使用 `--permission-mode dontAsk` 设置它
    
    启用的可选模式在 `plan` 之后插入，`bypassPermissions` 优先，`auto` 最后。如果您同时启用了两者，您将在前往 `auto` 的途中循环通过 `bypassPermissions`。
    
    **启动时**：将模式作为标志传递。
    
    ```bash theme={null}
    claude --permission-mode plan
    ```
    
    **作为默认设置**：在[设置](/zh-CN/settings#settings-files)中设置 `defaultMode`。
    
    ```json theme={null}
    {
      "permissions": {
        "defaultMode": "acceptEdits"
      }
    }
    ```
    
    相同的 `--permission-mode` 标志适用于 `-p` [非交互式运行](/zh-CN/headless)。
  </Tab>

  <Tab title="VS Code">
    **在会话期间**：单击提示框底部的模式指示器。

    **作为默认设置**：在 VS Code 设置中设置 `claudeCode.initialPermissionMode`，或使用 Claude Code 扩展设置面板。
    
    模式指示器显示这些标签，映射到每个标签应用的模式：
    
    | UI 标签              | 模式                  |
    | :----------------- | :------------------ |
    | Ask before edits   | `default`           |
    | Edit automatically | `acceptEdits`       |
    | Plan mode          | `plan`              |
    | Auto mode          | `auto`              |
    | Bypass permissions | `bypassPermissions` |
    
    在您在扩展设置中启用**允许危险地跳过权限**后，Auto mode 出现在模式指示器中，但它保持不可用，直到您的账户满足 [auto mode 部分](#eliminate-prompts-with-auto-mode)中列出的每个要求。`claudeCode.initialPermissionMode` 设置不接受 `auto`；要默认以 auto mode 启动，请改为在您的 Claude Code [`settings.json`](/zh-CN/settings#settings-files) 中设置 `defaultMode`。
    
    Bypass permissions 也需要**允许危险地跳过权限**切换才能在模式指示器中出现。
    
    有关扩展特定的详细信息，请参阅 [VS Code 指南](/zh-CN/vs-code)。
  </Tab>

  <Tab title="JetBrains">
    JetBrains 插件在 IDE 终端中运行 Claude Code，因此切换模式的工作方式与 CLI 中相同：按 `Shift+Tab` 循环切换，或在启动时传递 `--permission-mode`。
  </Tab>

  <Tab title="Desktop">
    使用发送按钮旁边的模式选择器。Auto 和 Bypass permissions 仅在您在 Desktop 设置中启用它们后出现。请参阅 [Desktop 指南](/zh-CN/desktop#choose-a-permission-mode)。
  </Tab>

  <Tab title="Web and mobile">
    在 [claude.ai/code](https://claude.ai/code) 或移动应用中使用提示框旁边的模式下拉菜单。权限提示出现在 claude.ai 中以供批准。哪些模式出现取决于会话在哪里运行：

    * **云会话**在 [Claude Code on the web](/zh-CN/claude-code-on-the-web)：Auto accept edits 和 Plan mode。Ask permissions、Auto 和 Bypass permissions 不可用。
    * **[Remote Control](/zh-CN/remote-control) 会话**在您的本地机器上：Ask permissions、Auto accept edits 和 Plan mode。Auto 和 Bypass permissions 不可用。
    
    对于 Remote Control，您也可以在启动主机时设置起始模式：
    
    ```bash theme={null}
    claude remote-control --permission-mode acceptEdits
    ```
  </Tab>
</Tabs>

## 使用 acceptEdits mode 自动批准文件编辑

`acceptEdits` mode 让 Claude 在您的工作目录中创建和编辑文件而无需提示。状态栏显示 `⏵⏵ accept edits on` 当此模式处于活动状态时。

除了文件编辑外，`acceptEdits` mode 自动批准常见的文件系统 Bash 命令：`mkdir`、`touch`、`rm`、`rmdir`、`mv`、`cp` 和 `sed`。这些命令在以安全环境变量（如 `LANG=C` 或 `NO_COLOR=1`）或进程包装器（如 `timeout`、`nice` 或 `nohup`）为前缀时也会自动批准。与文件编辑一样，自动批准仅适用于您的工作目录或 `additionalDirectories` 内的路径。该范围外的路径、对[受保护路径](#protected-paths)的写入和所有其他 Bash 命令仍然会提示。

当您想在编辑器中或通过 `git diff` 之后审查更改而不是逐个批准每个编辑时，使用 `acceptEdits`。从默认模式按 `Shift+Tab` 一次进入它，或直接启动它：

```bash theme={null}
claude --permission-mode acceptEdits
```

## 使用 plan mode 在编辑前进行分析

Plan mode 告诉 Claude 研究并提议更改而不进行更改。Claude 读取文件、运行 shell 命令进行探索，并编写计划，但不编辑您的源代码。权限提示的应用方式与默认模式相同。

通过按 `Shift+Tab` 或在单个提示前加上 `/plan` 进入 plan mode。您也可以从 CLI 以 plan mode 启动：

```bash theme={null}
claude --permission-mode plan
```

再次按 `Shift+Tab` 离开 plan mode 而不批准计划。

当计划准备好时，Claude 呈现它并询问如何继续。从该提示您可以：

* 批准并在 auto mode 中启动
* 批准并接受编辑
* 批准并手动审查每个编辑
* 继续规划并提供反馈
* 使用 [Ultraplan](/zh-CN/ultraplan) 进行基于浏览器的审查进行细化

每个批准选项也提供首先清除规划上下文的选项。

## 使用 auto mode 消除提示

<Note>
  Auto mode 需要 Claude Code v2.1.83 或更高版本。
</Note>

Auto mode 让 Claude 执行而无需权限提示。一个单独的分类器模型在操作运行前审查操作，阻止任何超出您请求范围的操作、针对无法识别的基础设施的操作，或似乎由 Claude 读到的恶意内容驱动的操作。

<Warning>
  Auto mode 是研究预览版。它减少提示但不保证安全。将其用于您信任一般方向的任务，而不是作为敏感操作审查的替代品。
</Warning>

Auto mode 仅在您的账户满足所有这些要求时可用：

* **计划**：Max、Team、Enterprise 或 API。Pro 上不可用。
* **管理员**：在 Team 和 Enterprise 上，管理员必须在 [Claude Code 管理员设置](https://claude.ai/admin-settings/claude-code)中启用它，然后用户才能打开它。管理员也可以通过在[托管设置](/zh-CN/permissions#managed-settings)中将 `permissions.disableAutoMode` 设置为 `"disable"` 来锁定它。
* **模型**：Team、Enterprise 和 API 计划上的 Claude Sonnet 4.6、Opus 4.6 或 Opus 4.7；Max 计划上仅 Claude Opus 4.7。不支持其他模型，包括 Haiku 和 claude-3 模型。
* **提供商**：仅 Anthropic API。在 Bedrock、Vertex 或 Foundry 上不可用。

如果 Claude Code 报告 auto mode 不可用，其中一个要求未满足；这不是暂时中断。一个单独的消息命名一个模型并说 auto mode "cannot determine the safety" 的操作是暂时分类器中断；请参阅[错误参考](/zh-CN/errors#auto-mode-cannot-determine-the-safety-of-an-action)。

### 分类器默认阻止的内容

分类器信任您的工作目录和您的仓库的配置的远程。其他所有内容都被视为外部，直到您[配置受信任的基础设施](/zh-CN/auto-mode-config)。

**默认阻止**：

* 下载和执行代码，如 `curl | bash`
* 向外部端点发送敏感数据
* 生产部署和迁移
* 云存储上的大规模删除
* 授予 IAM 或仓库权限
* 修改共享基础设施
* 不可逆地销毁会话开始前存在的文件
* 强制推送或直接推送到 `main`

**默认允许**：

* 工作目录中的本地文件操作
* 安装在您的锁定文件或清单中声明的依赖项
* 读取 `.env` 并向其匹配的 API 发送凭证
* 只读 HTTP 请求
* 推送到您启动的分支或 Claude 创建的分支

Sandbox 网络访问请求通过分类器路由而不是默认允许。运行 `claude auto-mode defaults` 以查看完整的规则列表。如果常规操作被阻止，管理员可以通过 `autoMode.environment` 设置添加受信任的仓库、桶和服务：请参阅[配置 auto mode](/zh-CN/auto-mode-config)。

### 您在对话中陈述的边界

分类器将您在对话中陈述的边界视为阻止信号。如果您告诉 Claude "don't push" 或 "wait until I review before deploying"，分类器会阻止匹配的操作，即使默认规则会允许它们。边界保持有效，直到您在后续消息中解除它。Claude 自己的判断条件已满足不会解除它。

边界不存储为规则。分类器在每次检查时从记录中重新读取它们，因此如果[上下文压缩](/zh-CN/costs#reduce-token-usage)删除陈述边界的消息，边界可能会丢失。为了硬保证，请改为添加[拒绝规则](/zh-CN/permissions#permission-rule-syntax)。

### 当 auto mode 回退时

每个被拒绝的操作显示通知并出现在 `/permissions` 下的"最近拒绝"选项卡中，您可以按 `r` 以手动批准重试它。

如果分类器在一行中阻止操作 3 次或总共 20 次，auto mode 暂停，Claude Code 恢复提示。批准提示的操作恢复 auto mode。这些阈值不可配置。任何允许的操作重置连续计数器，而总计数器在会话中持续，仅在其自己的限制触发回退时重置。

在[非交互式模式](/zh-CN/headless)中使用 `-p` 标志，重复的阻止中止会话，因为没有用户可以提示。

重复的阻止通常意味着分类器缺少关于您的基础设施的上下文。使用 `/feedback` 报告误报，或让管理员[配置受信任的基础设施](/zh-CN/auto-mode-config)。

<AccordionGroup>
  <Accordion title="分类器如何评估操作">
    每个操作都经过固定的决策顺序。第一个匹配的步骤获胜：

    1. 与您的[允许或拒绝规则](/zh-CN/permissions#manage-permissions)匹配的操作立即解决
    2. 只读操作和工作目录中的文件编辑自动批准，除了对[受保护路径](#protected-paths)的写入
    3. 其他所有内容都发送到分类器
    4. 如果分类器阻止，Claude 收到原因并尝试替代方案
    
    进入 auto mode 时，授予任意代码执行的广泛允许规则被删除：
    
    * 全面 `Bash(*)`
    * 通配符解释器如 `Bash(python*)`
    * 包管理器运行命令
    * `Agent` 允许规则
    
    诸如 `Bash(npm test)` 之类的狭隘规则会继续。删除的规则在您离开 auto mode 时恢复。
    
    分类器看到用户消息、工具调用和您的 CLAUDE.md 内容。工具结果被剥离，因此文件或网页中的恶意内容无法直接操纵它。一个单独的服务器端探针扫描传入的工具结果并在 Claude 读取前标记可疑内容。有关这些层如何协同工作的更多信息，请参阅 [auto mode 公告](https://claude.com/blog/auto-mode)和[工程深度探讨](https://www.anthropic.com/engineering/claude-code-auto-mode)。
  </Accordion>

  <Accordion title="Auto mode 如何处理子代理">
    分类器在三个点检查[子代理](/zh-CN/sub-agents)工作：

    1. 在子代理启动前，委派的任务描述被评估，因此看起来危险的任务在生成时被阻止。
    2. 当子代理运行时，它的每个操作都通过分类器，使用与父会话相同的规则，子代理前言中的任何 `permissionMode` 都被忽略。
    3. 当子代理完成时，分类器审查其完整的操作历史；如果该返回检查标记了一个问题，安全警告被添加到子代理的结果前面。
  </Accordion>

  <Accordion title="成本和延迟">
    分类器在独立于您的 `/model` 选择的服务器配置模型上运行，因此切换模型不会改变分类器可用性。分类器调用计入您的令牌使用。每次检查发送记录的一部分加上待处理操作，在执行前添加往返。受保护路径外的读取和工作目录编辑跳过分类器，因此开销主要来自 shell 命令和网络操作。
  </Accordion>
</AccordionGroup>

## 仅使用 dontAsk mode 允许预先批准的工具

`dontAsk` mode 自动拒绝每个会提示的工具调用。仅与您的 `permissions.allow` 规则和[只读 Bash 命令](/zh-CN/permissions#read-only-commands)匹配的操作可以执行；显式 `ask` 规则被拒绝而不是提示。这使模式完全非交互式，适合 CI 管道或受限环境，其中您预先定义 Claude 可能执行的确切操作。

在启动时使用标志设置它：

```bash theme={null}
claude --permission-mode dontAsk
```

## 使用 bypassPermissions mode 跳过所有检查

`bypassPermissions` mode 禁用权限提示和安全检查，因此工具调用立即执行。对[受保护路径](#protected-paths)的写入是仍然提示的唯一操作。仅在隔离环境（如容器、VM 或没有互联网访问的 devcontainers）中使用此模式，其中 Claude Code 无法对您的主机系统造成损害。

您无法从没有启用标志之一启动的会话进入 `bypassPermissions`；使用其中一个重新启动以启用它：

```bash theme={null}
claude --permission-mode bypassPermissions
```

`--dangerously-skip-permissions` 标志等同。

<Warning>
  `bypassPermissions` 不提供针对提示注入或意外操作的保护。对于没有提示的后台安全检查，请改为使用 [auto mode](#eliminate-prompts-with-auto-mode)。管理员可以通过在[托管设置](/zh-CN/permissions#managed-settings)中将 `permissions.disableBypassPermissionsMode` 设置为 `"disable"` 来阻止此模式。
</Warning>

## 受保护的路径

对一小组路径的写入在每种模式中都永远不会自动批准。这防止了仓库状态和 Claude 自己的配置的意外破坏。在 `default`、`acceptEdits`、`plan` 和 `bypassPermissions` 中这些写入提示；在 `auto` 中它们路由到分类器；在 `dontAsk` 中它们被拒绝。

受保护的目录：

* `.git`
* `.vscode`
* `.idea`
* `.husky`
* `.claude`，除了 `.claude/commands`、`.claude/agents`、`.claude/skills` 和 `.claude/worktrees`，其中 Claude 经常创建内容

受保护的文件：

* `.gitconfig`、`.gitmodules`
* `.bashrc`、`.bash_profile`、`.zshrc`、`.zprofile`、`.profile`
* `.ripgreprc`
* `.mcp.json`、`.claude.json`

## 另请参阅

* [权限](/zh-CN/permissions)：允许、询问和拒绝规则；托管策略
* [配置 auto mode](/zh-CN/auto-mode-config)：告诉分类器您的组织信任哪些基础设施
* [Hooks](/zh-CN/hooks)：通过 `PreToolUse` 和 `PermissionRequest` hooks 的自定义权限逻辑
* [Ultraplan](/zh-CN/ultraplan)：在 Claude Code on the web 会话中运行 plan mode，带基于浏览器的审查
* [安全](/zh-CN/security)：保障和最佳实践
* [沙箱](/zh-CN/sandboxing)：Bash 命令的文件系统和网络隔离
* [非交互式模式](/zh-CN/headless)：使用 `-p` 标志运行 Claude Code
