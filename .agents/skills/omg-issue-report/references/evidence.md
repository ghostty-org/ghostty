# Evidence collection

Use these steps only for an existing OMG feature's bug, performance incident,
crash, rendering/scrolling problem, or another observable regression.
Feature requests do not need version or log collection.

## Target and version

- Default to release `OMG.app`. If the user names OMG Dev, another build, or
  a source build, investigate only that target. When the target cannot be
  confirmed, record `unknown`; do not silently switch applications.
- Read the installed app's `Info.plist`: `CFBundleIdentifier`, `OMGVersion` /
  `CFBundleShortVersionString`, `CFBundleVersion`, `GhosttyBaseVersion`,
  `GhosttyBaseRevision`, and the executable name. If the instance is running,
  record its PID.
- When available, run the matching `Contents/MacOS/omg --version` to confirm
  build mode. Do not launch the GUI just to guess a version. Never substitute
  the checkout's current version for the installed version.
- Keep each application, version, bundle identity, and PID in its own evidence
  set. Do not merge logs from release OMG, OMG Dev, source builds, or unrelated
  processes. An older incident is not proven to come from the currently
  installed binary merely because that binary reports a version today.
- Do not claim "all versions are affected" without evidence. A verified
  version or `version unknown` is the only safe title metadata.

## Incident time and logs

- Extract the observed symptom, incident time and timezone, user operations,
  frequency, and relevant context. Use `unknown` rather than inventing a
  reproduction.
- For performance, crash, rendering, or scrolling incidents, collect bounded
  macOS unified logs when permission allows. Prefer the affected PID; otherwise
  use the bundle/subsystem. With a known event time, start with up to ten
  minutes on either side. With an unknown time, start with the latest ten
  minutes and label the window provisional.
- If logging is unavailable, permission is denied, or the evidence is missing,
  state the limitation. Do not bypass permissions, silently escalate
  privileges, or claim that logs were collected.
- Stick to the smallest relevant, redacted excerpt in the issue. Do not paste
  an entire unified-log dump, settings file, environment dump, history archive,
  terminal/Agent transcript, or Quick Input history. Do not read private Agent
  sessions by default.
- Redact API tokens, credentials, SSH keys, account names, host addresses,
  private repository URLs, private prompts, source code, and unnecessary
  personal paths. Review screenshots with the same rule.

## Local report bundle

Store the draft and, when collected, the complete filtered log in:

```text
~/Library/Logs/OMG/Issue Reports/<timestamp>-<app-name>/
```

Create the directory with mode `0700` and files with mode `0600`. Save the
complete filtered log as `omg.log`. Return the complete local path only to the
user; never publish it in an Issue. Do not upload the full log as an attachment.

Do not quit, relaunch, replace, or profile an existing release/Dev app merely
to collect evidence. Any such change requires separate consent.

For suspected security vulnerabilities, stop before publishing. Follow the
private reporting path in `docs/REPORTING.md`; do not put secrets or exploit
details into an ordinary issue.
