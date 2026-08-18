# SimPane devlog

Findings, dead ends, and decisions. Newest phase last.

## Phase 0 — Recon

### Environment

macOS 26.5.1, Xcode 26.5 (17F42), CoreSimulator **1051.54**, Apple Silicon arm64.
Runtimes iOS 18.6 / 26.3 / 26.5. Test device: iPhone 17 Pro on iOS 26.3.1.

Zig is **not installed** (`zig version` → not found). `build.zig.zon` requires
`minimum_zig_version = "0.16.0"`. Not needed before Phase 4; flagged now so it is
not a surprise then.

The working tree at `~/Downloads/ghostty-main` is **not a git repository**, so the
"commit at each acceptance gate" rule cannot be honoured as written. Raised at the
Phase 0 gate rather than running `git init` unilaterally.

### Dead end 1 — enumerating ObjC classes crashed the tool

`objc_copyClassList` imports into Swift as `AutoreleasingUnsafeMutablePointer`,
and subscripting that runs a Swift dynamic cast per element, which messages every
registered class. With both private frameworks loaded (~59,000 classes) some
unrelated CloudKit class trapped in `___forwarding___` and the process took
SIGTRAP.

Crash frames were `allClassNames() → swift_dynamicCast → swift_getObjectType →
_CF_forwarding_prep_0 → __forwarding__ → CloudKit`.

Fix: enumerate per image with `objc_copyClassNamesForImage`, which returns C
strings and never touches a class object. Better anyway — it gives per-framework
provenance, which is how we learned SimulatorKit ships exactly 48 classes.

**Lesson:** in this codebase, prefer C runtime calls that return strings over
anything that hands Swift a `Class`.

### Dead end 2 — KVC aborts on CoreSimulator's XPC proxies

`io.ioPorts` returns `ROCKRemoteProxy` objects. `[proxy valueForKey:@"state"]`
raised `NSUnknownKeyException` for a key the proxy answers fine over the wire, and
Swift cannot catch ObjC exceptions, so the process aborted.

Worse, `-respondsToSelector:` on these proxies answers **optimistically** — it is
not a usable existence test.

Fix: added `Sources/SimPaneObjC` (`SPObjC`), which does everything through
`-methodSignatureForSelector:` + `NSInvocation` inside `@try/@catch`, boxing
scalar and struct returns. `-methodSignatureForSelector:` performs a real remote
lookup, so a non-nil signature is the trustworthy existence test.

This target is not throwaway: the shipping code needs the same exception barrier,
so it will be reused by `SimPaneKit` in Phase 3.

### Decision — match ports on protocol conformance, not class name or index

ROCK proxy class names are generated per connection and *concatenate the remote
object's protocol list*, e.g.
`ROCKRemoteProxy-<uuid>-SimScreen-SimDeviceIOPortDescriptorInterface-ROCKImpersonateable-SimDisplayIOSurfaceRenderable-…`.
Tempting to string-match, but the proxy also exposes `protocols` programmatically,
which is stable and readable. The 13 ports' ordering is not contractual.

### Finding — arm64 is enough; no arm64e helper needed

Both frameworks are `x86_64 + arm64e` with no plain arm64 slice, yet both `dlopen`
cleanly from our plain arm64 binary and dispatch works. Ground rule 5's premise
holds and the Baguette-style separate helper process is not required.

### Finding — SimulatorKit is now a Swift framework

Its classes carry module-qualified ObjC names (`SimulatorKit.SimDeviceLegacyHIDClient`).
Every published header dump names the bare class, and `NSClassFromString` on the
bare name returns `nil` **silently**. This is why the first HID probe reported
"absent" — the class was there the whole time under a different name.

### Screen path — proven live

Main display = descriptor conforming to `SimDisplayIOSurfaceRenderable` **and**
`descriptor.state.displayClass == 0`. Both halves matter: a second descriptor has
`displayClass == 1` (external display) and would otherwise match.

idb's `displayClass == 0` predicate survives on Xcode 26.5.

Measured on the booted iPhone 17 Pro:

