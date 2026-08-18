# SimPane — Private API Notes

Ground truth for the CoreSimulator / SimulatorKit surface **as it exists on this
machine**, derived by runtime introspection rather than from checked-in headers.
Everything below was observed live, not inferred from a reference repo.

Re-derive after any Xcode update:

```sh
cd simpane && swift build
cd .. && ./simpane/.build/debug/simdump --out research/api-dump.txt
```

`simdump` needs a booted device (`xcrun simctl boot <udid>`); pass `--udid` to pick
one explicitly. It dumps every class in both frameworks, walks the live IO ports,
proves the framebuffer can be acquired, samples the damage-callback rate, and
decodes the Indigo message layout out of the live method signature.

## Environment this was captured on

| | |
|---|---|
| macOS | 26.5.1 (25F80) |
| Xcode | 26.5 (17F42), `/Applications/Xcode.app/Contents/Developer` |
| **CoreSimulator** | **1051.54** |
| Host arch | arm64 (Apple Silicon) |
| Device under test | iPhone 17 Pro, iOS 26.3.1 (23D8133) |
| Runtimes installed | iOS 18.6, 26.3, 26.5 |

The CoreSimulator version is the single most important number here — it decides
the HID transport (see §C).

## Framework loading

| Framework | Path |
|---|---|
| CoreSimulator | `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator` |
| SimulatorKit | `$(xcode-select -p)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit` |

Both are universal `x86_64 + arm64e` with **no plain arm64 slice**, and both
`dlopen` cleanly from a plain **arm64** process (`RTLD_LAZY | RTLD_GLOBAL`),
registering ~49,800 additional ObjC classes. Loading CoreSimulator first is not
required — SimulatorKit pulls it in — but we do it explicitly so a failure is
attributable.

No arm64e helper process is needed. Ground rule 5's premise holds: ObjC message
dispatch into these frameworks works from arm64.

### SimulatorKit is now a Swift framework

Its 48 classes carry Swift module-qualified ObjC names. This is the single
biggest drift from every published header dump, and looking up the bare name
silently returns `nil`:

```
SimulatorKit.SimDeviceLegacyHIDClient     (mangled: _TtC12SimulatorKit24SimDeviceLegacyHIDClient)
SimulatorKit.SimDeviceScreen              SimulatorKit.SimDisplayView
SimulatorKit.SimDigitizerInputView        SimulatorKit.SimKeyboardInputController
SimulatorKit.SimDisplayRenderableView     SimHIDCaptureManager   (not module-qualified)
```

`NSClassFromString` works with **either** the module-qualified name or the
mangled `_TtC…` name; prefer the readable one.

## Everything is an XPC proxy — two consequences

`SimDeviceIOClient.ioPorts` returns objects whose class is generated per
connection, e.g.

```
ROCKRemoteProxy-9BF5BA20-…-SimScreen-SimDeviceIOPortDescriptorInterface
  -ROCKImpersonateable-SimDisplayIOSurfaceRenderable
  -SimDisplayResizeableRenderable-SimDisplayRenderable
```

The class name is a concatenation of the remote object's protocol list, and the
proxy also exposes that list programmatically through its `protocols` property.
**Match on protocol conformance, never on class name or port index** — the order
of the 13 ports is not contractual.

Two traps, both hit during Phase 0:

1. **KVC raises.** `[proxy valueForKey:@"state"]` throws `NSUnknownKeyException`
   even for keys the proxy answers fine over the wire. Swift cannot catch that,
   so it aborts the process. Use `NSInvocation`, never KVC.
2. **`-respondsToSelector:` over-reports.** ROCK proxies answer optimistically.
   The trustworthy existence test is
   `[target methodSignatureForSelector:] != nil`, which performs a real remote
   lookup.

Both are handled in `Sources/SimPaneObjC/SimPaneObjC.m` (`SPObjC`), which is also
where ObjC exceptions get converted to `NSError` so a private-API surprise cannot
kill the host process.

---

## A. Service context and device lookup

```objc
// Class: SimServiceContext  (CoreSimulator, plain ObjC)
+ (SimServiceContext *)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)err;
- (SimDeviceSet *)defaultDeviceSetWithError:(NSError **)err;

// Class: SimDeviceSet
@property (readonly) NSArray<SimDevice *> *devices;

// Class: SimDevice
@property (readonly) NSUUID *UDID;
@property (readonly) NSString *name;
@property (readonly) unsigned long long state;   // 0 Creating 1 Shutdown 2 Booting 3 Booted 4 ShuttingDown
@property (readonly) SimRuntime *runtime;        // .name .versionString .buildVersionString
@property (readonly) SimDeviceType *deviceType;  // .name .identifier
@property (readonly) SimDeviceIOClient *io;
```

