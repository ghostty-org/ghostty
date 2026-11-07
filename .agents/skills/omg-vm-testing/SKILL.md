---
name: omg-vm-testing
description: Run Oh My Ghostty GUI and interactive verification inside the retained headless Tart VM so tests do not take over the host desktop. Use for Debug deployment, GUI smoke checks, keyboard/mouse interaction, screenshots, fullscreen behavior, and latency/throughput baselines. Do not use for unit, Zig, or selector-only tests.
---

# OMG VM testing

The retained Tart VM `omg-test` runs a macOS guest at 1512x982 (the host's
logical size). Build on the host, then deploy and exercise the app in the guest:
the host desktop is never touched and no VM window is opened.

## When to use

- Verifying OMG Dev behavior that needs windows, keyboard, mouse, screenshots,
  a shell or native fullscreen.
- Reproducing UI bugs or capturing guest screenshots/logs as evidence.
- Taking before/after latency or PTY baselines (relative comparisons only).

Do not use it for unit, Zig or selector-only tests, and do not use it for
multi-display or frame-rate acceptance.

## Workflow

```sh
macos/scripts/vm/omg-vm up
env -u SDKROOT macos/build.nu --configuration Debug --action build
macos/scripts/vm/omg-vm deploy
macos/scripts/vm/omg-vm provision     # once per VM or signing identity change
macos/scripts/vm/omg-vm smoke /tmp/omg-smoke.png
macos/scripts/vm/omg-vm desktop       # optional interactive checks and timings
macos/scripts/vm/omg-vm logs
macos/scripts/vm/omg-vm down
```

- `up` starts the VM headless through launchd, waits for SSH and the Aqua
  session, and re-applies the recorded display mode.
- `deploy` copies `macos/build/Debug/OMG.app` (bundle
  `com.jischeng.omg.debug`) and verifies its signature.
- `provision` writes the guest TCC rows for Accessibility, Screen Capture, Post
  Events and Apple Events using the deployed bundle's requirement. Re-run it
  only after the signing identity changes.
- `smoke` launches OMG, opens a fresh terminal, types a marker command through
  System Events, checks the guest marker file and saves a screenshot.
- `desktop` synthesizes HID mouse/keyboard events in the guest for drag
  selection and fullscreen, and prints launch, new-window, input and PTY
  timings.
- `down` asks the guest to halt and removes the launchd job; the disk is kept.

## Rules

- Build and test serially; do not launch OMG on the host for GUI checks.
- Never quit or replace `/Applications/OMG.app` (the release app) or the user's
  `OMG Dev`.
- The guest is disposable: deploy and restart freely, but do not delete
  `~/.tart/vms/omg-test` or the downloaded base image.
- Always `down` when the work is finished, unless the next step needs the VM.
- Capture screenshots inside the guest; do not open a host VM window and do not
  use `--vnc-experimental` (it produced black frames).

## Limits

- Tart exposes one virtual display, so multi-display behavior cannot be tested.
- Frame rate and input-to-photon latency need a host desktop run; `desktop`
  reports app-level timings only.
- The drag check assumes the default sidebar width and font, so a resized
  sidebar makes it fail instead of passing silently.
- The guest renders at 1x while the host is 2x Retina; screenshots are
  1512x982 versus 3024x1964 on the host.

## Troubleshooting

- `Guest did not halt within 45s` means the script fell back to
  `tart stop --timeout 15`; check `omg-vm logs` before trusting the next run.
- TCC denials after a rebuild usually mean the signing identity changed; re-run
  `omg-vm provision`.
- A direct AppleScript query to OMG in the guest can fail with
  `AppleEvent timed out (-1712)`; use the System Events and CGEvent paths in the
  scripts instead.

See [`macos/VM_TESTING.md`](../../../macos/VM_TESTING.md) for setup and the
recorded timings.
