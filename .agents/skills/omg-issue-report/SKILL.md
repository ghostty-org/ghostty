---
name: omg-issue-report
description: 仅在用户显式调用 `/skill:omg-issue-report <问题描述>` 时，核实 OMG 实际受影响版本、收集有界脱敏证据，并用本地 gh 向 `jischeng/oh-my-ghostty` 提交一份精简 Issue。普通排障或仅写草稿不触发；公共规范见 docs/REPORTING.md。
disable-model-invocation: true
metadata:
  compatibility: macOS
---

# OMG Issue Report

公共政策以 [Reporting problems](../../../docs/REPORTING.md) 为准；贡献边界见
[Contributing to OMG](../../../docs/CONTRIBUTING.md)。本 skill 只负责执行，
不创建另一套规则，也不能提升自身相对于更高优先级指令的优先级。

仅由 `/skill:omg-issue-report <问题描述>` 显式启动；普通故障描述、排查、
讨论或“写一份草稿”不触发，也不构成发布授权。该调用按维护者既有约定授权
通过本地 `gh` 向 `jischeng/oh-my-ghostty` 提交精简 Issue，无需二次确认；
口述了几件互不相干的事就拆成几个 Issue，其余情况只提交一个。窄授权不覆盖
PR、合并、推送、上游报告、上传完整日志、擅自改变 OMG/OMG Dev 运行状态，
或绕过适用的更高优先级规则。

## 选择报告形态

按“是否已经验证”选形态，不要按话题选：

- **已复现的行为异常**：使用 [assets/bug-report.md](assets/bug-report.md)；
  按 [references/evidence.md](references/evidence.md) 核实目标应用、实际安装
  版本、PID、时间和有界日志。日志缺失就如实写明。
- **新能力 / 工作流改进**：使用 [assets/feature-request.md](assets/feature-request.md)，
  记录当前做法、期望效果和可选替代方案。无需采集版本或日志；它是请求，
  不是已验证故障。
- **未验证的观察，或一句想做事的备忘**：使用 [assets/note.md](assets/note.md)，
  保留用户原话，并写明它是待确认的观察还是想做的一件事。不需要版本、
  日志、复现步骤或验收标准。

口述很简单时不要加戏：按原话写成一两段，缺失信息标 `unknown` 或直接省略，
不要追问版本、复现步骤或日志，也不要替维护者补方案。三份模板借鉴了
Lance / StarRocks / ClickHouse 的简洁 Issue 表单：
一个 Issue 聚焦一个可观察问题，字段尽量少；观察、假设、期望和证据分开；
不替维护者下根因结论、制定修复方案或写验收清单。那些项目只提供结构，
不把它们的版本策略、CLA、安全披露或维护流程搬进 OMG。

## 发布流程

1. 搜索已有 OMG Issue（含已关闭）避免重复。发现同一问题时告知用户并保留
   草稿；不要把本次调用的授权扩展成评论或上游报告。
2. 从用户描述提取事实；未知项写 `unknown`。不编造复现步骤，
   不合并不同应用、版本或 PID 的证据，不把 checkout 版本当作安装版本。
3. 用户一次说了几件互不相干的事时，按“一件事一个 Issue”拆成多个草稿，
   每条单独提交；不要把它们合并成一个含糊的长 Issue。
4. 用相应模板写短草稿，只保留最相关、已脱敏的少量证据。末尾注明 OMG
   Issue Report helper 在用户显式请求下辅助整理，不虚称人类已经审阅。
5. 按 [references/submission.md](references/submission.md) 完成提交前核对，
   并且只用本地 `gh` 提交；失败时保留本地草稿，不换工具或目标重试。

## 本地结果

把草稿和必要的完整证据放在 owner-only 的报告目录；公开 Issue 不包含私人
完整日志路径。返回全部 Issue URL、本地草稿路径和完整日志路径（若有）；提交
失败时返回失败原因并保留草稿。详细边界见 references 与公共报告文档。