```
displaySize 1206x2622, pitch 460, 12763136 bytes
framebufferSurface -> IOSurface 1206x2622, bytesPerRow 4864, pixelFormat 'BGRA'
damage callbacks: 162 in 3.0s = 54/s
ioSurfacesChange callbacks: 0
```

Reproduced across runs: **54/s and 50.3/s while apps were launching, 0/s with the
device idle.** The zero is the correct behaviour, not a failure — these are damage
notifications, not a frame clock, so a static screen produces none. Any FPS
readout in the UI has to present that honestly rather than looking hung.

50–54/s clears the ≥30 fps gate with no polling fallback needed. `bytesPerRow` 4864
exceeds `width*4` = 4824, so the surface is **row-padded** — a hand-rolled bitmap
path would tear. Using `CALayer.contents` with the `IOSurface` object sidesteps it.

Selector spelling drifted: it is `ioSurfacesChangeCallback:` (**plural**) here;
the singular spelling in older references does not exist. Zero surface-change
callbacks during the sample is expected — that signals a surface *swap*
(rotation/resize/reboot), not a frame.

Neither register selector takes a queue, so the callback thread is arbitrary.
`SimScreen` on the same descriptor offers a combined registration *with* an
explicit `callbackQueue` — noted as the Phase 3 upgrade path, deliberately not
taken now because the simpler pair is what Phase 0 proved.

### Input path — the version cliff is the whole story

