# Glissé

A native macOS menu-bar utility that turns the vertical edges of your trackpad
into invisible sliders.

Put one finger on the **left** edge and slide up or down to change **screen
brightness**. Do the same on the **right** edge for **volume**. No clicking, no
modifier keys, no window. The real macOS volume/brightness HUD appears, and the
trackpad ticks under your finger as the value moves.

### About the name

*Glissé* — glided. The user-facing name is defined in exactly one place,
`Sources/GlisseKit/Utilities/Branding.swift`, so renaming again is a one-line
change.

The accent is deliberately confined to what a person reads. The executable,
SwiftPM product, Swift modules and bundle identifier all stay ASCII (`Glisse`,
`GlisseKit`, `xyz.glisse.Glisse`) because those double as the process name and as
filesystem paths, where a non-ASCII character is a liability. So:

| | value |
| --- | --- |
| Bundle on disk | `Glissé.app` |
| `CFBundleDisplayName` / `CFBundleName` | `Glissé` |
| `CFBundleExecutable`, process name, CLI | `Glisse` |
| Bundle identifier / OSLog subsystem | `xyz.glisse.Glisse` |

Renaming changed the bundle identifier, and therefore the `UserDefaults` domain.
`SettingsStore` migrates preferences from the previous domain once, so the rename
does not silently reset anyone's configuration.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Building](#building)
- [Installing](#installing)
- [Permissions](#permissions)
- [Terminal modes](#terminal-modes)
- [Settings](#settings)
- [Architecture](#architecture)
- [Private APIs](#private-apis)
- [Why App Sandbox is disabled](#why-app-sandbox-is-disabled)
- [External monitors](#external-monitors)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)

---

## What it does

| Feature | Default | Notes |
| --- | --- | --- |
| Left edge → brightness | on | Real backlight, not a gamma trick or an overlay |
| Right edge → volume | on | Follows the current output device |
| Relative control | always | Deltas are added to the current value; finger position is never mapped to absolute value |
| On-screen display | on | Always the **real macOS HUD**, never an imitation. On macOS 26+ that means delegating the change to the system's own media keys (needs Accessibility). |
| Haptic feedback | on, Medium | Ticks on value progress, not per input frame. Off / Light / Medium / Strong. Driven through `MTActuator`, because the public API is silent for a background app. |
| Pause while typing | on | 500 ms after each keystroke, new gestures are refused |
| Fine control | off | Same gesture, much smaller change |
| Swap sides | off | Left ↔ right |
| Bottom quarter only | off | Gestures may only *start* in the lower quarter of the edge |
| Freeze pointer | off | Pointer stays where it was while you slide |
| Three-finger tap = middle click | off | Deliberate tap only; three-finger swipes are left to macOS |
| Modifier requirement | none | Hold or toggle Control / Option / Command / Shift / Fn |
| Launch at login | on¹ | via `SMAppService` |

¹ Auto-registration only happens for a copy installed in `/Applications` or
`~/Applications`. A build running from `build/` will not add itself to your login
items — that path would break on `make clean`. The menu toggle still works from
anywhere.

### The activation rule

Being *near* an edge is not enough. A gesture only starts when the finger:

1. **begins** inside the edge strip (default: outer 8% of the width),
2. satisfies the modifier requirement at that moment,
3. is not inside the typing-suppression window,
4. then moves vertically by at least ~1.1% of the trackpad height,
5. without wandering sideways by more than ~4.5% first,
6. is the only finger on the device.

A touch that starts in the middle and travels to the edge can **never** activate
the slider, for its whole life. That single rule removes most false positives, and
it is covered by unit tests.

---

## Requirements

- macOS 13 Ventura or later. Developed and verified on **macOS 27.0 (26A5416b)**.
- Apple Silicon or Intel Mac with a Force Touch trackpad or a Magic Trackpad.
  Haptics are silently skipped on hardware without an actuator.
- To build: Swift 6 toolchain. **Xcode is not required** — the Command Line Tools
  are enough (`xcode-select --install`). A full Xcode is only needed to run the
  unit tests, because `XCTest` does not ship with the Command Line Tools.

---

## Building

From a fresh checkout:

```bash
git clone <this repo> Swipey
cd Swipey
make            # debug build  -> build/Glissé.app
make release    # optimised    -> dist/Glissé.app
```

`make` compiles the SwiftPM package and assembles a real `.app` bundle
(`LSUIElement`, `Info.plist`, icon, ad-hoc code signature). The bundle is
required — running the bare executable works, but macOS will not grant it a
stable Accessibility identity and `SMAppService` will refuse to register it.

Other targets:

```bash
make run        # build, then launch
make test       # unit + fuzz tests (needs Xcode for XCTest)
make probe      # capability report
make diagnose   # live trackpad coordinates
make icon       # regenerate Resources/AppIcon.icns from code
make dmg        # dist/Glissé.dmg (run `make release` first)
make clean
```

### If Xcode is installed but not selected

`swift build` works with the Command Line Tools, but `swift test` needs `XCTest`.
The `Makefile` picks up `/Applications/Xcode.app` or `/Applications/Xcode-beta.app`
automatically. To do it by hand:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

### Opening in Xcode

```bash
open Package.swift
```

There is no `.xcodeproj`. Xcode opens SwiftPM packages directly, and a generated
project file would be one more thing to keep in sync.

### Signing

Debug and release builds are **ad-hoc signed** (`codesign --sign -`) by default.
That is enough for local use. To sign with a Developer ID:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release
xcrun notarytool submit dist/Glissé.dmg --apple-id … --team-id … --password … --wait
xcrun stapler staple dist/Glissé.app
```

No certificates, profiles or credentials are stored in this repository, and
`.gitignore` excludes `*.p12`, `*.cer` and `*.provisionprofile`.

### Gatekeeper, for unsigned builds

An ad-hoc signed app you built yourself runs without complaint on the machine
that built it. If you copy it to another Mac, Gatekeeper will block it because it
is not notarised. Right-click → **Open**, then confirm, or:

```bash
xattr -d com.apple.quarantine /Applications/Glissé.app
```

---

## Installing

```bash
make release
cp -R dist/Glissé.app /Applications/
open /Applications/Glissé.app
```

A slider glyph appears in the menu bar. That is the whole interface.

To uninstall: quit from the menu, turn off Launch at Login first (or run
`/Applications/Glissé.app/Contents/MacOS/Glisse --login-item disable`),
then delete the app and, if you want, `defaults delete xyz.glisse.Glisse`.

---

## Permissions

**The core feature needs no permission at all.** Edge sliding, volume and
brightness all work on first launch, before you have granted anything. This is
because touch data comes from `MultitouchSupport`, which reads the device
directly, rather than from the window server.

Accessibility is requested to enable the on-screen display and three optional
extras. Find it at:

- macOS 27: **System Settings ▸ Device Control and Data Access ▸ Accessibility**
- macOS 13–26: **System Settings ▸ Privacy & Security ▸ Accessibility**

Apple renamed that pane in macOS 27, which is a common reason people cannot find
it. What needs the permission:

| Needs Accessibility | Why |
| --- | --- |
| The macOS on-screen display | On macOS 26+ the only way to make the system draw it is to post media key events |
| Pause while typing | A listen-only `CGEventTap` on `keyDown` |
| Toggle-mode modifier | A listen-only tap on `flagsChanged`, needed because the key is pressed while Glissé is in the background |
| Three-finger middle click | Posting a synthetic `CGEvent` requires it |
| AppKit fallback touch source | Only used if `MultitouchSupport` ever stops working |

Both taps are created with `.listenOnly`, so they physically cannot swallow or
alter a keystroke.

Glissé asks once. If you decline, it will not ask again — use
**Permissions…** in the menu when you change your mind. The permission state is
watched only while a request is outstanding (1 Hz, torn down as soon as it
flips), so features light up without restarting the app, and nothing polls in
steady state.

No other permission is used. No camera, no microphone, no files, no network. The
app makes no outbound connections of any kind.

---

## Terminal modes

These exist because a background utility is otherwise hard to verify.

```bash
Glisse --probe        # which frameworks resolved, devices, displays, audio, HUD
Glisse --selftest     # actually changes volume/brightness/HUD, then restores
Glisse --diagnose     # live normalised touch coordinates
Glisse --haptictest   # fire every actuation pattern in turn, labelled
Glisse --hudtest      # probe both OSD routes, then drive the real HUD via media keys
Glisse --login-item status|enable|disable
```

`--diagnose` is the one to use if a gesture feels wrong. It prints, per contact,
the device, touch id, phase, normalised x/y, vertical travel and pressure, plus
which edge strip the finger is in and any resulting delta. After 10 seconds it
prints the resolved `MTTouch` byte layout and the verdict of the vertical-axis
check.

---



### The on-screen display

Glissé draws no HUD of its own — no overlay window, no progress bar, no
imitation of Apple's design. The display you see is the one macOS owns, so it
always matches your macOS version.

There are exactly two ways to get it, and the OS decides which applies:

| Mechanism | macOS | How | Resolution |
| --- | --- | --- | --- |
| System OSD, direct | 13–15 | Write the exact value, then ask the private OSD to display it | continuous |
| System HUD, media keys | 26+ | Synthesise the machine's own volume/brightness key events, so macOS performs the change *and* draws its HUD | 1/64 steps |
| No HUD | any | Value still written precisely, nothing displayed | continuous |

Why the second one exists: on macOS 26+ there is no way to ask the system to show
its OSD. Both private routes are dead — `-[OSDManager showImage:…]` accepts every
call and draws nothing, and `com.apple.OSDUIHelper` refuses the XPC connection.
The HUD is not even a listable window any more (confirmed by diffing
`CGWindowListCopyWindowInfo` across a real key press), so it is drawn inside
WindowServer where nothing external can reach it.

The one thing that still produces the genuine HUD is the event a Mac keyboard
sends. So Glissé posts that same `NSSystemDefined` subtype-8 event. A bare
media key moves in 1/16 steps, which would ratchet; holding Shift+Option asks for
quarter steps, measured at exactly 1/64 for both volume and brightness. A full
sweep is therefore 64 presses — finer than the 16-segment HUD can even draw.

Consequences, stated plainly:

- **This path needs Accessibility permission**, because it posts events. Without
  it the gesture still works and the value still changes precisely; no display
  appears, and the menu says why.
- The keys act on whatever output device and display macOS considers current. So
  brightness aimed at a **pinned or external display**, or driven over DDC, keeps
  the precise direct path and forgoes the HUD.
- Mute is the system's own: sliding to zero produces the real mute HUD.

Flow:

```text
trackpad gesture
     ↓
macOS changes the actual volume / brightness (media key) ──▶ macOS draws its HUD
     ↓
value read back ──▶ haptics + end-stop detection stay in step with reality
```

### Settings

Menu bar for the common switches; a small five-tab window for the rest
(**General**, **Gestures**, **Feedback**, **Displays**, **Advanced**).
**Diagnostics…** opens a live text dump — touch source, resolved private-struct
layout, gesture numbers, audio device, display backends, HUD provider. That
window refreshes twice a second while open and stops the moment it closes.

Everything lives in `UserDefaults` under one key (`settings.v1`) as JSON, read
and written in exactly one place (`SettingsStore`). Settings written by an older
build are merged over the current defaults key by key, so adding a preference
never wipes the others.

---

## Architecture

```
                  ┌─────────────────────┐
                  │ Raw trackpad device │
                  └──────────┬──────────┘
                             │  MultitouchSupport (private)   ← primary
                             │  NSTouch via CGEventTap        ← fallback
                             ▼
                     TrackpadManager            picks + recovers a source
                             │  TrackpadFrame (Sendable value type)
                             ▼
                    EdgeGestureEngine           pure state machine, no I/O
                             │  IDLE → CANDIDATE → ACTIVE → ENDING → IDLE
                             │  EdgeAction.volume / .brightness (relative delta)
              ┌──────────────┴───────────────┐
              ▼                              ▼
      CoreAudioVolumeController      BrightnessController
              │                              │
              ▼                    ┌─────────┴──────────┐
          Core Audio               ▼                    ▼
       ('vmvc' → 'volm'    DisplayServices          DDC/CI VCP 0x10
        → per-channel)     (built-in panel)      (external, coalesced)
              │                              │
              └──────────────┬───────────────┘
                             ▼
                     resulting value
                             │
                   ┌─────────┴────────┐
                   ▼                  ▼
          macOS-owned HUD         Haptics
       (OSD direct on 13–15,   (MTActuator, detent-gated)
        media keys on 26+)
```

Supporting services:

```
KeyboardMonitor ──▶ TypingSuppressionService ──▶ gesture eligibility
ModifierMonitor ──▶ gesture eligibility (hold mode reads NSEvent.modifierFlags
                    directly, so it needs no permission)
AppLifecycleObserver ──▶ TrackpadManager · DisplayManager · volume cache · cursor
TerminationGuard ──▶ clean shutdown on SIGTERM/SIGINT/SIGHUP
SettingsStore ──▶ menu bar · gesture engine · every service
```

### Threading

```
touch source thread (~125 Hz)
      │   hand off an immutable frame, nothing else
      ▼
serial gesture queue (.userInteractive)
      │   engine step → value arithmetic → hardware write
      ├──▶ DisplayServices / Core Audio   fast, synchronous
      ├──▶ DDC coalescer queue            slow, never blocks the gesture
      ├──▶ HUD (throttled to 60 Hz)
      └──▶ haptics (only when a detent changes)
```

Backpressure is handled by **dropping** frames, not queueing them: at most three
may be in flight. A stale finger position is worth less than low latency, and an
unbounded queue would turn one slow write into growing lag.

Two design notes that deviate from an obvious reading of the spec, with reasons:

- **`DisplayManager` is a lock-protected class, not an actor.** The gesture path
  needs a display's capabilities *synchronously* while deciding where to send a
  delta. Awaiting an actor there would add a hop and jitter to the one code path
  that has to stay under ~16 ms. The expensive part (probing DDC, ~100 ms per
  monitor) runs on a utility queue and only on reconfiguration.
- **Swift language mode 5, not 6.** The Swift 6.4 compiler is used, but strict
  data-race checking is not enabled: the raw `MultitouchSupport` callback,
  `CGEventTap` callbacks and the `OSDManager` bridge all cross non-`Sendable` C
  boundaries. Isolation is instead enforced narrowly and explicitly — the pure
  gesture core is `Sendable` end to end and unit tested, everything touching
  AppKit is `@MainActor`, and the raw callback paths only touch value types plus
  one lock.

---

## Private APIs

Every private symbol is resolved with `dlopen`/`dlsym` at runtime, never linked.
A symbol that disappears in a future macOS release degrades that one feature to
"unavailable"; it cannot cause a launch-time `dyld` abort. All of it lives in
`Sources/GlissePrivate/`, behind protocols, so the rest of the app is unaware.

| Framework | Symbols | Why there is no alternative |
| --- | --- | --- |
| `MultitouchSupport` | `MTDeviceCreateList`, `MTRegisterContactFrameCallbackWithRefcon`, `MTUnregisterContactFrameCallback`, `MTDeviceStart/Stop`, `MTDeviceIsBuiltIn`, `MTDeviceGetDeviceID/FamilyID/GUID`, `MTDeviceGetSensorSurfaceDimensions`, `MTDeviceGetSensorDimensions`, `MTDeviceIsAlive/IsRunning/IsOpaqueSurface` | macOS exposes trackpad contacts publicly only via `NSTouch`, which is delivered to the *focused* app. A background utility has no public way to see raw contacts. |
| `MultitouchSupport` (actuator) | `MTActuatorCreateFromDeviceID`, `MTActuatorOpen/Close/IsOpen`, `MTActuatorActuate` | `NSHapticFeedbackManager.defaultPerformer` produces nothing from an `LSUIElement` accessory app that is never the active application — measured, not assumed. Its own documentation scopes it to "user actions in your app". No public alternative exists, and it is also the only source of more than one feedback firmness. |
| `DisplayServices` | `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness`, `DisplayServicesGet/SetLinearBrightness` | No public API sets the built-in backlight. `IODisplaySetFloatParameter` worked on Intel; the Apple Silicon backlight is not an `IODisplay` parameter. |
| `CoreDisplay` | `CoreDisplay_Display_Get/SetUserBrightness` | Fallback only, and only after being cross-checked against `DisplayServices` (see below). |
| `OSD` | `OSDManager`, `-showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:` | No public API shows the system volume/brightness HUD. Reached through `NSClassFromString` + `respondsToSelector`, wrapped in `@try`. |
| `IOKit` (undeclared) | `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C` | The only way to reach a monitor's I2C channel on Apple Silicon. macOS has no external-brightness API at all. |

### The `MTTouch` problem, and how it is handled

`MTTouch`'s layout is not published and has changed size across releases. Swift
never sees it. The Objective-C bridge parses it into `ESRawTouch` — a struct we
own — through a byte layout that is **validated at runtime**, not assumed:

- The canonical layout (stride 96, timestamp at +8, path index +16, state +20,
  normalised position +32) is the starting point.
- Every frame is scored: state must be 1–8, path index 0–128, normalised x/y
  within −0.15…1.15, size finite and sane, per-contact timestamp within 2 s of
  the frame timestamp.
- A frame with **two or more** contacts that parses cleanly is real
  corroboration, because a wrong stride would misalign contact 2 onward. Three
  such frames promote the layout from *assumed* to *validated*.
- Repeated failures trigger a bounded re-derivation: the timestamp offset is
  located by matching the known frame timestamp, then stride × position-offset
  candidates are scored.
- If that also fails, the bridge reports layout failure and `TrackpadManager`
  switches to the public `NSTouch` source. Gestures keep working.
- `x`/`y` are clamped to 0…1 before anything downstream sees them.

On macOS 27.0 / M2 Pro this reports `validated, stride=96` after a few seconds of
normal use. The `--diagnose` output includes a hex dump of the last frame so the
layout can be re-derived by hand if a future release ever breaks the validator.

### Measured behaviour that contradicts the obvious implementation

Three things were verified on hardware and changed the design:

1. **`MTDeviceIsAlive` returns `false` before `MTDeviceStart`.** Using it as an
   enumeration filter discards every device, and the app silently falls back to
   the public touch source. It is not used as a filter.
2. **`CoreDisplay_Display_GetUserBrightness` returns a constant `1.0`** on this
   machine regardless of the real backlight, and `SetUserBrightness` has no
   observable effect. So CoreDisplay is a *fallback only*, gated behind a probe
   that cross-checks it against `DisplayServices` and rejects it if they disagree
   by more than 0.10.
3. **`MTDeviceGetGUID` does not return a real UUID** — it returns the device ID
   in the first byte and zeros for the rest. Session keys use `MTDeviceGetDeviceID`
   instead, which is stable across sleep and replug.

`DisplayServicesBrightnessChanged` and `DisplayServicesGetBrightnessRange` do not
exist on macOS 27.0. They are looked up optionally and skipped; the only visible
consequence is that the Control Centre brightness slider may lag behind until it
is reopened.

---

## Why App Sandbox is disabled

There is no entitlement that permits any of the following, and all of it is
required:

- reading raw multitouch contacts from the device,
- setting the backlight through `DisplayServices`,
- opening a display's I2C channel for DDC/CI,
- creating a `CGEventTap`.

The app is sandbox-free but otherwise minimal: **no** root, **no** setuid helper,
**no** daemon, **no** launch agent beyond the `SMAppService` login item, **no**
kernel extension, **no** system extension, **no** privileged helper. It is one
user-space process. It is not App Store distributable, and is not meant to be.

---

## External monitors

External brightness uses DDC/CI, writing VCP feature `0x10`. On Apple Silicon
this goes through `IOAVService`; on Intel through `IOI2CSendRequest`.

Three protections, because monitors are the least reliable thing here:

1. **Capability probe once per display, cached.** A monitor that never answers a
   VCP `0x10` read is marked unsupported and left alone forever.
2. **The native maximum is read from the monitor.** Assuming 100 is the classic
   DDC bug — panels use 20, 100, 255 and other values. Writing 100 to a 20-max
   monitor either clips or is rejected.
3. **A circuit breaker.** Three consecutive failures suspend that display for
   2 s, then 5, 15, 30, 60 s. One success resets it. A dead monitor is never
   hammered at trackpad-frame frequency, and a monitor that recovers after a dock
   reconnect is retried within a minute.

Writes are coalesced with an 18 ms trailing edge on a serial queue, so a sweep
produces at most ~55 writes per second and always lands on the final value. The
gesture thread never waits on I2C.

> **This path is implemented but not verified on hardware.** No external display
> was available. The framing follows the DDC/CI spec and the reply parser scans
> for the `Get VCP Feature Reply` body rather than assuming a fixed offset, but
> treat external-monitor brightness as untested until you try it. `--probe`
> reports which transport resolved and how each display was matched to its I2C
> channel (`edid`, `serial` or `index` — `index` is a positional guess and is
> labelled as such).

---

## Known limitations

Real ones, not hedging.

First, what *was* verified on this hardware (macOS 27.0 / M2 Pro 14"), so the
limitations below are read in context: the `MTTouch` layout reaches `validated`
under real touches; a real left-edge slide was observed producing brightness
deltas; volume and brightness writes were confirmed by read-back and restored
exactly; the native `OSDManager` HUD renders; the vertical-axis verifier reports
`matchesContract` (finger up = value up); five full teardown-and-re-register
cycles of the multitouch callbacks all recovered; both the Quit and `SIGTERM`
shutdown paths exit cleanly with no crash reports.

Now the gaps:

- **The macOS HUD needs Accessibility on macOS 26+, and costs resolution.** It
  cannot be asked to appear, only produced as a side effect of letting the system
  perform the change, so adjustments there move in 1/64 steps rather than being
  truly continuous. Turn the display off in Settings to get continuous control
  back without it.
- **Brightness on a pinned or external display gets no HUD.** The media keys
  address whatever display macOS considers current; there is no way to aim them.
  Those displays keep the precise DDC/DisplayServices path.
- **`NSHapticFeedbackManager` is silent for this app.** It produces nothing from a
  background accessory app, so haptics go through `MTActuator`. The public API
  remains as a fallback for hardware where the actuator cannot be opened, but on a
  MacBook it will not be the code path in use.
- **The Light/Medium/Strong actuation mapping is unconfirmed by feel.** The driver
  returns success for all eight patterns and firmness is not measurable from
  software. `--haptictest` exists to calibrate it.
- **External-monitor brightness is unverified.** See above.
- **Magic Trackpad is unverified.** Only the built-in trackpad was available.
  Device enumeration, per-device gesture sessions and hot-plug handling are all
  implemented and the code paths are exercised, but no second physical device was
  tested.
- **Intel Macs are unverified.** The Intel code paths (`IODisplay` brightness,
  `IOI2CSendRequest` DDC) are implemented and compile, but this was built and run
  only on Apple Silicon.
- **Sleep/wake recovery is verified indirectly.** `--selftest` performs five full
  teardown-and-re-register cycles of the `MultitouchSupport` callbacks — which is
  the exact action that recovery performs, and the step that historically breaks —
  plus a stop/start rebuild, audio cache invalidation and display re-enumeration.
  All pass. An actual lid-close cycle has not been performed; see
  `docs/QA-CHECKLIST.md`.
- **Toggle-mode modifiers fire on any press of that key**, including when it is
  being used as part of a shortcut. Hold mode has no such ambiguity, which is why
  it is the recommended choice.
- **Fn in toggle mode** is unreliable on some third-party keyboards, which never
  report `maskSecondaryFn`. It is offered but not the default.
- **Only one finger may drive a slider.** A resting thumb ends the gesture. This
  is deliberate — it is the cheapest defence against false activation — but if you
  habitually rest a thumb near the edge you may find gestures cut short.
- **The Control Centre brightness slider can lag** until reopened, because
  `DisplayServicesBrightnessChanged` no longer exists on macOS 27.
- **Volume follows the system output device**, so if that device has no volume
  control (some HDMI sinks, some aggregate devices) the right edge does nothing.
  The menu says which device is active and whether it is controllable.
- **`--diagnose` and `--probe` print a line from Apple's own framework**
  (`*** Recognized (0x6d) family***`). That is `MultitouchSupport` writing to
  stdout, not Glissé.

---

## Troubleshooting

**Nothing happens when I slide.**
Open **Diagnostics…**. Check, in order: `active source` is not `none`;
`devices` is at least 1; `MTTouch layout` is `validated` or `assumed`, not
`FAILED`; `frames processed` climbs while you touch the trackpad. Then look at
`last reject` — it names the reason the most recent contact was refused
(`not an edge`, `typing suppression`, `multi-touch`, `horizontal motion`,
`outside bottom region`, `modifier not satisfied`).

**It triggers when I did not mean it.**
Narrow **Settings → Advanced → Edge width** (default 8%), raise **Vertical
intent**, or turn on **Bottom quarter only**.

**It does not trigger when I do mean it.**
Widen the edge, or lower **Vertical intent**. If you are a fast typist, reduce
**Typing pause**.

**Sliding up decreases the value.**
Open **Diagnostics…** and read the *Vertical axis verification* verdict, then turn
on **Settings → Advanced → Invert vertical direction**. This should not happen —
the app verifies the axis automatically by correlating touch movement against
pointer movement, and reports `matchesContract` on tested hardware — but the
switch is there. The verdict needs roughly 10–30 seconds of ordinary pointer use
before it settles; until then it reads `undetermined`, which is not a problem.

**The pointer is stuck.**
It should not be possible: the pointer is released on gesture end, cancel, sleep,
lock, app deactivation, permission loss, a 1 s watchdog with no gesture
heartbeat, `SIGTERM`/`SIGINT`/`SIGHUP`, and `atexit`. If it ever does happen,
quitting Glissé releases it. To fix it by hand from any Mac:
`osascript -e 'do shell script "true"'` will not help — instead run
`python3 -c "import Quartz; Quartz.CGAssociateMouseAndMouseCursorPosition(1)"`.

**Launch at Login will not stick.**
It only auto-registers from `/Applications` or `~/Applications`. Check the state
with `--login-item status`. If it says *Needs approval*, enable Glissé in
**System Settings → General → Login Items**.

**Two middle clicks from one tap.**
Should not happen; there are two independent guards (a 300 ms re-arm in the
recogniser and a 200 ms floor in the synthesiser). Please note the exact gesture
if it does.

---

## Project layout

```
Swipey/
├── Package.swift                 SwiftPM manifest (macOS 13+)
├── Makefile                      build, bundle, sign, dmg, icon
├── README.md
├── Resources/
│   ├── Info.plist                LSUIElement, bundle id, usage strings
│   └── AppIcon.icns              generated by Scripts/make-icon.swift
├── Scripts/
│   ├── build.sh                  filters SwiftPM's very verbose failures
│   ├── make-icon.sh
│   └── make-icon.swift           original icon, drawn with CoreGraphics
├── docs/
│   └── QA-CHECKLIST.md           manual hardware test sheet
│
├── Sources/GlissePrivate/     ALL unsafe / private code lives here
│   ├── include/
│   │   ├── ESMultitouchTypes.h   stable ESRawTouch, layout descriptor
│   │   ├── ESMultitouchBridge.h
│   │   ├── ESBrightnessBridge.h  DisplayServices + CoreDisplay + IODisplay
│   │   ├── ESOSDBridge.h         native HUD
│   │   └── ESDDCBridge.h         IOAVService / IOI2C transport
│   ├── ESMultitouchBridge.m      dlsym, layout validation, frame conversion
│   ├── ESBrightnessBridge.m
│   ├── ESOSDBridge.m
│   └── ESDDCBridge.m
│
├── Sources/GlisseKit/
│   ├── App/
│   │   ├── GlisseMain.swift        entry + --probe/--diagnose/--selftest
│   │   ├── AppDelegate.swift
│   │   ├── AppCoordinator.swift       owns every service; startup/shutdown order
│   │   ├── GestureCoordinator.swift   frames → hardware
│   │   ├── AppLifecycleObserver.swift sleep/wake/lock/display/session
│   │   └── TerminationGuard.swift     signal-safe shutdown
│   ├── MenuBar/
│   │   ├── StatusItemController.swift
│   │   ├── MenuBuilder.swift
│   │   └── MenuState.swift
│   ├── Trackpad/
│   │   ├── TrackpadTouch.swift        canonical models + coordinate contract
│   │   ├── TouchSource.swift          protocol over both sources
│   │   ├── TrackpadManager.swift      source selection + recovery
│   │   ├── AppKitTouchSource.swift    public NSTouch fallback
│   │   ├── AxisOrientationVerifier.swift
│   │   ├── Private/
│   │   │   └── MultitouchSupportTouchSource.swift
│   │   └── Gesture/
│   │       ├── EdgeGestureEngine.swift        pure state machine
│   │       ├── GestureSession.swift
│   │       ├── GestureConfiguration.swift
│   │       ├── AdjustmentMath.swift           relative delta, mute, DDC scaling
│   │       ├── ThreeFingerTapRecognizer.swift
│   │       └── TypingSuppressionService.swift
│   ├── Audio/
│   │   ├── VolumeControlling.swift
│   │   ├── CoreAudioVolumeController.swift
│   │   └── AudioDeviceObserver.swift
│   ├── Brightness/
│   │   ├── DisplayTarget.swift
│   │   ├── BrightnessController.swift
│   │   ├── DisplayManager.swift
│   │   ├── BuiltIn/DisplayServicesBrightnessBackend.swift
│   │   └── DDC/DDCBrightnessBackend.swift
│   ├── HUD/
│   │   ├── SystemHUDProviding.swift    OS-owned HUD only; no custom overlay
│   │   ├── NativeSystemHUDProvider.swift
│   │   └── HUDCoordinator.swift        picks OSD-direct vs media-keys vs none
│   ├── Feedback/HapticFeedbackService.swift
│   ├── Input/
│   │   ├── KeyboardMonitor.swift
│   │   ├── ModifierMonitor.swift
│   │   ├── MediaKeyController.swift    synthesises the real volume/brightness keys
│   │   ├── CursorController.swift
│   │   └── MiddleClickSynthesizer.swift
│   ├── Permissions/PermissionManager.swift
│   ├── Login/LoginItemManager.swift
│   ├── Preferences/
│   │   ├── AppSettings.swift
│   │   ├── SettingsStore.swift
│   │   ├── SettingsView.swift
│   │   └── DiagnosticsWindowController.swift
│   └── Utilities/
│       ├── Clamp.swift
│       ├── Throttler.swift            Throttler, Coalescer, MonotonicClock
│       └── Logger.swift               OSLog categories
│
├── Sources/Glissé/main.swift
└── Tests/GlisseTests/              127 tests
    ├── GestureTestSupport.swift
    ├── EdgeGestureEngineTests.swift   the spec's gesture matrix
    ├── ThreeFingerTapTests.swift
    ├── GestureSessionTests.swift      + typing suppression, throttler
    ├── MappingTests.swift             volume, mute, DDC, HUD scaling
    ├── SettingsStoreTests.swift
    └── GestureFuzzTests.swift
```

---

## Dependencies

None. Apple frameworks only: AppKit, SwiftUI (settings window only), CoreGraphics,
CoreAudio, AudioToolbox, IOKit, ApplicationServices, ServiceManagement, OSLog.

No analytics, no telemetry, no accounts, no licensing, no network code, no
in-app purchase, and no update checker.

## Licensing note

This is an independent implementation. It shares a *category* with other
trackpad-slider utilities but contains no third-party source, binaries, artwork
or branding. The DDC/CI framing follows the published VESA MCCS specification.
The icon is generated from `Scripts/make-icon.swift`.