`dir` is the output of `xcode-select -p` verbatim. Confirmed live: 29 devices
enumerated, booted device resolved, runtime reported as `iOS 26.3 / 26.3.1 /
23D8133`.

Per the plan, device **lifecycle** still goes through `xcrun simctl boot/shutdown`
— it is the stable surface. These selectors are for discovery and for reaching
`io` only.

## B. Screen — main display, IOSurface, and callbacks

### Finding the main display

Walk `device.io.ioPorts`; for each port take `-descriptor`; keep the descriptor
that **both**:

1. conforms to `SimDisplayIOSurfaceRenderable`, and
2. has `[[descriptor state] displayClass] == 0`.

Both halves are load-bearing. On this machine two descriptors satisfy (1):
`displayClass == 0` is the built-in screen and `displayClass == 1` is the
external/companion display. idb's `displayClass == 0` predicate **still holds on
Xcode 26.5**.

```objc
// Protocol: SimDisplayDescriptorState  (on descriptor.state)
- (unsigned short)displayClass;        // 0 == main
- (unsigned int)defaultWidthForDisplay;
- (unsigned int)defaultHeightForDisplay;
- (unsigned int)defaultPixelFormat;
- (NSURL *)mask;
```

### Acquiring the surface

```objc
// Protocol: SimDisplayIOSurfaceRenderable
@property (readonly) IOSurface *framebufferSurface;
@property (readonly) IOSurface *maskedFramebufferSurface;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id))cb;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
```

Note **`ioSurfacesChangeCallback`** — plural `Surfaces`. Older references spell it
`ioSurfaceChangeCallback` (singular) and that selector does **not** exist here.

`framebufferSurface` returns the **ObjC `IOSurface` object**, not an
`IOSurfaceRef`, which is exactly what `CALayer.contents` accepts. Measured live:

```
displaySize        1206 x 2622      (points; NSSize)
displayPitch       460
displaySizeInBytes 12763136
surface.width      1206
surface.height     2622
surface.bytesPerRow 4864            (> width*4 = 4824 — the surface is row-padded)
surface.pixelFormat 1111970369      = 'BGRA'
surface.seed        advances continuously
```

The row padding is why we must hand the `IOSurface` to CoreAnimation rather than
treating the buffer as tightly packed.

### Repaint callbacks

```objc
// Protocol: SimDisplayRenderable
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(id))cb;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
- (void)registerCallbackWithUUID:(NSUUID *)uuid displayPropertiesChanged:(void (^)(id))cb;
- (void)unregisterDisplayPropertiesChangedCallbackWithUUID:(NSUUID *)uuid;
@property (readonly) CGSize displaySize;
@property (readonly) unsigned long long displayPitch;
@property (readonly) unsigned long long displaySizeInBytes;
```

**Measured: 54/s and 50.3/s across runs** while apps were launching, and **0/s
with the device idle**. That clears the ≥30 fps acceptance target without any
polling fallback. The idle zero is correct — these are damage notifications, not
a frame clock — so a static screen legitimately produces none.

`ioSurfacesChange` fired 0 times in that window, which is expected — it signals a
surface *swap* (rotation, resize, reboot), not a new frame. Both must be handled:
damage drives repaint, surface-change drives re-binding `layer.contents`.

Registration takes a caller-supplied `NSUUID` as the handle and returns void.
There is **no queue parameter** on these two, so treat the callback thread as
arbitrary and hop to the main queue before touching any view.

### A richer alternative: `SimScreen`

The same descriptor also conforms to `SimScreen`, which bundles all three
callbacks *and* takes an explicit queue:

```objc
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)q
                          frameCallback:(void (^)(...))frame
                surfacesChangedCallback:(void (^)(...))surfaces
              propertiesChangedCallback:(void (^)(...))props;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@property (readonly) id<SimScreenProperties> screenProperties;
- (void)setPowerState:(int)state completionQueue:(dispatch_queue_t)q completionHandler:(void (^)(...))h;
```