`SimDeviceLegacyClient` (idb's older class, and the one every header dump names)
is **absent**. The live replacement is `SimulatorKit.SimDeviceLegacyHIDClient`,
and `alloc` + `initWithDevice:error:` against the booted device **succeeds**.

idb selects its HID transport on the **CoreSimulator version**, not iOS version
(`FBSimulatorHIDSelection.swift`): from **1155.4** (Xcode 27) the guest hands its
legacy HID services to `dtuhidd`, after which Indigo messages are *"delivered
byte-correctly and then dropped"* — silent failure, no error.

This machine is **1051.54**, and no `dtuhidd` binary exists anywhere in Xcode.app.
So legacy Indigo is correct here. Recorded as risk #1: a future Xcode upgrade
kills input with no error, so we check the version at startup and refuse rather
than appear broken.

### Decision — hand-build the Indigo message (idb's way), not Baguette's

Baguette calls SimulatorKit's C builders via `dlsym` + `@convention(c)`
(`IndigoHIDInput.swift:28-62`). Ground rule 5 forbids raw C function pointers from
these frameworks, so its input path is **off-limits as an implementation**, though
it remains the best documentation of field semantics (button codes, edge flags)
and its Apache-2.0 licence permits that with attribution. It also hard-targets
Xcode 26 with no version branch, so it would not degrade gracefully for us.

idb (MIT) does exactly what our rules require: resolve the class by name, declare
an `@objc protocol`, `unsafeBitCast`, send. It independently arrived at the same
class name this machine reports.

### Finding — the struct layout is recoverable from the runtime

The full `IndigoHIDMessageStruct` definition is embedded in the ObjC type encoding
of `sendWithMessage:freeWhenDone:completionQueue:completion:`. Decoding it with
`NSGetSizeAndAlignment` gives authoritative sizes for *this* Xcode, which beats
any checked-in header:

```
base struct 32 B  (24 B mach header, uint32 innerSize @24, uint8 eventType @28)
payload element 168 B, align 8  -> single-event message = 200 B
_event union 128 B; _touch_event 128 B; _button_event 24 B; _extended (kbd) 88 B
```

`simdump` re-derives this automatically, so an Xcode update is a re-run rather
than a re-investigation. Field *semantics* are still not recoverable from the
encoding and remain the open question for Phase 2.

### Unexplored, deliberately

SimulatorKit ships `SimDisplayView`, `SimDigitizerInputView` and
`SimKeyboardInputController` — Apple's own rendering and input views. Embedding
`SimDisplayView` could make Phase 1 nearly free. Not pursued because their members
are Swift-only (not `@objc`), so they cannot be driven through ObjC dispatch, and
the plan's approach is fixed. Worth a look only if the CALayer path disappoints.

### Artifacts

- `research/api-dump.txt` — 5,681-line live dump (gitignored)
- `research/notes/*.md` — nine reference-repo studies (gitignored)
- `simpane/Sources/SimDump/main.swift` — the introspection tool
- `simpane/Sources/SimPaneObjC/` — ObjC dispatch + exception barrier
- `docs/simpane/API-NOTES.md` — the selector inventory

## Phase 1 — Read-only live mirror

`SimPanePOC` is a plain SwiftPM executable (no bundle, no storyboard) that boots
or attaches to a device and shows its screen in an `NSView`.

```
swift build
./simpane/.build/debug/SimPanePOC                 # mirror the booted device
./simpane/.build/debug/SimPanePOC --list          # devices
./simpane/.build/debug/SimPanePOC --snapshot f.png  # one frame, headless
./simpane/.build/debug/SimPanePOC --stats 6       # callback rate, headless
```

### Which repaint nudge is required — measured, not assumed

The plan flagged this as an open question, and it had three plausible answers.
Reassigning `contents`, marking the layer dirty, or nothing at all — since
CoreAnimation samples the IOSurface on the render server, "nothing" was a real
possibility. Added `SIMPANE_NUDGE` to switch modes, then for each: capture the
window, switch the guest app, capture again, pixel-diff.

| Mode | Differing samples | Verdict |
|---|---|---|
| `contents` — reassign `layer.contents` | 433 / 1169 | **live updates** |
| `needsDisplay` — `layer.setNeedsDisplay()` | 2 / 1169 | stale |
| `none` — bind once, never touch | 1 / 1169 | stale |

**Reassigning `layer.contents` with the same IOSurface is what makes
CoreAnimation re-read it.** `setNeedsDisplay` does nothing because the layer has
no drawing of its own (`layerContentsRedrawPolicy = .never`), and binding once
leaves the first frame frozen forever. The one or two differing samples in the
failing modes are the status-bar clock area, not real updates.

The switch is left in the code so this is re-testable after an OS update rather
than being a comment someone has to trust.

### No display link — damage drives the pump

Ghostty's Xcode project targets **macOS 13.0**, so `NSView.displayLink(target:selector:)`
(14+) is unavailable, and `CVDisplayLink` is deprecated from 15. Since damage
callbacks already arrive at 40–70/s, they drive the pump directly:

- damage callback (arbitrary thread) sets a flag and, if no repaint is already
  scheduled, does one `DispatchQueue.main.async`
- the main-queue drain reassigns `contents` once per batch

That coalesces bursts, never runs faster than the guest paints, and idles at zero
work when the screen is static. Measured `presented fps` tracks `damage/s`
exactly, which confirms it drops nothing and never presents redundantly.

`ioSurfacesChange` is handled separately and re-reads `framebufferSurface`,
deliberately ignoring the callback's argument — the payload shape is not
contractual but the property always reports the current surface.

### Measurements

```
surface           1206x2622 BGRA
window            359x812 pt, aspect preserved by contentsGravity = .resizeAspect
presented fps     20-72, typically 40-70 while apps animate; 0 idle
headless --stats  37.6/s and 39.5/s over multi-second windows
CPU               0.0% idle
RSS               ~73 MB
```

### Acceptance gate — all four items

1. Live device screen visible in the window.
2. `xcrun simctl launch booted com.apple.mobilesafari` from a separate process
   appeared in the open window without reattaching.
3. Sustained well above the 30 fps target.
4. Quitting left the device `Booted`, still able to launch apps, and a fresh
   attach worked immediately.

### Tooling note — capturing the window

`screencapture -x <file>` fails with *"could not create image from display"*
because the terminal lacks Screen Recording permission. Capturing a **specific
window id** works regardless:

```sh
WID=$(python3 -c "import Quartz; ...")   # CGWindowListCopyWindowInfo
screencapture -x -o -l"$WID" out.png
```

Worth keeping for Phase 4, where the same trick verifies the embedded pane.

### Deliberately deferred

- `SimScreen`'s combined registration with an explicit `callbackQueue` — the
  simpler protocol pair is what Phase 0 proved, so it stays until there is a
  reason to change.
- Metal. The CALayer path costs one property assignment per frame and idles at
  0% CPU, so `CAMetalLayer` would buy nothing.
- Occlusion pausing is wired to `windowDidChangeOcclusionState` but not yet
  measured; Phase 5 covers that.

## Phase 2 — Input forwarding

Status: **complete.** All four input classes work reliably; the acceptance gate
passes end to end.

### The approach both references use is disallowed here — and we did not need it

Phase 0 recorded that idb messages `SimDeviceLegacyHIDClient` through a declared
`@objc protocol`, which is what ground rule 5 asks for. That is true of the
**send**, and only the send. For **building** messages idb resolves
`IndigoHIDMessageForButton`, `IndigoHIDMessageForMouseNSEvent`,
`IndigoHIDMessageForKeyboardArbitrary` and `IndigoHIDMessageForTrackpadMoveEvent`
with `dlsym` and calls them as raw C function pointers
(`FBSimulatorIndigoHID.swift:19-52`) — exactly what Baguette does, and exactly
what rule 5 forbids. idb even notes that SimulatorKit has no single-touch builder
at all, so it calls the multi-touch one and re-envelopes the result by hand.

**Correction to the Phase 0 note:** neither reference satisfies rule 5 for
message construction. So rather than stopping, the message was built from scratch
in Swift, using idb's MIT-licensed `Indigo.h` for the layout and Baguette's notes
for field semantics. **It works.** `SimPaneCore.IndigoWire` emits touch, button
and key messages with no C function pointer anywhere, which is a cleaner result
than either reference achieves under our constraints.

### The layout is packed, and the Phase 0 sizes were wrong

`simdump` decodes the struct from the live method signature with
`NSGetSizeAndAlignment`, which applies natural alignment. The real struct is
`#pragma pack(push, 4)`. The Phase 0 note's "168-byte payload, 200-byte message"
was therefore wrong in a way that would silently produce messages the guest
ignores. Correct, and confirmed by messages the guest acts on:

```
IndigoPayload   0x90        button/key message  0xC0 total, innerSize 0xA0, 1 payload
timestamp @+0x04 (unaligned) single touch        0x140 total, innerSize 0x90, 2 payloads
```

API-NOTES.md carries the full corrected field table. The lesson: a type encoding
gives you field *types and order*, never offsets, unless you also know the
packing.

### Keyboard: HID usages, not virtual key codes

idb's header describes the keycodes as "hardware independent … HIToolbox", i.e.
`NSEvent.keyCode`. Sending those produced `668k[e2=` for an intended `apple.com`.
Every character decodes exactly as the **USB HID Usage Page 0x07** value with
that number — `0x23`→6, `0x25`→8, `0x0E`→k, `0x2F`→[, `0x08`→e, `0x1F`→2,
`0x2E`→=. So the guest reads HID usages. `SimPaneCore.KeyMap` does the
translation and `apple.com` then types correctly.

A wrong guess that decodes perfectly is the cheapest possible diagnostic; it is
worth sending deliberately-wrong input once to find out what a black box expects.

### What is proven to work

Each verified by screenshotting the framebuffer before and after and diffing:

- **Tap** — tapping the Settings row opened General; tapping the Settings icon on
  the home screen launched it.
- **Drag** — a vertical drag scrolled a settings list; the coordinate mapping
  lands where intended.
- **Hardware buttons** — Home returned to SpringBoard from an app, Lock and Siri
  both produced their expected screens. Side and Apple Pay do nothing on this
  device, which is expected.
- **Keyboard** — `apple.com` typed into Safari's address bar.

21 unit tests pin the wire format, the coordinate mapping (including letterbox
rejection and Y orientation) and the keycode table. `swift test` is green.

### Two real defects, both in our code

Input worked for a gesture or two and then went silent, with the send reporting
success. Two independent bugs, found by building a soak that runs many actions
through **one** client in **one** process — the shape the product uses, and the
one thing none of the earlier tests did (they spawned a process per action).

**1. The lift mask omitted the touch bit.** `IndigoTouch.eventMask` reports which
fields *changed*. On lift both `range` and `touch` go 1 → 0, so both bits belong
in the mask. Our `.up` used `Range|Identity` (`0x21`), copied from idb's trackpad
"ended" phase. The guest therefore never saw the contact lift, believed a finger
was still down, and ignored everything afterwards — accepting each message
without error. Sweeping the mask over a rebooted device made it unambiguous:

| lift mask | second gesture |
|---|---|
| `0x21` Range,Identity | ignored |
| `0x23` Range,Touch,Identity | lands |
| `0x27` + Position | lands |
| `0x03` Range,Touch | lands |

Every value containing `0x02` works. We use `0x23`, the minimal correct set, and
a test pins it.

**2. Hardware button presses were never released.** `press()` scheduled the
button-up with `DispatchQueue.main.asyncAfter`. Whenever the caller was spinning
a nested runloop the block never ran, so Home and Lock stayed held down — and a
held hardware button makes the guest ignore all further input. The instrumented
log made it obvious: **5 button downs, 0 button ups.** Both halves now run on a
queue of their own, off the main thread, with a real sleep between them.

A third, milder issue was also fixed: the mach port backing the session drops
(reported as `Mach port not connected, device may not be ready yet`).
`IndigoHIDClient` now resets the session, retries, and rebuilds the client if
that is not enough. Sends are serialized with a lock, since touches arrive on the
main thread and buttons on the button queue.

### Reliability after the fixes

- taps only, one client: **20/20**
- taps + drags + buttons interleaved: **24/24**
- full acceptance script: every action responds; repeated runs stay green
  without rebooting the device

### Wrong turns worth recording

- **The harness hid the diagnosis for a long time.** Test steps redirected stderr
  to `/dev/null`, so `Mach port not connected` — the one message that explained
  everything — was invisible for many rounds of A/B testing. Several confident
  conclusions drawn in that period (that display callbacks broke HID, that drags
  wedged the digitizer, that touch worked only once per boot) were artefacts of
  comparing runs against an already-broken device. **Never discard stderr from
  the thing under test.**
- **Priming.** A message sent immediately after attaching is sometimes dropped, so
  the client spends an inert one to open the channel. The first attempt used a
  lone touch-*up*, which is a bad choice: repeated on every attach it can leave
  the guest's digitizer with a phantom contact. It is now a key-up for the
  reserved HID usage 0, which cannot mean anything.
- **Callback UUIDs must be distinct.** The two display registrations originally
  shared one `NSUUID`. They are separate registrations with separate unregister
  selectors, so they need separate handles.
- **Do not block the main thread while driving input.** The UI test originally
  used `Thread.sleep`; it now pumps the runloop.
- Tapping with zero hold does nothing — iOS ignores a zero-duration contact. The
  scripted tap holds 60 ms.

- **A bad oracle cost two rounds of wrong conclusions.** The screen-change check
  first sampled every 4093rd byte, which misses real changes and reports a false
  "unchanged"; the status-bar clock ticking over could also read as a change. It
  now samples every 97th byte, skips the top of the screen, and compares a
  fraction rather than a hash. Several "intermittent failures" evaporated once it
  was accurate. Trust a measurement before trusting what it says about the code.

### Acceptance gate

`./simpane/.build/debug/SimPanePOC --uitest <dir>` drives the real view with
synthesized NSEvents and prints a screen delta per action, so a regression names
itself instead of showing up as a blank screenshot:

```
home            swipe page      home            tap Settings    scroll list
home            tap address bar type apple.com  lock            wake
swipe to unlock
```

Against the gate's requirements: dragging pages the home screen, tapping opens
Settings, dragging scrolls its list, tapping Safari's address bar and typing
loads apple.com, Home returns to SpringBoard, Lock then unlock works.

A `0.0%` reading is not automatically a failure — pressing Home while already on
the home screen, or reloading a page Safari already had open, legitimately
changes nothing. Read the screenshots, not just the deltas.

Diagnostics kept for future regressions:

- `--soak N` — N iterations through one client, per-action pass/fail.
  `SIMPANE_SOAK_DRAGS=1` interleaves drags with taps and buttons.
- `--probe <gap>` — one gesture, a pause, a second gesture. This is what proved
  the failure was not an idle timeout.
- `SIMPANE_DEBUG_INPUT=1` — logs every message with coordinates and outcome. This
  is what exposed the missing button-ups.

## Phase 3 — Extract SimPaneKit

Goal: turn the POC into the reusable library the Ghostty fork will consume.

### Shape

| Target | Contains | Private API |
|---|---|---|
| `SimPaneCore` | Indigo wire format, coordinates, keycode table | none |
| `SimPaneObjC` | ObjC dispatch + exception barrier | none by itself |
| `SimPaneKit` | the library: session, view, input, lifecycle | one file |
| `SimPanePOC` | proof the public API suffices, plus diagnostics | none |

`SimulatorSession` is the only type a host needs. It owns lifecycle (`simctl`),
the display, the HID client, and the view.

### The shim boundary is checked, not asserted

`Sources/SimPaneKit/Private/PrivateSim.swift` is the only file that names a
private class, resolves a selector by string, or dlopens anything. It absorbed
Phase 2's `IndigoHIDClient`, which had been naming
`SimulatorKit.SimDeviceLegacyHIDClient` on its own.

`Scripts/check-private-api.sh` encodes ground rule 4 so Phase 4 cannot quietly
break it. `SimDump` is exempt and says so: dumping private API is its whole job.

### The view now exists before a device does

Phase 2's view was constructed from a live `SimDisplay`, so it could not exist
until a device was booted and attached. A pane in a terminal window has the
opposite lifetime — it is installed once and outlives any particular device — so
the view is now created empty and `bind`/`unbind` attach a display to it. That is
what makes `mirrorView` a stable `NSView` a host can install and forget.

### Rendering pauses itself

Phase 2 made the *host* remember to set `isRenderingEnabled` from
`windowDidChangeOcclusionState`. The view now watches its own window occlusion,
its own hidden state, and re-checks in `layout()` — the catch-up for window
states that never post an occlusion notification.

Proven, not assumed: `SIMPANE_OCCLUSION_TEST=1 SimPanePOC` miniaturizes itself
mid-run and reports frames presented in each state. With the guest painting
throughout: **visible 38, hidden 0, restored 59.**

### Two real bugs the extraction surfaced

**The focus border never drew.** `draw(_:)` painted it, but the view sets
`layerContentsRedrawPolicy = .never`, so AppKit never called `draw(_:)`. It has
been dead code since Phase 2. The view now uses explicit sublayers — a content
layer whose frame *is* the content rect, a border layer, and a status layer.
Rendering and hit-testing therefore share one rect instead of each computing the
letterbox separately (`contentsGravity = .resizeAspect` versus
`Coordinates.contentRect`).

**`runBlocking` deadlocks once AppKit is running.** The POC awaits async library
calls from synchronous code by pumping a nested runloop. That drains the main
queue while AppKit's own loop is idle — which is why every pre-`NSApp.run()` use
worked — but not once `NSApp.run()` is running. The UI test then blocked the main
thread waiting for work that needed the main actor, and hung after step 5. A
`sample` of the hung process showed the main thread parked in
`RunLoop.runMode:beforeDate:` with the awaited task never scheduled.

Fixed in three places, because one fix would only have moved it:

1. `SimulatorSession` owns the HID client instead of reading it back off the
   main-actor-isolated view, so scripted input never needs the main thread.
2. `UITestRunner` is `async` throughout — every pause is an `await`, never a
   blocked main thread.
3. `runBlocking` now asserts `!NSApplication.shared.isRunning`, turning a silent
   hang back into a stack trace.

### Acceptance gate

`swift test` — **33 tests, 0 failures** (21 SimPaneCore, 12 SimPaneKit).
`Scripts/check-private-api.sh` — clean. Clean build, **0 warnings**.

The full UI script through the library, on a device nothing else was touching:

```
home 0.0%          swipe page 23.5%   home 23.5%       tap Settings 70.6%
scroll list 38.2%  home 70.6%         tap address bar 66.8%
type apple.com 66.4%   lock 71.9%     wake 73.8%       swipe to unlock 4.2%
```

Frame pump: **56 damage/s, 48 fps presented** while the screen is changing;
**0/s when the guest is idle** — iOS does not paint a static home screen, which
is why an idle pane costs nothing.

### A contaminated measurement, caught the second time

The first Phase 3 gate run showed `swipe to unlock` at 0.5% and extra soak
misses. A hung *pre-fix* POC process from the deadlock investigation was still
alive, holding a second HID client. Every reading taken while it lived is
worthless. Phase 2 recorded exactly this failure mode; it recurred anyway
because "did I leave a process running" is not something a delta tells you.
`pgrep -f SimPanePOC` before measuring, always.

### Open: unlock-after-lock, a guest behaviour

On a freshly booted device the unlock swipe works. After a lock/wake cycle in the
same session the same swipe moves the lock screen ~4% and snaps back — and it
fails **identically through the scripted path and the NSEvent path**, which is
what rules out the extraction as the cause. `IndigoWire` is byte-for-byte the
Phase 2 code with the same tests pinning it, and every other drag (home paging,
Settings scrolling, soak drags) works. Recorded as a device behaviour to revisit
in Phase 5, not a blocker.

### Diagnostics kept

- `--soak N`, `SIMPANE_SOAK_DRAGS=1` — as before, now with
  `SIMPANE_SOAK_SNAPSHOTS=<dir>`, which captures the screen whenever an action
  reads UNCHANGED. A delta cannot distinguish "input dropped" from "tap landed
  somewhere inert"; guessing between those cost a day in Phase 2.
- `--probe <gap>`, `--uitest <dir>`, `SIMPANE_DEBUG_INPUT=1`, `SIMPANE_NUDGE`.
- `--screenshot <png>` — `simctl` capture, alongside `--snapshot`, which reads the
  framebuffer we actually render. Keeping both is deliberate: one is exact, the
  other proves our render path.

### Not done

`swiftlint` is not installed on this machine, so CLAUDE.md's Swift formatting
step could not be run against these sources.

## Phase 4 — Ghostty integration

### Step 0 — integration note (written before any code, per the plan)

#### How the app builds

`zig build` produces `macos/GhosttyKit.xcframework`; the Xcode project links it
as a plain file reference. **It does not exist in this tree**, so the Xcode
project cannot build at all until Zig has run once.

`macos/AGENTS.md` is stricter than the root `CLAUDE.md` and wins for this
directory:

- Build the app with `macos/build.nu`, **not** `zig build`.
- Use `zig build -Demit-macos-app=false` only to refresh the underlying library
  after changing anything outside `macos/`.
- Output lands in `macos/build/<configuration>/Ghostty.app`.
- Unit tests: `macos/build.nu --action test`.

Neither `zig` nor `nu` is installed on this machine. Homebrew offers
`zig 0.16.0`, which is exactly `build.zig.zon`'s `minimum_zig_version`.

The `Run SwiftLint` build phase is a no-op when swiftlint is absent, so its
absence will not fail the build.

#### How a terminal window composes its content view

```
NSWindow.contentView
└── TerminalViewContainer            (NSView; owns the liquid-glass layer)
    └── NSHostingView
        └── TerminalView             (SwiftUI root)
            └── ZStack
                ├── VStack { DebugBuildWarningView?, TerminalSplitTreeView }
                ├── TerminalCommandPaletteView
                └── UpdateOverlay
```

`TerminalController.init` builds the container and assigns
`window.contentView`. The controller is the `TerminalViewModel` *and* the
`TerminalViewDelegate`, so per-window state belongs on it.

The sidebar therefore goes **inside the ZStack's first child**, wrapping the
`VStack` in an `HStack`, so the command palette and update overlay keep floating
above it.

#### How an auxiliary surface is already hosted — the inspector

`Ghostty.InspectorView` is the precedent to copy, and it matches what SimPaneKit
already does:

- An AppKit `NSView` bridged into SwiftUI with `NSViewRepresentable`.
- Hosted beside the terminal inside `SplitView`, which takes a
  `@Binding var split: CGFloat` — that is the resizable-sidebar mechanism, no
  new UI needed.
- Focus via `@FocusState` plus `becomeFirstResponder`/`resignFirstResponder`.
- **Rendering paused on occlusion using `NSWindow.didChangeOcclusionStateNotification`,
  filtered on `window == self.window`** — the identical pattern SimPaneKit
  arrived at independently in Phase 3. Nothing to reconcile.
- Toggled by `@IBAction func toggleTerminalInspector(_:)` on `TerminalController`,
  dispatched through the responder chain from a First Responder menu item.

#### What this means for the work

**Adding Swift files needs no project-file edit.** The Ghostty target uses
`fileSystemSynchronizedGroups` for `macos/Sources`, so anything dropped in there
is compiled automatically. Only the SimPaneKit *package* reference needs a
`project.pbxproj` edit: an `XCLocalSwiftPackageReference` plus an
`XCSwiftPackageProductDependency` in the Ghostty target's
`packageProductDependencies` (today it holds only Sparkle).

**No `@available` gating is needed after all.** The Xcode targets deploy to
13.0/13.1 and SimPaneKit is `.macOS(.v13)`, so it simply links. The Phase 3 note
predicting `@available` walls was wrong — keeping the package at Ghostty's floor
removed the problem instead of moving it.

#### Menu item and shortcut

`View → Terminal Inspector` is the last item in the View menu; the simulator
pane goes below it after a separator, as `View → iOS Simulator`, wired to a new
`@IBAction func toggleSimulatorPane(_:)` on `TerminalController` exactly like the
inspector.

Shortcut: **⌘⌥S**. Reasoning, since the plan asks for it explicitly:

- Ghostty's own defaults were extracted from `Config.zig`'s `Keybinds.init`.
  The `cmd`-prefixed set in use is: `, - = 0 [ ] a d e f j k n q t w z`,
  arrows/page/home/end/backspace/enter/escape, `cmd+alt+{i,w,arrows}`,
  `cmd+shift+{, [ ] d enter f g j p t v w z}`, `cmd+shift+alt+{j,w}`, plus
  `cmd+1…9` for tabs. **`cmd+alt+s` is free.**
- It parallels `⌘⌥I` for the inspector — same "auxiliary pane" family, which is
  the point.
- It does not collide with Simulator.app's conventions (⌘⇧H Home, ⌘L Lock), and
  those stay as sidebar buttons rather than menu shortcuts anyway.

The shortcut is a **static `keyEquivalent`**, not a Ghostty keybind action.
Routing it through `MenuShortcutManager` would mean adding an action to the Zig
config system, which the plan forbids in v1. No existing binding changes.

#### Persistence

`UserDefaults.ghostty`, not `.standard` — Ghostty redirects to a test suite via
`GHOSTTY_USER_DEFAULTS_SUITE` in debug builds, and using `.standard` would leak
state past that. Keys: `simpane.paneVisible`, `simpane.paneWidth`,
`simpane.lastDeviceUDID`.

#### Degradation

`validateMenuItem(_:)` disables the item and sets the `.toolTip` to
`SimulatorSession.support().reason` when unsupported. Nothing else changes: the
sidebar is never constructed, and SimPaneKit dlopens nothing until asked.

### Blocked before any code lands

Ground rule 2 says both builds must succeed after every Phase 4 commit. With no
Zig there is no `GhosttyKit.xcframework`, so **no part of the integration can be
compiled, let alone run**. Writing unverifiable Swift into Ghostty's tree is
exactly what that rule exists to prevent, so the code is not being written yet.

Needed to proceed:

1. `brew install zig` (0.16.0, matches `minimum_zig_version`) — hard blocker.
2. `brew install nushell` for `macos/build.nu` — the documented build path.
3. A decision on source control: the tree is not a git repository, so the
   plan's "commit at each acceptance gate" cannot be honoured.
