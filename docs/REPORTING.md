# Reporting problems and requesting features

This is the public reporting guide for **Oh My Ghostty (OMG)**. You do not need
an agent, a skill, or an upstream Ghostty vouch to report an OMG problem.
English and Chinese reports are welcome.

- [Search existing OMG issues](https://github.com/jischeng/oh-my-ghostty/issues)
  first, including closed issues.
- Use the [OMG issue forms](https://github.com/jischeng/oh-my-ghostty/issues/new/choose)
  for bugs and feature requests.
- For patches, see [Contributing to OMG](CONTRIBUTING.md).

## Where to report

Report problems with OMG's Quick Input, history, tabs, Inspector, editor,
Settings, Agent integration, SSH workspace features, packaging or updates here.
For terminal rendering/input problems where ownership is unclear, start with
OMG too. State whether you can reproduce the issue in official Ghostty **only
if you actually tried it**. Do not assume a shared core means the same bug exists
upstream, or send OMG-specific failures to Ghostty maintainers.

If a problem is independently reproducible in official Ghostty, follow its
[current contribution/reporting rules](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md)
when reporting there. OMG's reporting authorization does not apply upstream.

## A useful bug report

Keep one issue focused on one observable problem. Include:

1. **Expected and actual behavior.** Describe what you saw, not an inferred cause.
2. **Minimal reproduction steps** and frequency: every time, intermittent, or
   currently unknown. Say whether the problem requires a split, SSH, an Agent
   session, or particular settings.
3. **The affected application/build:** OMG version, release vs OMG Dev/source
   build, build number if available, macOS version and Apple Silicon/Intel.
4. **Time and timezone** for intermittent, performance or crash incidents.
5. **Relevant evidence:** a redacted screenshot, a short log excerpt, or the
   matching crash report. If evidence is unavailable, say so.

Use About OMG or the installed app's `Info.plist` to identify the build:

- `OMGVersion` / `CFBundleShortVersionString`: OMG release version;
- `CFBundleVersion`: build number;
- `GhosttyBaseVersion` and `GhosttyBaseRevision`: the inherited Ghostty base;
- `CFBundleIdentifier`: release and development identities are different.

Do not substitute the repository's current version for the installed version.
Do not mix logs from `OMG.app`, `OMG Dev.app`, or unrelated processes. An app's
`Contents/MacOS/omg --version` output can identify its build mode; it does not
establish that an older incident came from that same process.

Suggested title: `[OMG <version>] <short symptom>`. Use `version unknown` when
it cannot be verified. Uncertainty is better than invented metadata.

### Copyable bug-report outline

```markdown
## What happened
Expected:
Actual:

## Reproduction
1.
2.
Frequency:
Time/timezone (if relevant):

## Environment
OMG version / build:
Release, OMG Dev, or source build:
macOS / architecture:
Ghostty base version / revision (if available):
Local, SSH, Agent, split layout (if relevant):

## Evidence
Short redacted log excerpt or screenshot:
What I have already checked:

## Related issues
Full GitHub URLs, one per line; omit when none.

## AI assistance
Tool, scope of assistance, and review confirmation; omit when none.
```

You are not expected to diagnose the root cause or propose a fix. If you have a
hypothesis, label it as a hypothesis and separate it from observations.

## Logs, screenshots and privacy

**GitHub issues are public. Review everything before sharing it.**

- Redact API tokens, credentials, SSH private keys, account names, private
  repository URLs, host addresses and unnecessary personal paths.
- Terminal/Agent output, Quick Input history and screenshots can contain private
  prompts or source code. Share the smallest evidence that demonstrates the bug.
- For an incident log, use the affected process/PID or bundle/subsystem and a
  bounded time window. A default investigation window is up to ten minutes on
  either side of a known incident; if the time is unknown, start with the most
  recent ten minutes and say that it is a provisional window.
- Do not paste an entire unified-log dump, settings file, history archive or
  environment dump into an issue. Do not upload a full local log automatically.
- If logging is unavailable or macOS denies access, report that limitation;
  do not bypass permissions, silently escalate privileges, or claim logs were
  collected.
- Do not quit, replace, relaunch or profile a user's existing release/Dev app
  merely to collect a report without their consent.

Optional local incident bundles may be kept under
`~/Library/Logs/OMG/Issue Reports/<timestamp>-<app-name>/`. Use owner-only access
(directory `0700`, files `0600`). The full local path is useful to its owner, not
as a public GitHub attachment or a link other people can open.

## Feature requests

Explain the workflow, what is currently difficult, and the desired outcome.
An example helps; a large implementation design or acceptance checklist is not
required. Versions and logs are optional when proposing a new feature.

Write `not version-specific` for a request's intended scope, not `broken in all
versions` unless you have evidence. Bugs in an existing feature still benefit
from an actual affected version and reproduction steps.

## Notes and memos

A short observation, wish or task you want to remember is a valid report. Say
what should be remembered and mark it as an observation, a wish or a task;
versions, logs and reproduction steps are omitted on purpose and are added
later only when they already exist. One focused item per issue — the tracker
already holds one-line notes such as "Inspector 缺少分支查看与快速切换" — and
split several unrelated items into separate issues.

Notes are ordinary issues, so they stay public and follow the same redaction
rules as any other report.

## Security reports

Do not publish secrets or exploit details in an ordinary issue. Use GitHub's
private vulnerability reporting **if it is enabled for this repository**. If no
private reporting channel is available, ask a maintainer for one without
posting the sensitive details. This guide does not promise a currently enabled
private reporting service.

## Optional agent-assisted reporting

The checked-in [OMG Issue Report skill](../.agents/skills/omg-issue-report/SKILL.md)
is an implementation aid for this guide, not a separate source of policy.

The helper keeps a short entrypoint and loads only the report template or
evidence/submission reference relevant to the request. Its checked-in templates
follow the compact shape used by mature open-source issue forms: expected and
actual behavior, minimal reproduction, affected version/environment, bounded
evidence, related issues and AI-assistance disclosure. Those forms inspired the
layout only; OMG's own reporting, privacy and authorization rules remain the
authority here.

- Only an explicit `/skill:omg-issue-report <description>` invocation authorizes
  that helper to submit an issue directly to `jischeng/oh-my-ghostty` using local
  `gh`. By the maintainer's established workflow, this invocation is the user's
  submission authorization; no second confirmation is required.
- Ordinary debugging requests, discussion of this guide, and requests to draft
  a report are **not** permission to publish one.
- The authorization does not include creating/merging PRs, posting upstream,
  uploading raw logs, changing app state, or broader GitHub actions.
- The helper must follow applicable higher-priority instructions and use a
  reviewed, minimal factual body with redacted evidence. A skill cannot grant
  itself authority over those instructions.
- After submission, return the issue URL and any local evidence location to the
  user; return the complete filtered-log path privately, never in the public
  issue. If submission fails, retain the draft and report the failure rather
  than posting through a different tool or destination.
- When one invocation describes several unrelated items, the helper files one
  focused issue per item and returns every issue URL.

Humans can submit directly through GitHub; the local-`gh` restriction above is
for the dedicated automation helper. Review and disclose AI assistance in manual
reports. Helper-generated reports must identify the assistance and validate the
factual body/evidence under the explicit authorization above; do not imply that
a human reviewed generated details that they have not actually reviewed. The
user remains responsible for reviewing what is published.
