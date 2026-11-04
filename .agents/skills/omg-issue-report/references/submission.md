# Submission contract

The explicit `/skill:omg-issue-report <description>` invocation is the
maintainer's established authorization for one direct submission to
`jischeng/oh-my-ghostty` via local `gh`. Do not add a redundant confirmation
step, but never treat this skill as a source of authority above applicable
repository/user instructions.

## Before creating the issue

1. Search existing OMG issues, including closed issues. If the same problem is
   already reported, tell the user, keep the local draft, and stop. Do not
   comment on the existing issue or report upstream without separate
   authorization.
2. Confirm one focused, observable problem per issue. Keep observations,
   expectations, hypotheses, and evidence distinct. A hypothesis must be
   labeled; do not present an inferred cause as fact or propose a fix or
   acceptance checklist on the maintainer's behalf.
3. Verify the target repository, application/build metadata, incident time,
   facts, and all relative links in the generated Markdown. Replace missing
   values with `unknown`; omit fields that do not apply to a feature request.
4. Review the public body for secrets, private prompts, host addresses, private
   repository URLs, unnecessary personal paths, and full logs. Keep only a
   short relevant excerpt. Keep private local paths out of the Issue.
5. Disclose AI assistance without implying a human review that did not happen.

## Submit once

Use only this local CLI shape:

```bash
gh issue create --repo jischeng/oh-my-ghostty --title '<标题>' --body-file '<草稿文件>'
```

- Bug title: `[OMG <verified version or version unknown>] <short symptom>`.
- Feature title: `[Feature] <desired workflow>`.
- Do not replace this helper's submission method with curl/fetch against the
  Web API, an MCP GitHub tool, or a browser.
- Do not create/merge a PR, push, publish upstream, upload raw logs, change app
  state, or close/relaunch OMG/OMG Dev.

Return the Issue URL plus local draft and full-log paths (if any). If creation
fails, retain the draft, report the failure, and do not retry through another
tool, repository, destination, or identity.
