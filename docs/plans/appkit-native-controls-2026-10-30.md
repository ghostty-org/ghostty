# OMG native controls follow-up - 2026-10-30

This follows `appkit-native-migration-2026-10-30.md` and the subsequent scope
confirmation in `appkit-ui-review-2026-10-30.md`.

## Scope and ownership

- Files, Git and Agent History each use one frontend for local and SSH data.
  Filesystem, executor and history-loading boundaries remain in place.
  Connection state and available actions may differ; those differences do not
  justify a duplicate remote UI.
- Native controllers own the migrated controls, keyboard handling and popup
  presentation. SwiftUI adapters still pass snapshots and actions into these
  controllers; static surrounding content may remain SwiftUI.
- Runtime recovery reconnects the existing remote session. Its explanation
  does not promise that an expired remote session can be restored. A pane with
  a runtime descriptor does not also show the legacy SSH replacement prompt.
- Ghostty's terminal search, terminal rendering and input implementation are
  unchanged. Workspace and tab controls/layout are excluded for their later
  joint integration.
- This change does not migrate all SSH connections to session runtime or
  rewrite filesystem, Git, history storage, or plugin APIs.

## Migrated surfaces

- File picker: native path input, directory table, loading/error/empty state,
  navigation and confirmation controls inside the existing sheet. The model
  accepts either filesystem backend; the local system Open panel remains an
  available entry point.
- Agent History: native search and filter controls, native transcript toolbar,
  and an AppKit-owned filter popover. Existing session and transcript tables
  remain in place.
- Git: native pull/push actions, tag and integration form controls, and
  reference-picker content, while retaining the existing Git collection and
  action/executor models.
- SSH host selection: native selection control shared by registration and
  Agent integration settings.
- Session runtime recovery: native status text and reconnect button with
  explicit pane-bound action validation.

## Acceptance

Check selection through model updates, path input during asynchronous directory
loads, marked-text handling, keyboard activation/cancellation, disabled menu
actions, and stale actions after the owning context changes. Native conversion
must retain all existing validation and mutation parameters.

Model/controller tests and compilation are distinct from physical IME, live
SSH reconnection, real popup focus in fullscreen, and actual desktop pointer
interaction. Record execution results below after validation; these latter
behaviors must not be inferred from routine test passes.

## Executed validation

- App compilation and targeted acceptance: **42 tests in 9 suites passed**.
  This includes the runtime reattachment identity test, filesystem picker
  asynchronous results and marked-text tests, History search/filter/transcript
  controls, Git dialog validation, Git reference keyboard navigation, and host
  selection identity. Log: `/tmp/omg-native-controls-acceptance-tests.log`.
- Change-selected routine regression: **1,104 tests: 1,098 passed, 5 failed,
  1 skipped**. The failing tests cover Git queue revisit timing, cached-link
  timing, workspace persistence, non-native fullscreen, and tab scroll-dispatch
  timing. The fullscreen test caused an unexpected host exit in the broad run.
  Log: `/tmp/omg-native-controls-regression-tests.log`.
- Isolated rerun of those exact five failing methods: **5/5 passed**, without
  further product-code changes. The broad run is not recorded as green; it
  retains a suite-order/timing/window-state reliability gap.
  Log: `/tmp/omg-native-controls-failure-rerun.log`.
- All 30 changed/new Swift files passed strict SwiftLint. `git diff --check`
  and `python3 dist/check_omg_docs.py` passed.
- The native Tag and integration forms were rendered and visually inspected.
  Optional test previews: `/tmp/omg-native-tag.png` and
  `/tmp/omg-native-integration.png`.

Physical IME operation, real user-host SSH reconnect, fullscreen popup focus,
and pointer-driven desktop acceptance remain unverified. Routine app-hosted
window/field-editor fixtures passed; those fixtures are not a substitute for
these live checks. The change selector explicitly excluded desktop opt-in
suites, which concern workspace/tab, Quick Input, and terminal link gestures
outside this batch.

Other inline Git browser composition, unrelated settings forms, and static leaf
content may still use SwiftUI. Existing NSAlert dialogs are already native and
were not translated again. This is the scoped controls migration, not a claim
that every OMG UI control is now AppKit.

Changes remain uncommitted in the main checkout. No installed app was replaced,
and no push, PR, or release was created for this batch.