**Decision: start with the `SimDisplayRenderable` + `SimDisplayIOSurfaceRenderable`
pair**, because that is the combination proven end-to-end in Phase 0. `SimScreen`
is the upgrade path if we want the explicit callback queue or power control; it is
present on this machine and worth revisiting in Phase 3.

### Other ports (for orientation)

| Port | Descriptor advertises |
|---|---|
| 0 | `SimScreenCaptureService` |
| 1 | display, `displayClass == 1` (external) |
| **2** | **display, `displayClass == 0` (main)** |
| 3 | `SimScreenAdapter` |
| 4 | `SimAcceleratorMetalDevice` |
| 5 | `SimAcceleratorIOSurface` |
| **6** | **`SimLegacyHIDDescriptor`** |
| 7–9 | `SimStreamProcessable` |
| 10 | `SimAudioHostRoutable` |
| 11–12 | bare `SimDeviceIOMachServiceProvider` |

Indices are incidental — match on protocol.

---

## C. Input — HID send path

### Which transport applies here

idb implements two transports and selects between them on the **CoreSimulator
version**, not the iOS version
(`idb/FBSimulatorControl/HID/FBSimulatorHIDSelection.swift`):

- `< 1155.4` → **legacy Indigo** via `SimulatorKit.SimDeviceLegacyHIDClient`
- `>= 1155.4` (Xcode 27) → **DTUHID**, because the guest hands its legacy HID
  services to `dtuhidd`, after which Indigo messages are "delivered byte-correctly
  and then dropped"

**This machine is CoreSimulator 1051.54, and no `dtuhidd` binary exists anywhere
in Xcode.app.** So the legacy Indigo path is correct and functional here. The
DTUHID path is the forward-looking concern for a future Xcode 27 upgrade, and
`FBSimulatorHIDSelection`'s version predicate is the right shape to copy when
that day comes.

### The client

`SimDeviceLegacyClient` — the class idb's older code and every published header
dump names — is **absent**. Its replacement:

```objc
// Class: SimulatorKit.SimDeviceLegacyHIDClient   (Swift class, ObjC-visible members)
- (instancetype)initWithDevice:(SimDevice *)device error:(NSError **)error;
- (instancetype)initWithDevice:(SimDevice *)device
              sessionResetQueue:(dispatch_queue_t)q
                          error:(NSError **)error
           sessionResetHandler:(void (^)(void))handler;
- (void)resetHIDSession;
- (void)sendWithMessage:(IndigoHIDMessageStruct *)msg
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue
             completion:(void (^)(NSError *))completion;
```

**Verified live: `alloc` + `initWithDevice:error:` against the booted device
returns a working instance.** No message has been sent yet — that is Phase 2.

`freeWhenDone:YES` transfers ownership of the buffer to the client, so the
message must be `calloc`'d (not stack- or Swift-allocated).

### Indigo message layout

> **Correction (Phase 2).** The sizes first recorded here were derived by running
> `NSGetSizeAndAlignment` over the live type encoding, which applies *natural*
> alignment. The real struct is `#pragma pack(push, 4)`, so those numbers were
> wrong (they gave a 168-byte payload and a 200-byte message). The packed layout
> below is confirmed both by idb's `Indigo.h` and by messages that the guest
> actually acts on. `simdump` still prints the natural-alignment decode; read it
> as field *types and order*, not offsets.

Decoded from the live `sendWithMessage:` type encoding — this is authoritative
for *this* Xcode and beats any header:

```
IndigoHIDMessageStruct   size 32 (base, before the flexible array), align 8
  @0   {?=IIIIIi}   24 B   mach message header (5 x uint32 + int32)
  @24  I             4 B   innerSize
  @28  C             1 B   eventType   (1 button/keyboard, 2 single-touch, 3 multi-touch)
  @32  [0 payload]         flexible array member, align 8
```

Payload element (168 B, align 8):

```
  @0   I            eventKind    (2 = button, 0xB = touch)
  @8   Q            timestamp    (mach_absolute_time())
  @16  I            reserved
  @24  (_event)     128-byte union, align 8
  ...  c C [2C] Q   trailing fields
```

The `_event` union's members, verbatim from the encoding:

