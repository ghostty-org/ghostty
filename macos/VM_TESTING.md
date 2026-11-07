# macOS VM testing

Use the retained Tart VM `omg-test` to exercise Debug builds away from the host
desktop. Build on the host; the VM is used for GUI launch, keyboard input, shell
and screenshot checks. Its disk is kept when stopped, so the macOS image is
downloaded once and only the VM process is started on demand.

The VM runs with `--no-graphics`: Tart does not open a host window, while the
guest keeps its virtual display. Screenshots are taken with `screencapture`
inside the guest and copied out over SSH, so acceptance never touches the host
desktop or steals its focus.

## One-time host setup

```sh
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest omg-test
tart set omg-test --cpu 8 --memory 16384 --display 1920x1200
```

Boot the VM once with `tart run omg-test`, sign in as `admin`, enable automatic
login for that user, and keep System Integrity Protection disabled (the base
image ships with it disabled). Automatic login is required because the app and
the screenshot commands run inside the guest's Aqua session over SSH.

`omg-vm up` installs a per-host SSH key through Tart's guest agent, so no guest
password is stored by the scripts.

## Loop

```sh
# Start the retained VM on demand
macos/scripts/vm/omg-vm up

# Build on the host
env -u SDKROOT macos/build.nu --configuration Debug --action build

# Deploy, grant guest privacy permissions, and run the smoke check
macos/scripts/vm/omg-vm deploy
macos/scripts/vm/omg-vm provision
macos/scripts/vm/omg-vm smoke
macos/scripts/vm/omg-vm desktop

# Inspect guest logs and shut the VM down, keeping its disk
macos/scripts/vm/omg-vm logs
macos/scripts/vm/omg-vm down
```

`provision` writes the guest's TCC decisions for Accessibility, Screen Capture,
Post Events and Apple Events, using the designated requirement of the deployed
bundle. Run it once per VM and again after changing the signing identity;
ordinary rebuilds keep the same requirement.

`smoke` launches OMG Dev in the guest Aqua session, opens a new terminal, types
a unique `echo`/`touch` command through System Events, verifies the guest marker
file, and saves a screenshot. This covers GUI launch, key delivery, PTY shell and
the guest screenshot path.

Measured on an Apple Silicon host: `up` 14-17 s, `deploy` about 5 s, `smoke`
about 6 s, `down` about 6.5 s.

## Desktop checks

`desktop` synthesizes HID events inside the guest instead of touching the host
desktop, and prints these measurements:

- mouse drag: drags across a terminal line and verifies the copied selection
- native fullscreen: `Cmd-Ctrl-F` in and out, against the guest screen size
- launch, new-window and Return-to-shell latency
- PTY write throughput for 50,000 lines

The drag check assumes the default sidebar width and font, so a resized sidebar
makes it fail instead of silently passing. The PTY number is write throughput,
not a frame rate: rendering happens asynchronously after the shell returns.

Observed on the local 1024x768 guest: launch 1.2-3.7 s (higher when more windows
are restored), new window 0.25-0.54 s, fullscreen in 0.23-0.40 s, fullscreen out
0.66-1.11 s, Return to shell 81-90 ms and about 485k-520k PTY lines per second.

## Shutdown

`down` asks the guest to halt over SSH and then removes the launchd job. Tart
alone is not enough: a `tart stop` request can sit unanswered while the macOS
guest keeps running, and Tart 2.32.1 keeps its `run` process alive after a
guest-initiated halt, so the VM keeps reporting `running` until that process is
removed. If the guest has not halted within 45 s, the script falls back to
`tart stop --timeout 15`.

## Limits

- Do not use `--vnc-experimental` for acceptance; a local run produced black
  frames. Guest screenshots are the supported capture path.
- Tart exposes one virtual display, so multi-display behavior cannot be tested
  in this VM.
- Sidebar tab drag, multi-display behavior, frame rate and visible-input
  latency measurements still need a host desktop run; `desktop` only covers
  what can be driven from inside the guest.
- App launch in the VM costs roughly 1.5-2x the host, but the `omg +version`
  startup path is the same order of magnitude; the gap is window restoration,
  not process startup.
- The first window restored after a full stop can show a session that ended
  while the guest was powered off. The smoke command always opens a fresh
  terminal, which is the right starting point for disposable GUI checks.
- `omg-vm status` shows the Tart state and guest IP; `down` leaves the VM disk
  and the downloaded base image intact.
