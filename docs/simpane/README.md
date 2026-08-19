# Simulator Pane

A live, interactive iOS Simulator inside a Ghostty window. Toggle it with
**View → iOS Simulator** (⌘⌥S) and a collapsible sidebar appears beside the
terminal: pick a device, boot it, and its screen is mirrored in the pane. Click,
scroll, and type go to the device; Simulator.app is never involved.

The device runs headlessly under `simctl`. The pane renders the device's own
framebuffer and forwards input directly to it.

```
┌───────────────────────────────┬─────────────┐
│ $ xcrun simctl launch booted  │ [iPhone 17] │
│   com.example.app             │  ⌂ 🔒 📷    │
│                               │ ┌─────────┐ │
│ …your terminal…               │ │ live    │ │
│                               │ │ device  │ │
│                               │ └─────────┘ │
└───────────────────────────────┴─────────────┘
```

## Requirements

- **macOS** with **full Xcode** installed and selected. Command Line Tools alone
  are not enough — the pane needs `SimulatorKit.framework`, which ships inside
  Xcode. Check with `xcode-select -p`; it must point inside `Xcode.app`.
- At least one **iOS runtime and simulator device** (`xcrun simctl list devices`).
- **CoreSimulator older than 1155.4** for *input*. From that version Apple routes
  the guest's HID through `dtuhidd` and legacy Indigo events are accepted and
  silently dropped, so the pane refuses to forward input rather than pretend.
  Rendering is unaffected. Check with:

  ```sh
  defaults read /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Info.plist \
    CFBundleShortVersionString
  ```

Where any of this is missing, the menu item is disabled and its tooltip says why.
Nothing else about Ghostty changes.

## Building the fork

Follow the repo's own instructions — `macos/AGENTS.md` is authoritative for the
macOS app:

```sh
zig build -Demit-macos-app=false   # produces macos/GhosttyKit.xcframework
macos/build.nu                     # builds macos/build/Debug/Ghostty.app
```

Xcode 26 ships the Metal compiler separately. If `zig build` fails with
*"cannot execute tool 'metal'"*, run:

```sh
xcodebuild -downloadComponent MetalToolchain
```

`SimPaneKit` lives in `simpane/` as a local Swift package the Xcode project
references. It builds and tests on its own:

```sh
cd simpane && swift test
```

## Using it

| Control | What it does |
|---|---|
| Device picker | Grouped by iOS version, with booted devices in a **Running** section at the top and marked with a dot. **Refresh** at the bottom; the list also refreshes when the app comes forward |
| ▶ / ⏏ | Boot and mirror, or stop mirroring — **⏏ leaves the device running** |
| ⌂ / 🔒 | Home and Lock, as hardware buttons |
| 📷 | Writes a `simctl` screenshot to the Desktop and reveals it |
| ⏺ | Records the screen to a movie on the Desktop; turns red while recording, and reveals the file when stopped |
| ⏻ | Shuts the device down |
| ⧉ | Hands the device to Simulator.app, which opens it in its own window (the pane detaches) |

There is no rotate control. Rotation is not reachable from here — see below.

**Where your keystrokes go matters.** Click the mirror and the keyboard is
routed to the device: the screen gets an accent border and the toolbar shows
`keys → simulator`. **Press Escape twice**, or click any terminal surface, to
give the keyboard back to the terminal.

Closing the pane detaches the mirror but **never shuts the device down** — it
keeps running, and reopening the pane picks it back up. Each window has its own
pane; several can mirror the same device at once.

State persists per user under a `simpane.` prefix: `simpane.paneVisible`,
`simpane.paneSplit`, `simpane.lastDeviceUDID`.

## Troubleshooting

**"CoreSimulator returned no service context" / errors mentioning
`CoreSimulatorService`.** The classic aftermath of an Xcode update: the running
service no longer matches the framework on disk. Quit Simulator.app and Xcode,
then:

```sh
launchctl remove com.apple.CoreSimulator.CoreSimulatorService
```

and reopen the pane. The pane detects this case and prints the same advice.

**The menu item is greyed out.** Hover it — the tooltip carries the reason, which
is almost always no Xcode selected, or a private class that has moved.

**Input does nothing but rendering is fine.** Either CoreSimulator is ≥ 1155.4
(see Requirements), or the guest is ignoring events because it is still booting.
A device that shows a black screen with a spinner is not ready yet.

**There is no way to rotate the device.** Rotation is not an Indigo HID event.
Simulator.app sends a *GSEvent* (`kGSEventDeviceOrientationChanged`, type 50) to
the device's `PurpleWorkspacePort`, which is a different mach port from the one
this pane uses. The client class that reference implementations reach it through,
`SimDeviceLegacyClient`, does not exist in this CoreSimulator — only
`SimDeviceLegacyHIDClient`, whose sole send method takes an
`IndigoHIDMessageStruct`. Reaching the purple port would mean looking it up and
calling `mach_msg_send` directly. Use ⧉ to hand the device to Simulator.app,
where ⌘← / ⌘→ rotate it.

**"Device shut down. Waiting for it to come back…"** The device's guest process
died. The pane reattaches by itself once the device is booted again.

**`simctl shutdown` seems to do nothing.** An attached pane holds the device
open, and the shutdown takes effect only once the pane detaches. Use the pane's
own ■ button, or close the pane first.

## A warning about private APIs

The pane reaches CoreSimulator and SimulatorKit through **private APIs**. Apple
does not support them and changes them without notice, so **expect this to break
on Xcode updates**. It is built to fail loudly and safely rather than crash:
everything is resolved by name at runtime, nothing is linked, and a missing class
or selector turns into an "unsupported" message.

When it does break:

1. Re-derive the live API surface with the recon tool that produced the current
   inventory:

   ```sh
   cd simpane && swift build && ./.build/debug/simdump --out /tmp/api-dump.txt
   ```

2. Compare against [`API-NOTES.md`](API-NOTES.md), which records every selector
   this depends on and the evidence for it.
3. All private-API access is confined to one file,
   `simpane/Sources/SimPaneKit/Private/PrivateSim.swift`. A script enforces that:

   ```sh
   cd simpane && ./Scripts/check-private-api.sh
   ```

[`DEVLOG.md`](DEVLOG.md) records how each piece was worked out, including the
dead ends — read it before assuming something was done arbitrarily.
[`ATTRIBUTIONS.md`](ATTRIBUTIONS.md) covers what was borrowed and under what
licence.
