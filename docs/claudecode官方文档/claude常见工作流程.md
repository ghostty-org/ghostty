# TitleDocumentation Index

> Fetch the complete documentation index at: https://code.claude.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 常见工作流程

> 使用 Claude Code 探索代码库、修复错误、重构、测试和其他日常任务的分步指南。

本页涵盖日常开发的实用工作流程：探索陌生代码、调试、重构、编写测试、创建 PR 和管理会话。每个部分都包含示例提示，您可以根据自己的项目进行调整。有关更高级的模式和提示，请参阅[最佳实践](/zh-CN/best-practices)。

## 理解新的代码库

### 快速获取代码库概览

假设您刚加入一个新项目，需要快速了解其结构。

<Steps>
  <Step title="导航到项目根目录">
    ```bash theme={null}
    cd /path/to/project 
    ```
  </Step>

  <Step title="启动 Claude Code">
    ```bash theme={null}
    claude 
    ```
  </Step>

  <Step title="请求高级概览">
    ```text theme={null}
    give me an overview of this codebase
    ```
  </Step>

  <Step title="深入了解特定组件">
    ```text theme={null}
    explain the main architecture patterns used here
    ```

    ```text theme={null}
    what are the key data models?
    ```
    
    ```text theme={null}
    how is authentication handled?
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 从广泛的问题开始，然后缩小到特定领域
  * 询问项目中使用的编码约定和模式
  * 请求项目特定术语的词汇表
</Tip>

### 查找相关代码

假设您需要定位与特定功能相关的代码。

<Steps>
  <Step title="要求 Claude 查找相关文件">
    ```text theme={null}
    find the files that handle user authentication
    ```
  </Step>

  <Step title="获取有关组件如何交互的上下文">
    ```text theme={null}
    how do these authentication files work together?
    ```
  </Step>

  <Step title="理解执行流程">
    ```text theme={null}
    trace the login process from front-end to database
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 明确说明您要查找的内容
  * 使用项目中的领域语言
  * 为您的语言安装[代码智能插件](/zh-CN/discover-plugins#code-intelligence)，以便 Claude 能够精确地进行"转到定义"和"查找引用"导航
</Tip>

***

## 高效修复错误

假设您遇到了错误消息，需要找到并修复其来源。

<Steps>
  <Step title="与 Claude 分享错误">
    ```text theme={null}
    I'm seeing an error when I run npm test
    ```
  </Step>

  <Step title="请求修复建议">
    ```text theme={null}
    suggest a few ways to fix the @ts-ignore in user.ts
    ```
  </Step>

  <Step title="应用修复">
    ```text theme={null}
    update user.ts to add the null check you suggested
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 告诉 Claude 重现问题的命令并获取堆栈跟踪
  * 提及重现错误的任何步骤
  * 让 Claude 知道错误是间歇性的还是持续的
</Tip>

***

## 重构代码

假设您需要更新旧代码以使用现代模式和实践。

<Steps>
  <Step title="识别用于重构的遗留代码">
    ```text theme={null}
    find deprecated API usage in our codebase
    ```
  </Step>

  <Step title="获取重构建议">
    ```text theme={null}
    suggest how to refactor utils.js to use modern JavaScript features
    ```
  </Step>

  <Step title="安全地应用更改">
    ```text theme={null}
    refactor utils.js to use ES2024 features while maintaining the same behavior
    ```
  </Step>

  <Step title="验证重构">
    ```text theme={null}
    run tests for the refactored code
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 要求 Claude 解释现代方法的优势
  * 在需要时请求更改保持向后兼容性
  * 以小的、可测试的增量进行重构
</Tip>

***

## 使用专门的 subagents

假设您想使用专门的 AI subagents 来更有效地处理特定任务。

<Steps>
  <Step title="查看可用的 subagents">
    ```text theme={null}
    /agents
    ```

    这显示所有可用的 subagents 并让您创建新的。
  </Step>

  <Step title="自动使用 subagents">
    Claude Code 自动将适当的任务委派给专门的 subagents：

    ```text theme={null}
    review my recent code changes for security issues
    ```
    
    ```text theme={null}
    run all tests and fix any failures
    ```
  </Step>

  <Step title="明确请求特定的 subagents">
    ```text theme={null}
    use the code-reviewer subagent to check the auth module
    ```

    ```text theme={null}
    have the debugger subagent investigate why users can't log in
    ```
  </Step>

  <Step title="为您的工作流程创建自定义 subagents">
    ```text theme={null}
    /agents
    ```

    然后选择"Create New subagent"并按照提示定义：
    
    * 描述 subagent 目的的唯一标识符（例如，`code-reviewer`、`api-designer`）。
    * Claude 何时应该使用此代理
    * 它可以访问哪些工具
    * 描述代理角色和行为的系统提示
  </Step>
</Steps>

<Tip>
  提示：

  * 在 `.claude/agents/` 中创建项目特定的 subagents 以供团队共享
  * 使用描述性的 `description` 字段来启用自动委派
  * 限制工具访问权限为每个 subagent 实际需要的内容
  * 查看[subagents 文档](/zh-CN/sub-agents)了解详细示例
</Tip>

***

## 使用 Plan Mode 进行安全的代码分析

Plan Mode 指示 Claude 通过使用只读操作分析代码库来创建计划，非常适合探索代码库、规划复杂更改或安全地审查代码。在 Plan Mode 中，Claude 使用 [`AskUserQuestion`](/zh-CN/tools-reference) 在提出计划之前收集需求并澄清您的目标。

### 何时使用 Plan Mode

* **多步骤实现**：当您的功能需要对许多文件进行编辑时
* **代码探索**：当您想在更改任何内容之前彻底研究代码库时
* **交互式开发**：当您想与 Claude 迭代方向时

### 如何使用 Plan Mode

**在会话期间打开 Plan Mode**

您可以在会话期间使用 **Shift+Tab** 循环切换权限模式来切换到 Plan Mode。

如果您处于 Normal Mode，**Shift+Tab** 首先切换到 Auto-Accept Mode，在终端底部显示 `⏵⏵ accept edits on`。随后的 **Shift+Tab** 将切换到 Plan Mode，显示 `⏸ plan mode on`。

**在 Plan Mode 中启动新会话**

要在 Plan Mode 中启动新会话，请使用 `--permission-mode plan` 标志：

```bash theme={null}
claude --permission-mode plan
```

**在 Plan Mode 中运行"无头"查询**

您也可以使用 `-p` 直接在 Plan Mode 中运行查询（即在["无头模式"](/zh-CN/headless)中）：

```bash theme={null}
claude --permission-mode plan -p "Analyze the authentication system and suggest improvements"
```

### 示例：规划复杂的重构

```bash theme={null}
claude --permission-mode plan
```

```text theme={null}
I need to refactor our authentication system to use OAuth2. Create a detailed migration plan.
```

Claude 分析当前实现并创建全面的计划。通过后续问题进行细化：

```text theme={null}
What about backward compatibility?
```

```text theme={null}
How should we handle database migration?
```

<Tip>按 `Ctrl+G` 在默认文本编辑器中打开计划，您可以在 Claude 继续之前直接编辑它。</Tip>

当您接受计划时，Claude 会自动从计划内容为会话命名。该名称显示在提示栏和会话选择器中。如果您已经使用 `--name` 或 `/rename` 设置了名称，接受计划不会覆盖它。

### 将 Plan Mode 配置为默认值

```json theme={null}
// .claude/settings.json
{
  "permissions": {
    "defaultMode": "plan"
  }
}
```

有关更多配置选项，请参阅[设置文档](/zh-CN/settings#available-settings)。

***

## 使用测试

假设您需要为未覆盖的代码添加测试。

<Steps>
  <Step title="识别未测试的代码">
    ```text theme={null}
    find functions in NotificationsService.swift that are not covered by tests
    ```
  </Step>

  <Step title="生成测试脚手架">
    ```text theme={null}
    add tests for the notification service
    ```
  </Step>

  <Step title="添加有意义的测试用例">
    ```text theme={null}
    add test cases for edge conditions in the notification service
    ```
  </Step>

  <Step title="运行并验证测试">
    ```text theme={null}
    run the new tests and fix any failures
    ```
  </Step>
</Steps>

Claude 可以生成遵循您项目现有模式和约定的测试。请求测试时，请明确说明您想验证的行为。Claude 检查您现有的测试文件以匹配已在使用的样式、框架和断言模式。

为了获得全面的覆盖，要求 Claude 识别您可能遗漏的边界情况。Claude 可以分析您的代码路径并建议测试错误条件、边界值和容易被忽视的意外输入。

***

## 创建拉取请求

您可以通过直接要求 Claude 创建拉取请求（"create a pr for my changes"），或逐步指导 Claude：

<Steps>
  <Step title="总结您的更改">
    ```text theme={null}
    summarize the changes I've made to the authentication module
    ```
  </Step>

  <Step title="生成拉取请求">
    ```text theme={null}
    create a pr
    ```
  </Step>

  <Step title="审查和细化">
    ```text theme={null}
    enhance the PR description with more context about the security improvements
    ```
  </Step>
</Steps>

当您使用 `gh pr create` 创建 PR 时，会话会自动链接到该 PR。您可以稍后使用 `claude --from-pr <number>` 恢复它。

<Tip>
  在提交前审查 Claude 生成的 PR，并要求 Claude 突出显示潜在的风险或注意事项。
</Tip>

## 处理文档

假设您需要为代码添加或更新文档。

<Steps>
  <Step title="识别未记录的代码">
    ```text theme={null}
    find functions without proper JSDoc comments in the auth module
    ```
  </Step>

  <Step title="生成文档">
    ```text theme={null}
    add JSDoc comments to the undocumented functions in auth.js
    ```
  </Step>

  <Step title="审查和增强">
    ```text theme={null}
    improve the generated documentation with more context and examples
    ```
  </Step>

  <Step title="验证文档">
    ```text theme={null}
    check if the documentation follows our project standards
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 指定您想要的文档样式（JSDoc、docstrings 等）
  * 请求文档中的示例
  * 请求公共 API、接口和复杂逻辑的文档
</Tip>

***

## 在笔记和非代码文件夹中工作

Claude Code 可以在任何目录中工作。在笔记库、文档文件夹或任何 markdown 文件集合中运行它，以搜索、编辑和重新组织内容，就像处理代码一样。

`.claude/` 目录和 `CLAUDE.md` 与其他工具的配置目录并排存在，不会产生冲突。Claude 在每次工具调用时都会重新读取文件，因此它会在下次读取该文件时看到您在另一个应用程序中所做的编辑。

***

## 使用图像

假设您需要在代码库中使用图像，并希望 Claude 帮助分析图像内容。

<Steps>
  <Step title="将图像添加到对话中">
    您可以使用以下任何方法：

    1. 将图像拖放到 Claude Code 窗口中
    2. 复制图像并使用 ctrl+v 将其粘贴到 CLI 中（不要使用 cmd+v）
    3. 向 Claude 提供图像路径。例如，"Analyze this image: /path/to/your/image.png"
  </Step>

  <Step title="要求 Claude 分析图像">
    ```text theme={null}
    What does this image show?
    ```

    ```text theme={null}
    Describe the UI elements in this screenshot
    ```
    
    ```text theme={null}
    Are there any problematic elements in this diagram?
    ```
  </Step>

  <Step title="使用图像获取上下文">
    ```text theme={null}
    Here's a screenshot of the error. What's causing it?
    ```

    ```text theme={null}
    This is our current database schema. How should we modify it for the new feature?
    ```
  </Step>

  <Step title="从视觉内容获取代码建议">
    ```text theme={null}
    Generate CSS to match this design mockup
    ```

    ```text theme={null}
    What HTML structure would recreate this component?
    ```
  </Step>
</Steps>

<Tip>
  提示：

  * 当文本描述不清楚或繁琐时使用图像
  * 包含错误、UI 设计或图表的屏幕截图以获得更好的上下文
  * 您可以在对话中使用多个图像
  * 图像分析适用于图表、屏幕截图、模型等
  * 当 Claude 引用图像时（例如，`[Image #1]`），`Cmd+Click`（Mac）或 `Ctrl+Click`（Windows/Linux）链接以在默认查看器中打开图像
</Tip>

***

## 引用文件和目录

使用 @ 快速包含文件或目录，无需等待 Claude 读取它们。

<Steps>
  <Step title="引用单个文件">
    ```text theme={null}
    Explain the logic in @src/utils/auth.js
    ```

    这在对话中包含文件的完整内容。
  </Step>

  <Step title="引用目录">
    ```text theme={null}
    What's the structure of @src/components?
    ```

    这提供了带有文件信息的目录列表。
  </Step>

  <Step title="引用 MCP 资源">
    ```text theme={null}
    Show me the data from @github:repos/owner/repo/issues
    ```

    这使用 @server:resource 格式从连接的 MCP 服务器获取数据。有关详细信息，请参阅 [MCP 资源](/zh-CN/mcp#use-mcp-resources)。
  </Step>
</Steps>

<Tip>
  提示：

  * 文件路径可以是相对的或绝对的
  * @ 文件引用在文件的目录和父目录中添加 `CLAUDE.md` 到上下文
  * 目录引用显示文件列表，而不是内容
  * 您可以在单个消息中引用多个文件（例如，"@file1.js and @file2.js"）
</Tip>

***

## 使用扩展思考（Thinking Mode）

[扩展思考](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)默认启用，为 Claude 提供空间在响应前逐步推理复杂问题。此推理在详细模式中可见，您可以使用 `Ctrl+O` 切换。在扩展思考期间，进度提示会出现在指示器下方，显示 Claude 正在积极工作。

此外，[支持努力级别的模型](/zh-CN/model-config#adjust-effort-level)使用自适应推理：不是固定的思考令牌预算，而是模型根据您的努力级别设置和手头的任务动态决定是否以及如何思考。自适应推理让 Claude 能够更快地响应常规提示，并为受益于深度思考的步骤保留更深层的思考。

扩展思考对于复杂的架构决策、具有挑战性的错误、多步骤实现规划和评估不同方法之间的权衡特别有价值。

<Note>
  "think"、"think hard" 和 "think more" 等短语被解释为常规提示指令，不分配思考令牌。
</Note>

### 配置 Thinking Mode

思考默认启用，但您可以调整或禁用它。

| 范围                    | 如何配置                                                     | 详细信息                                                     |
| ----------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **努力级别**            | 运行 `/effort`，在 `/model` 中调整，或设置 [`CLAUDE_CODE_EFFORT_LEVEL`](/zh-CN/env-vars) | 控制[支持的模型](/zh-CN/model-config#adjust-effort-level)上的思考深度 |
| **`ultrathink` 关键字** | 在提示中的任何地方包含 "ultrathink"                          | 添加上下文内指令，告诉模型在该轮进行更多推理。不改变努力级别本身；有关详细信息，请参阅[调整努力级别](/zh-CN/model-config#adjust-effort-level) |
| **切换快捷键**          | 按 `Option+T`（macOS）或 `Alt+T`（Windows/Linux）            | 为当前会话切换思考开/关（所有模型）。可能需要[终端配置](/zh-CN/terminal-config)来启用 Option 键快捷键 |
| **全局默认值**          | 使用 `/config` 切换 Thinking Mode                            | 在所有项目中设置默认值（所有模型）。<br />保存为 `~/.claude/settings.json` 中的 `alwaysThinkingEnabled` |
| **限制令牌预算**        | 设置 [`MAX_THINKING_TOKENS`](/zh-CN/env-vars) 环境变量       | 将思考预算限制为特定数量的令牌。在具有自适应推理的模型上，仅当设置为 `0` 时才适用，除非禁用自适应推理。示例：`export MAX_THINKING_TOKENS=10000` |

要查看 Claude 的思考过程，按 `Ctrl+O` 切换详细模式，并查看显示为灰色斜体文本的内部推理。

### 扩展思考如何工作

扩展思考控制 Claude 在响应前执行多少内部推理。更多思考提供更多空间来探索解决方案、分析边界情况和自我纠正错误。

在[支持努力级别的模型](/zh-CN/model-config#adjust-effort-level)上，思考使用自适应推理：模型根据您选择的努力级别动态分配思考令牌。这是调整速度和推理深度之间权衡的推荐方式。如果您希望 Claude 比您的努力级别通常会产生的更多或更少地思考，您也可以直接在提示中或在 `CLAUDE.md` 中说明。

对于较旧的模型，思考使用从您的输出分配中提取的固定令牌预算。预算因模型而异；有关详细信息，请参阅 [`MAX_THINKING_TOKENS`](/zh-CN/env-vars)。您可以使用该环境变量限制预算，或通过 `/config` 或 `Option+T`/`Alt+T` 切换完全禁用思考。

在具有自适应推理的模型上，`MAX_THINKING_TOKENS` 仅在设置为 `0` 以禁用思考时适用，或当 `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` 将模型恢复为固定预算时。`CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` 仅适用于 Opus 4.6 和 Sonnet 4.6。Opus 4.7 始终使用自适应推理，不支持固定思考预算。请参阅[环境变量](/zh-CN/env-vars)。

<Warning>
  您需要为所有使用的思考令牌付费，即使思考摘要被编辑。在交互模式中，思考默认显示为折叠的存根。在 `settings.json` 中设置 `showThinkingSummaries: true` 以显示完整摘要。
</Warning>

***

## 恢复以前的对话

启动 Claude Code 时，您可以恢复以前的会话：

* `claude --continue` 继续当前目录中最近的对话
* `claude --resume` 打开对话选择器或按名称恢复
* `claude --from-pr 123` 恢复链接到特定拉取请求的会话

从活跃会话内，使用 `/resume` 切换到不同的对话。

当选定的会话足够旧且足够大，以至于重新阅读它会消耗您使用限额的大部分时，`--resume`、`--continue` 和 `/resume` 会提供从摘要恢复而不是加载完整记录的选项。此提示在 Amazon Bedrock、Google Cloud Vertex AI 或 Microsoft Foundry 上不可用。

会话按项目目录存储。默认情况下，`/resume` 选择器显示来自当前 worktree 的交互式会话，带有键盘快捷键来扩展列表到其他 worktrees 或项目、搜索、预览和重命名。有关完整的快捷键参考，请参阅下面的[使用会话选择器](#use-the-session-picker)。

当您从同一存储库的另一个 worktree 选择会话时，Claude Code 直接恢复它，无需您首先切换目录。从不相关项目选择会话会将 `cd` 和恢复命令复制到您的剪贴板。

按名称恢复在当前存储库及其 worktrees 中解析。`claude --resume <name>` 和 `/resume <name>` 都查找精确匹配并直接恢复它，即使会话位于不同的 worktree 中。

当名称不明确时，`claude --resume <name>` 打开选择器，名称预填充为搜索词。`/resume <name>` 从活跃会话内报告错误，因此运行 `/resume` 不带参数来打开选择器并选择。

由 `claude -p` 或 SDK 调用创建的会话不会出现在选择器中，但您仍然可以通过将其会话 ID 直接传递给 `claude --resume <session-id>` 来恢复它。

### 命名您的会话

给会话起描述性名称以便稍后找到它们。这是在处理多个任务或功能时的最佳实践。

<Steps>
  <Step title="命名会话">
    在启动时使用 `-n` 命名会话：

    ```bash theme={null}
    claude -n auth-refactor
    ```
    
    或在会话期间使用 `/rename`，这也会在提示栏上显示名称：
    
    ```text theme={null}
    /rename auth-refactor
    ```
    
    您也可以从选择器重命名任何会话：运行 `/resume`，导航到会话，然后按 `Ctrl+R`。
  </Step>

  <Step title="稍后按名称恢复">
    从命令行：

    ```bash theme={null}
    claude --resume auth-refactor
    ```
    
    或从活跃会话内：
    
    ```text theme={null}
    /resume auth-refactor
    ```
  </Step>
</Steps>

### 使用会话选择器

`/resume` 命令（或 `claude --resume` 不带参数）打开具有以下功能的交互式会话选择器：

**选择器中的键盘快捷键：**

| 快捷键                                | 操作                                                         |
| :------------------------------------ | :----------------------------------------------------------- |
| `↑` / `↓`                             | 在会话之间导航                                               |
| `→` / `←`                             | 展开或折叠分组的会话                                         |
| `Enter`                               | 选择并恢复突出显示的会话                                     |
| `Space`                               | 预览会话内容。`Ctrl+V` 也适用于不将其捕获为粘贴的终端        |
| `Ctrl+R`                              | 重命名突出显示的会话                                         |
| `/` 或任何可打印字符（除 `Space` 外） | 进入搜索模式并过滤会话                                       |
| `Ctrl+A`                              | 显示此机器上所有项目的会话。再次按下以恢复当前存储库         |
| `Ctrl+W`                              | 显示当前存储库所有 worktrees 的会话。再次按下以恢复当前 worktree。仅在多 worktree 存储库中显示 |
| `Ctrl+B`                              | 过滤到来自当前 git 分支的会话。再次按下以显示所有分支的会话  |
| `Esc`                                 | 退出选择器或搜索模式                                         |

**会话组织：**

选择器显示带有有用元数据的会话：

* 会话名称（如果设置），否则对话摘要或第一个用户提示
* 自上次活动以来经过的时间
* 消息计数
* Git 分支（如果适用）
* 项目路径，在使用 `Ctrl+A` 扩展到所有项目后显示

分叉的会话（使用 `/branch`、`/rewind` 或 `--fork-session` 创建）在其根会话下分组，使查找相关对话更容易。

<Tip>
  提示：

  * **尽早命名会话**：在开始处理不同任务时使用 `/rename`——稍后找到"payment-integration"比"explain this function"容易得多
  * 使用 `--continue` 快速访问当前目录中最近的对话
  * 当您知道需要哪个会话时使用 `--resume session-name`
  * 当您需要浏览和选择时使用 `--resume`（不带名称）
  * 对于脚本，使用 `claude --continue --print "prompt"` 以非交互模式恢复
  * 在选择器中按 `Space` 在恢复前预览会话
  * 恢复的对话以与原始对话相同的模型和配置开始

  工作原理：

  1. **对话存储**：所有对话都自动保存在本地，包含完整的消息历史
  2. **消息反序列化**：恢复时，整个消息历史被恢复以保持上下文
  3. **工具状态**：来自以前对话的工具使用和结果被保留
  4. **上下文恢复**：对话以所有以前的上下文完整恢复
</Tip>

***

## 使用 Git worktrees 运行并行 Claude Code 会话

当同时处理多个任务时，您需要每个 Claude 会话都有自己的代码库副本，以便更改不会冲突。Git worktrees 通过创建单独的工作目录来解决这个问题，每个目录都有自己的文件和分支，同时共享相同的存储库历史和远程连接。这意味着您可以让 Claude 在一个 worktree 中处理功能，同时在另一个 worktree 中修复错误，而不会相互干扰。

使用 `--worktree`（`-w`）标志创建隔离的 worktree 并在其中启动 Claude。您传递的值成为 worktree 目录名称和分支名称：

```bash theme={null}
# 在名为 "feature-auth" 的 worktree 中启动 Claude
# 创建 .claude/worktrees/feature-auth/ 和新分支
claude --worktree feature-auth

# 在单独的 worktree 中启动另一个会话
claude --worktree bugfix-123
```

如果您省略名称，Claude 会自动生成一个随机名称：

```bash theme={null}
# 自动生成名称如 "bright-running-fox"
claude --worktree
```

Worktrees 在 `<repo>/.claude/worktrees/<name>` 创建，并从默认远程分支分支。worktree 分支命名为 `worktree-<name>`。

基础分支不能通过 Claude Code 标志或设置进行配置。`origin/HEAD` 是存储在您本地 `.git` 目录中的引用，Git 在您克隆时设置一次。如果存储库的默认分支稍后在 GitHub 或 GitLab 上更改，您的本地 `origin/HEAD` 会继续指向旧的，worktrees 将从那里分支。要重新同步您的本地引用与远程当前认为的默认值：

```bash theme={null}
git remote set-head origin -a
```

这是一个标准的 Git 命令，仅更新您的本地 `.git` 目录。远程服务器上没有任何更改。如果您希望 worktrees 基于特定分支而不是远程的默认值，请使用 `git remote set-head origin your-branch-name` 显式设置它。

为了完全控制 worktrees 的创建方式，包括为每次调用选择不同的基础，配置 [WorktreeCreate hook](/zh-CN/hooks#worktreecreate)。该 hook 完全替换 Claude Code 的默认 `git worktree` 逻辑，因此您可以从您需要的任何 ref 获取和分支。

您也可以在会话期间要求 Claude "work in a worktree" 或 "start a worktree"，它会自动创建一个。

### Subagent worktrees

Subagents 也可以使用 worktree 隔离来并行工作而不会冲突。要求 Claude "use worktrees for your agents" 或在[自定义 subagent](/zh-CN/sub-agents#supported-frontmatter-fields) 中通过在代理的 frontmatter 中添加 `isolation: worktree` 来配置它。每个 subagent 获得自己的 worktree，当 subagent 完成而没有更改时自动清理。

### Worktree 清理

当您退出 worktree 会话时，Claude 根据您是否进行了更改来处理清理：

* **无更改**：worktree 及其分支自动删除
* **存在更改或提交**：Claude 提示您保留或删除 worktree。保留会保留目录和分支，以便您稍后可以返回。删除会删除 worktree 目录及其分支，丢弃所有未提交的更改和提交

Subagent worktrees 由崩溃或中断的并行运行孤立的，在启动时会自动删除，一旦它们超过您的 [`cleanupPeriodDays`](/zh-CN/settings#available-settings) 设置，前提是它们没有未提交的更改、没有未跟踪的文件和没有未推送的提交。使用 `--worktree` 创建的 Worktrees 永远不会被此扫描删除。

要在 Claude 会话外清理 worktrees，请使用[手动 worktree 管理](#manage-worktrees-manually)。

<Tip>
  将 `.claude/worktrees/` 添加到您的 `.gitignore` 以防止 worktree 内容在主存储库中显示为未跟踪的文件。
</Tip>

### 复制 gitignored 文件到 worktrees

Git worktrees 是新鲜检出，所以它们不包括来自主存储库的未跟踪文件，如 `.env` 或 `.env.local`。要在 Claude 创建 worktree 时自动复制这些文件，请将 `.worktreeinclude` 文件添加到项目根目录。

该文件使用 `.gitignore` 语法列出要复制的文件。只有匹配模式且也被 gitignored 的文件才会被复制，因此跟踪的文件永远不会被复制。

```text .worktreeinclude theme={null}
.env
.env.local
config/secrets.json
```

这适用于使用 `--worktree` 创建的 worktrees、subagent worktrees 和[桌面应用](/zh-CN/desktop#work-in-parallel-with-sessions)中的并行会话。

### 手动管理 worktrees

为了更好地控制 worktree 位置和分支配置，直接使用 Git 创建 worktrees。当您需要检出特定的现有分支或将 worktree 放在存储库外时，这很有用。

```bash theme={null}
# 使用新分支创建 worktree
git worktree add ../project-feature-a -b feature-a

# 使用现有分支创建 worktree
git worktree add ../project-bugfix bugfix-123

# 在 worktree 中启动 Claude
cd ../project-feature-a && claude

# 完成时清理
git worktree list
git worktree remove ../project-feature-a
```

在[官方 Git worktree 文档](https://git-scm.com/docs/git-worktree)中了解更多。

<Tip>
  记住根据您的项目设置在每个新 worktree 中初始化您的开发环境。根据您的堆栈，这可能包括运行依赖项安装（`npm install`、`yarn`）、设置虚拟环境或遵循您的项目标准设置过程。
</Tip>

### 非 git 版本控制

Worktree 隔离默认使用 git。对于其他版本控制系统如 SVN、Perforce 或 Mercurial，配置 [WorktreeCreate 和 WorktreeRemove hooks](/zh-CN/hooks#worktreecreate) 以提供自定义 worktree 创建和清理逻辑。配置后，这些 hooks 在您使用 `--worktree` 时替换默认的 git 行为，因此[`.worktreeinclude`](#copy-gitignored-files-to-worktrees) 不被处理。在您的 hook 脚本中复制任何本地配置文件。

对于具有共享任务和消息的并行会话的自动协调，请参阅[代理团队](/zh-CN/agent-teams)。

***

## 在 Claude 需要您的注意时获得通知

当您启动长时间运行的任务并切换到另一个窗口时，您可以设置桌面通知，以便在 Claude 完成或需要您的输入时了解。这使用 `Notification` [hook 事件](/zh-CN/hooks-guide#get-notified-when-claude-needs-input)，每当 Claude 等待权限、空闲并准备好新提示或完成身份验证时触发。

<Steps>
  <Step title="将 hook 添加到您的设置">
    打开 `~/.claude/settings.json` 并添加一个 `Notification` hook，该 hook 调用您的平台的本机通知命令：

    <Tabs>
      <Tab title="macOS">
        ```json theme={null}
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "osascript -e 'display notification \"Claude Code needs your attention\" with title \"Claude Code\"'"
                  }
                ]
              }
            ]
          }
        }
        ```
      </Tab>
    
      <Tab title="Linux">
        ```json theme={null}
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "notify-send 'Claude Code' 'Claude Code needs your attention'"
                  }
                ]
              }
            ]
          }
        }
        ```
      </Tab>
    
      <Tab title="Windows">
        ```json theme={null}
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "powershell.exe -Command \"[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('Claude Code needs your attention', 'Claude Code')\""
                  }
                ]
              }
            ]
          }
        }
        ```
      </Tab>
    </Tabs>
    
    如果您的设置文件已经有 `hooks` 键，请将 `Notification` 条目合并到其中，而不是覆盖。您也可以通过在 CLI 中描述您想要的内容来要求 Claude 为您编写 hook。
  </Step>

  <Step title="可选地缩小匹配器范围">
    默认情况下，hook 在所有通知类型上触发。要仅针对特定事件触发，请将 `matcher` 字段设置为以下值之一：

    | 匹配器                  | 触发时机                |
    | :------------------- | :------------------ |
    | `permission_prompt`  | Claude 需要您批准工具使用    |
    | `idle_prompt`        | Claude 完成并等待您的下一个提示 |
    | `auth_success`       | 身份验证完成              |
    | `elicitation_dialog` | Claude 在问您一个问题      |
  </Step>

  <Step title="验证 hook">
    输入 `/hooks` 并选择 `Notification` 以确认 hook 出现。选择它显示将运行的命令。要端到端测试它，要求 Claude 运行需要权限的命令并切换离开终端，或要求 Claude 直接触发通知。
  </Step>
</Steps>

有关完整的事件架构和通知类型，请参阅[通知参考](/zh-CN/hooks#notification)。

***

## 将 Claude 用作 unix 风格的实用程序

### 将 Claude 添加到您的验证过程

假设您想将 Claude Code 用作 linter 或代码审查工具。

**将 Claude 添加到您的构建脚本：**

```json theme={null}
// package.json
{
    ...
    "scripts": {
        ...
        "lint:claude": "claude -p 'you are a linter. please look at the changes vs. main and report any issues related to typos. report the filename and line number on one line, and a description of the issue on the second line. do not return any other text.'"
    }
}
```

<Tip>
  提示：

  * 在您的 CI/CD 管道中使用 Claude 进行自动代码审查
  * 自定义提示以检查与您的项目相关的特定问题
  * 考虑为不同类型的验证创建多个脚本
</Tip>

### 管道进入、管道输出

假设您想将数据管道输入 Claude，并获得结构化格式的数据。

**通过 Claude 管道数据：**

```bash theme={null}
cat build-error.txt | claude -p 'concisely explain the root cause of this build error' > output.txt
```

<Tip>
  提示：

  * 使用管道将 Claude 集成到现有的 shell 脚本中
  * 与其他 Unix 工具结合以实现强大的工作流程
  * 考虑使用 `--output-format` 获得结构化输出
</Tip>

### 控制输出格式

假设您需要 Claude 的输出采用特定格式，特别是在将 Claude Code 集成到脚本或其他工具时。

<Steps>
  <Step title="使用文本格式（默认）">
    ```bash theme={null}
    cat data.txt | claude -p 'summarize this data' --output-format text > summary.txt
    ```

    这仅输出 Claude 的纯文本响应（默认行为）。
  </Step>

  <Step title="使用 JSON 格式">
    ```bash theme={null}
    cat code.py | claude -p 'analyze this code for bugs' --output-format json > analysis.json
    ```

    这输出包含元数据（包括成本和持续时间）的消息的 JSON 数组。
  </Step>

  <Step title="使用流式 JSON 格式">
    ```bash theme={null}
    cat log.txt | claude -p 'parse this log file for errors' --output-format stream-json
    ```

    这在 Claude 处理请求时实时输出一系列 JSON 对象。每条消息都是有效的 JSON 对象，但如果连接，整个输出不是有效的 JSON。
  </Step>
</Steps>

<Tip>
  提示：

  * 对于简单集成（您只需要 Claude 的响应），使用 `--output-format text`
  * 当您需要完整的对话日志时使用 `--output-format json`
  * 对于每个对话轮次的实时输出，使用 `--output-format stream-json`
</Tip>

***

## 按计划运行 Claude

假设您想让 Claude 自动定期处理任务，如每天早上审查开放的 PR、每周审计依赖项或在夜间检查 CI 失败。

根据您希望任务运行的位置选择调度选项：

| 选项                                           | 运行位置                 | 最适合                                                       |
| :--------------------------------------------- | :----------------------- | :----------------------------------------------------------- |
| [Routines](/zh-CN/routines)                    | Anthropic 管理的基础设施 | 即使您的计算机关闭也应该运行的任务。也可以在 API 调用或 GitHub 事件上触发，除了计划。在 [claude.ai/code/routines](https://claude.ai/code/routines) 配置。 |
| [桌面计划任务](/zh-CN/desktop-scheduled-tasks) | 您的机器，通过桌面应用   | 需要直接访问本地文件、工具或未提交更改的任务。               |
| [GitHub Actions](/zh-CN/github-actions)        | 您的 CI 管道             | 与存储库事件（如打开的 PR）相关的任务，或应该与工作流配置一起存在的 cron 计划。 |
| [`/loop`](/zh-CN/scheduled-tasks)              | 当前 CLI 会话            | 会话打开时的快速轮询。任务在您开始新对话时停止；`--resume` 和 `--continue` 恢复未过期的任务。 |

<Tip>
  为计划任务编写提示时，明确说明成功是什么样的以及如何处理结果。任务自主运行，所以它不能提出澄清问题。例如："审查标记为 `needs-review` 的开放 PR，对任何问题留下内联评论，并在 `#eng-reviews` Slack 频道中发布摘要。"
</Tip>

***

## 询问 Claude 关于其功能

Claude 内置访问其文档，可以回答关于其自身功能和限制的问题。

### 示例问题

```text theme={null}
can Claude Code create pull requests?
```

```text theme={null}
how does Claude Code handle permissions?
```

```text theme={null}
what skills are available?
```

```text theme={null}
how do I use MCP with Claude Code?
```

```text theme={null}
how do I configure Claude Code for Amazon Bedrock?
```

```text theme={null}
what are the limitations of Claude Code?
```

<Note>
  Claude 基于文档提供对这些问题的答案。有关可执行示例和实际演示，请运行 `/powerup` 以获得带有动画演示的交互式课程，或参考上面的特定工作流程部分。
</Note>

<Tip>
  提示：

  * Claude 始终可以访问最新的 Claude Code 文档，无论您使用的版本如何
  * 提出具体问题以获得详细答案
  * Claude 可以解释复杂的功能，如 MCP 集成、企业配置和高级工作流程
</Tip>

***

## 后续步骤

<CardGroup cols={2}>
  <Card title="最佳实践" icon="lightbulb" href="/zh-CN/best-practices">
    充分利用 Claude Code 的模式
  </Card>

  <Card title="Claude Code 如何工作" icon="gear" href="/zh-CN/how-claude-code-works">
    理解代理循环和上下文管理
  </Card>

  <Card title="扩展 Claude Code" icon="puzzle-piece" href="/zh-CN/features-overview">
    添加 skills、hooks、MCP、subagents 和插件
  </Card>

  <Card title="参考实现" icon="code" href="https://github.com/anthropics/claude-code/tree/main/.devcontainer">
    克隆开发容器参考实现
  </Card>
</CardGroup>