```
_extended               IIQ(?={?=I[64c]}{?=I}{?=IC})        88 B   keyboard
_touch_event            IIIdddddIIIIIdddddI                128 B
_pointer_event          dddII
_velocity_event         IdddI
_wheel_event            IdddIIII
_translation_event      dddI
_rotation_event         dddI
_scale_event            dddI
_dock_swipe_event       IIdddI
_button_event           IIIIII                              24 B
_pointer_button_event   IIII
_accelerometer_event    I[40C]
_force_event            IdId
_gamecontroller_event   {_dpad=dddd}{_face=dddd}{_shoulder=dddd}{_joystick=dddd}
_generic_vendor_defined_event  I
_watch_gesture_event    II
_paloma_pose_event      II[28C]{_translation=fff}{_orientation=ffff}
_paloma_collection_event  …
```

**Packed (`pack(4)`) layout — the one that works:**

```
IndigoMessage            payload at 0x20
  0x00  MachMessageHeader   24 B, left zeroed; the client fills it
  0x18  innerSize           uint32 — the payload stride the guest will use
  0x1c  eventType           uint8  — 1 button/keyboard, 2 single-touch, 3 multi-touch
  0x20  IndigoPayload[]     0x90 stride

IndigoPayload            (0x90 = 144 B)
  +0x00 eventKind           uint32 — 2 button, 0x0B touch
  +0x04 timestamp           uint64 — mach_absolute_time(), NOT 8-aligned
  +0x0c field3              uint32
  +0x10 event union         0x80

IndigoTouch              (relative to the event union)
  +0x00 field1              0x400002 on the primary contact, 1 on the repeat
  +0x04 field2              1 on the primary contact, 2 on the repeat
  +0x08 eventMask           Range 0x1 | Touch 0x2 | Position 0x4 | Identity 0x20
  +0x0c xRatio  (double)    0...1 from the left
  +0x14 yRatio  (double)    0...1 from the top
  +0x34 range               1 while in range
  +0x38 touch               1 while the contact is down
  +0x3c field11             routing target; 0x32 is the phone digitizer

IndigoButton             (relative to the event union)
  +0x00 eventSource   +0x04 eventType   +0x08 eventTarget   +0x0c keyCode
```

Message sizes actually accepted by the guest:

| Message | Total | innerSize | payloads |
|---|---|---|---|
| button / key | `0xC0` | `0xA0` | 1 |
| single touch | `0x140` | `0x90` | 2 (contact + repeat) |

### Keyboard codes are HID usages, not virtual key codes

idb's header calls them "hardware independent … HIToolbox" codes. On this Xcode
they are **USB HID Usage Page 0x07** values. Sending HIToolbox virtual codes for
`apple.com` typed `668k[e2=`, and every character decodes exactly as the HID
usage with that numeric value. `SimPaneCore.KeyMap` holds the translation.

Sizes were computed with `NSGetSizeAndAlignment` on the live encoding, not by
hand. `simdump` prints the full decode under `HID CLIENT + INDIGO STRUCT LAYOUT`
and re-derives it automatically after an Xcode update.

Field *semantics* (which uint32 is the target, the button codes, the touch
coordinate convention) are not recoverable from the encoding and come from the
reference repos — see §Reference verdict and DEVLOG.

### Button codes (from references, to be confirmed in Phase 2)

```
source: Home 0x0   Lock 0x1   Keyboard 0x2710   SideButton 0xbb8
        ApplePay 0x1f4   Siri 0x400002
target: Hardware 0x33   Keyboard 0x64
type:   Down 0x1   Up 0x2
```

### The HID IO port

Port 6's descriptor conforms to `SimLegacyHIDDescriptor`:

```objc
@property (readonly) NSObject<OS_xpc_object> *legacyHIDEventPort;
- (void)registerCallbackWithUUID:(NSUUID *)uuid legacyHIDEventPortCallback:(void (^)(id))cb;
- (void)unregisterLegacyHIDEventPortCallbackWithUUID:(NSUUID *)uuid;
```

We do **not** need this: `SimDeviceLegacyHIDClient` finds the port itself (its
ivars include `_ioPort` and `_port`). Recorded because it is the fallback if the
client class ever disappears — at that point one would `mach_msg` the Indigo
bytes to this port directly.

---

## Reference verdict — which repo matches this Xcode

| | Screen | Input |
|---|---|---|
| **idb** (MIT) | older attach-consumer spelling; `displayClass == 0` predicate still correct | **matches exactly** |
| **Baguette** (Apache-2.0) | same protocols, useful on field semantics | **approach is disallowed for us** |
| codex-sim (MIT) | — | — |

