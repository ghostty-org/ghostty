# Attributions

The Simulator Pane is glue over Apple private frameworks. Three open-source
projects were studied during Phase 0 recon. This file records what each
contributed and under what terms.

## facebook/idb — MIT

<https://github.com/facebook/idb> · Copyright (c) Meta Platforms, Inc. and affiliates.

MIT permits reuse with attribution, so code may be ported directly.

Used as the model for:

- Resolving `"SimulatorKit.SimDeviceLegacyHIDClient"` by name and messaging it
  through a declared `@objc protocol` + `unsafeBitCast`
  (`FBSimulatorControl/HID/FBSimulatorIndigoHIDClient.swift`). This is the pattern
  our HID client follows.
- Hand-building the Indigo message rather than calling SimulatorKit's C builders
  (`FBSimulatorControl/HID/FBSimulatorIndigoHID.swift`).
- The `displayClass == 0` main-display predicate
  (`FBSimulatorControl/Framebuffer/`).
- Selecting the HID transport on the **CoreSimulator** version — the 1155.4
  `dtuhidd` cliff (`FBSimulatorControl/HID/FBSimulatorHIDSelection.swift`).
- The NSEvent keyCode → HID usage table (Phase 2).

Any file that ports idb code carries a header pointing here.

## tddworks/baguette — Apache-2.0

<https://github.com/tddworks/baguette>

Apache-2.0 is permissive, but Baguette's input approach is **not** used: it
reaches SimulatorKit's C entry points through `dlsym` + `@convention(c)` function
pointers (`Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift`), which
this project forbids on arm64e pointer-authentication grounds.

Used as **documentation only** — no code ported:

- Indigo field semantics the type encoding cannot express: button source/target
  codes (Home `0x0`, Lock `0x1`, Keyboard `0x2710`, Side `0xbb8`, Siri
  `0x400002`), event type Down `0x1` / Up `0x2`.
- Confirmation that the display and HID protocol surface is unchanged on
  Xcode 26.
- Its Xcode 26 write-ups, as a cross-check on our own runtime findings.

## b-nnett/codex-plusplus-ios-simulator — MIT

<https://github.com/b-nnett/codex-plusplus-ios-simulator>

Reviewed as a second working example. Nothing ported.

## Apple

`CoreSimulator.framework` and `SimulatorKit.framework` are Apple private
frameworks, used here without support or stability guarantees. They are loaded at
runtime via `dlopen`; nothing from them is linked, vendored, or redistributed.
Expect breakage on Xcode updates — see `API-NOTES.md` for the introspection tool
that re-derives the selector inventory.
