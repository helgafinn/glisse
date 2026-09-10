# macOS has no public API for screen brightness

Try to write a Mac app that changes the screen brightness. Not reads it — changes it. You will find nothing in AppKit, nothing in Quartz, nothing in ScreenCaptureKit. `NSScreen` will tell you a display's colour space, its frame, its refresh rate, and its maximum EDR headroom. It will not let you dim it.

This is not an oversight that has gone unnoticed for a year. It is the state of the platform, and working around it teaches you something about what "private API" actually costs.

## What used to work

On Intel Macs the built-in backlight was an IOKit display parameter. You opened the display service and set a float:

```objc
IODisplaySetFloatParameter(service, kNilOptions,
                           CFSTR(kIODisplayBrightnessKey), level);
```

Not documented as a brightness API exactly, but it was public IOKit, it worked, and half the utilities on the Mac used it.

On Apple Silicon it does nothing. The backlight is no longer exposed as an `IODisplay` parameter, so there is no service to set the key on. The call succeeds in the sense that it does not crash, and the screen stays exactly as bright as it was.

The replacement is `DisplayServices`, a private framework:

```
DisplayServicesGetBrightness
DisplayServicesSetBrightness
DisplayServicesCanChangeBrightness
DisplayServicesGetLinearBrightness
DisplayServicesSetLinearBrightness
```

These work. They are also entirely undeclared — no header ships in any SDK.

## External displays have no API at all

The built-in panel is the good case. For an external monitor there has never been a macOS API for brightness, public or private, because brightness on an external display is not a macOS concept. It is a property of the monitor, reached over the display cable through **DDC/CI** — a two-wire I2C channel defined by VESA, where you write a feature code and a value.

Brightness is VCP feature `0x10`. Writing it means getting at the I2C channel, which on Apple Silicon means:

```
IOAVServiceCreateWithService
IOAVServiceReadI2C
IOAVServiceWriteI2C
```

Undeclared IOKit symbols. On Intel it was `IOI2CSendRequest`, also undeclared. There is no third option. Every external-brightness utility on the Mac — every single one — is doing this.

So the situation is: the obvious feature is unreachable publicly on the built-in display, and unreachable by any means except an undocumented I2C path on external ones.

## Using private symbols without shipping a time bomb

The naive approach is to declare the symbols and link against them. Do that and the day Apple removes one, your app does not degrade — it fails to launch. `dyld` aborts the process before `main` runs, and the user sees a crash with no explanation.

The alternative is to resolve everything at runtime:

```objc
void *handle = dlopen("/System/Library/PrivateFrameworks/"
                      "DisplayServices.framework/DisplayServices",
                      RTLD_LAZY);
SetBrightnessFn set = dlsym(handle, "DisplayServicesSetBrightness");
if (!set) { /* feature unavailable, app still runs */ }
```

Now a removed symbol costs you one feature instead of the whole app. The same applies to Objective-C classes reached by name — `NSClassFromString`, then `respondsToSelector:` before every call, wrapped so a signature change raises rather than corrupts.

This is not defensive padding. It is the only honest way to depend on something you were never promised.

## The harder problem: a struct whose layout is not published

Reading raw trackpad contacts needs `MultitouchSupport`, because the public `NSTouch` only delivers touches to the *focused* application. A background utility has no public way to see the trackpad at all.

The callback hands you an array of `MTTouch`. Its layout is unpublished and has changed size across releases. Guessing wrong does not throw — it silently hands you garbage coordinates, which for something that moves the screen brightness is worse than failing.

What works is treating the layout as a hypothesis and scoring it:

- Start from the canonical layout: stride 96, timestamp at +8, path index +16, state +20, normalised position +32.
- Score every frame. State must be 1–8. Path index 0–128. Normalised x and y within −0.15…1.15. Size finite. Per-contact timestamp within two seconds of the frame timestamp.
- **A frame with two or more contacts that parses cleanly is real corroboration**, because a wrong stride misaligns contact 2 onward. Three such frames promote the layout from *assumed* to *validated*.
- On repeated failure, re-derive within bounds: locate the timestamp offset by matching the known frame timestamp, then score stride × position-offset candidates.
- If that fails too, report layout failure and fall back to the public `NSTouch` path. Reduced behaviour, but working.

The multi-contact check is the load-bearing part. One contact parsing plausibly proves very little; a wrong stride that still produces sane values for four contacts in a row is not a coincidence you need to plan for.

## Three things the hardware said that the documentation did not

Every one of these was measured on a real machine and each one changed the design.

**`MTDeviceIsAlive` returns false before `MTDeviceStart`.** Use it as an enumeration filter — which reads as the obviously correct thing to do — and you discard every device on the system, then silently fall back to the degraded path. The name suggests a liveness check. It is not usable as one at enumeration time.

**`CoreDisplay_Display_GetUserBrightness` returns a constant `1.0`** regardless of the actual backlight, and its setter has no observable effect. It looks like a cleaner alternative to `DisplayServices` and it is inert. Any code that trusts it reports full brightness forever. The only safe use is as a fallback behind a probe that cross-checks it against `DisplayServices` and rejects it when they disagree.

**`MTDeviceGetGUID` does not return a UUID.** It returns the device ID in the first byte and zeros for the rest. Key anything on it and every trackpad collides.

None of this is discoverable by reading. It is only discoverable by instrumenting the calls and comparing them against what the screen actually did.

## What this means if you are considering it

Two things are worth being clear about.

**Private API use is a real ongoing liability**, not a one-time cheat. Every symbol is a thing that can vanish in a point release. The mitigation is runtime resolution and graceful degradation, and the honest description of the result is "this feature may stop working", not "this is fine".

**It also means no App Store.** There is no entitlement for raw trackpad contacts, none for the system HUD, none for I2C. An app doing this is a user-space process the user chooses to trust, and it should say so plainly rather than implying a review process vouched for it.

That trade is only worth making when the feature genuinely cannot exist otherwise. Brightness control is one of those cases: the platform simply does not offer it.

---

I ended up here writing [Glissé](https://github.com/helgafinn/glisse), which puts brightness and volume on the trackpad's left and right edges — glide the left edge to dim, the right to change volume, with the real system HUD rather than an imitation of it.

**It is free and open source.** MIT licensed, no payment, no trial, no licence key, no accounts, no telemetry, no analytics, no network code of any kind. Install it with:

```bash
brew install --cask --no-quarantine helgafinn/tap/glisse
```

The `--no-quarantine` is not a trick — the build is ad-hoc signed rather than notarised, because notarisation needs a paid Apple Developer account this project does not have. Gatekeeper would otherwise refuse to open it. One consequence worth knowing before you install: because the signature is ad-hoc, macOS forgets the Accessibility grant on each upgrade and you have to give it again.

Every private symbol it touches is documented in the README with the reason no public alternative exists, including the parts that are unverified — the Intel paths are written but have only been tested on Apple Silicon. If you only want the technique rather than the app, `Sources/GlissePrivate/` is the interesting directory.