> **Correction (Phase 2).** idb follows this pattern only for the *send*. For
> *building* messages it resolves `IndigoHIDMessageForButton`,
> `IndigoHIDMessageForMouseNSEvent` and friends with `dlsym` and calls them as
> raw C function pointers (`FBSimulatorIndigoHID.swift:19-52`) — the same thing
> Baguette does. So neither reference satisfies ground rule 5 for construction.
> We hand-build every message instead, which works: see DEVLOG Phase 2.

**Input: follow idb for the send path.** `FBSimulatorIndigoHIDClient.swift:47` already resolves
`"SimulatorKit.SimDeviceLegacyHIDClient"` by name and messages it through a
declared `@objc protocol` + `unsafeBitCast`:

```swift
@objc private protocol SimDeviceLegacyHIDClientMessaging {
  @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
  func send(...)
}
```

That is precisely the pattern ground rule 5 mandates, it is MIT-licensed, and it
independently arrived at the same class name this machine reports.

**Baguette's input path is off-limits.** It reaches SimulatorKit's C builders
(`IndigoHIDMessageForMouseNSEvent`, `IndigoHIDMessageForButton`,
`IndigoHIDMessageForTrackpadEventFromHIDEventRef`) through `dlsym` +
`@convention(c)` function pointers — see
`Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift:28-62`. Ground rule 5
forbids raw C function pointers from these frameworks. Baguette stays valuable as
**documentation** of field semantics (it is where the button codes above come
from), and its Apache-2.0 licence permits that with attribution, but we
hand-build the message the way idb does.

Baguette also hard-targets Xcode 26 with no runtime version branch, so its input
code would not degrade gracefully in our shipping build even if the approach were
allowed.

**Screen: neither, quite.** Use the selectors introspected here. The spelling
drifted (`ioSurfacesChangeCallback`), and this machine's own signatures are the
only trustworthy source.

---

## Introspection checklist

What Phase 1 must feature-detect before doing anything, in order. Any miss →
`SimPaneSupport.unsupported(reason:)`.

- [x] `xcode-select -p` resolves inside an `Xcode.app` bundle
- [x] `CoreSimulator.framework` dlopens
- [x] `SimulatorKit.framework` dlopens
- [x] `SimServiceContext` + `sharedServiceContextForDeveloperDir:error:`
- [x] `-defaultDeviceSetWithError:` → `SimDeviceSet` → `devices`
- [x] `SimDevice.io` → `SimDeviceIOClient` → `ioPorts`
- [x] a descriptor conforming to `SimDisplayIOSurfaceRenderable`
- [x] that descriptor's `state` conforms to `SimDisplayDescriptorState` and
      `displayClass == 0` exists
- [x] `-framebufferSurface` returns a non-nil `IOSurface`
- [x] `-registerCallbackWithUUID:damageRectanglesCallback:`
- [x] `-registerCallbackWithUUID:ioSurfacesChangeCallback:`
- [x] `NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient")`
- [x] `-initWithDevice:error:` constructs
- [x] `-sendWithMessage:freeWhenDone:completionQueue:completion:` exists
- [x] CoreSimulator version `< 1155.4` (else the Indigo path is silently dropped
      and we must switch to DTUHID)

All fourteen pass on this machine.

## Ranked risks

1. **A future Xcode crosses CoreSimulator 1155.4.** Input goes silently dead —
   messages are accepted and dropped, so it fails *without an error*. Mitigation:
   check the version at startup and refuse to enable input with a clear reason
   rather than appearing broken. Cheapest disproof: read
   `CoreSimulator.framework/Resources/Info.plist`.
2. **Indigo field semantics are guesswork until a real touch lands.** The
   encoding gives types, not meaning. Cheapest disproof: send one tap at screen
   centre in Phase 2 and watch SpringBoard react.
3. **Callback thread is undocumented.** 54/s arriving on an unknown queue into
   AppKit is a crash waiting to happen. Mitigation: always hop to main; consider
   `SimScreen`'s explicit `callbackQueue` variant.
4. **Row-padded surface** (4864 vs 4824). Any hand-rolled bitmap path must honour
   `bytesPerRow`. Avoided entirely by using `CALayer.contents`.
5. **SimulatorKit being Swift** means its classes could gain/lose ObjC visibility
   between releases with no symbol-level warning. Mitigation: `simdump` is
   checked in; re-run it on every Xcode update.
6. **Multiple consumers on one device.** Not yet tested; idb precedent says it is
   fine, and Phase 4 needs it for multiple Ghostty windows.
