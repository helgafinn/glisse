# Glissé manual QA sheet

Automated coverage (`make test`, `--selftest`) cannot touch a trackpad or close a
lid. This is the part that needs hands.

Copy this file per machine, fill in the header, work down the list.

---

## Machine

```
Mac model            :
Chip                 :
macOS version        :
Built-in trackpad    : yes / no
Magic Trackpad       : yes / no          model:
External display 1   :                   connection: HDMI / USB-C / DP / dock
External display 2   :                   connection:
Audio output devices :
Tester / date        :
```

Run first and paste the output:

```bash
make probe
make test
dist/Glissé.app/Contents/MacOS/Glisse --selftest
```

---

## 1. Coordinate contract — do this before anything else

`make diagnose`, then:

| Action | Expected | Pass |
| --- | --- | --- |
| Touch the far left edge | `x` reads ≈ 0.00, shows `LEFT-EDGE` | ☐ |
| Touch the far right edge | `x` reads ≈ 1.00, shows `RIGHT-EDGE` | ☐ |
| Touch the bottom edge (nearest you) | `y` reads ≈ 0.00 | ☐ |
| Touch the top edge (nearest keyboard) | `y` reads ≈ 1.00 | ☐ |
| Slide a finger upward | `dY` goes **positive** | ☐ |
| Slide a finger downward | `dY` goes **negative** | ☐ |
| Move the pointer around for ~10 s | axis verdict prints `matchesContract` | ☐ |
| After 10 s | `MTTouch layout` prints `validated` | ☐ |

If the axis verdict is `inverted`, turn on **Settings → Advanced → Invert
vertical direction** and note it here. If any of the four position checks are
wrong, stop and report the numbers — nothing below will be meaningful.

Record the actual readings:

```
left edge x   =            right edge x  =
bottom y      =            top y         =
layout        =            axis verdict  =
```

---

## 2. Core behaviour

| Check | Expected | Pass |
| --- | --- | --- |
| Right edge, slide up | Volume rises, the **real macOS volume HUD** appears | ☐ |
| Right edge, slide down | Volume falls | ☐ |
| Left edge, slide up | Brightness rises (screen visibly brighter) | ☐ |
| Left edge, slide down | Brightness falls | ☐ |
| Release finger mid-slide | Change stops instantly | ☐ |
| Slide feels continuous | No 16-step jumps, no stutter, no lag | ☐ |
| Haptic ticks | Present, paced with the value, not a buzz | ☐ |
| Slide to the very top | Reaches exactly 100%, one distinct end-stop tick | ☐ |
| Slide to the very bottom | Reaches 0%, volume mutes, speaker icon shows muted | ☐ |
| From muted 0%, slide up | Audio becomes audible again (not silently muted) | ☐ |
| Start a slide at the bottom of the edge | Works the same as starting at the top | ☐ |
| Two slides of equal length from different heights | Produce the same amount of change | ☐ |

---

## 3. Accidental activation — spend the most time here

Use the Mac normally for at least 20 minutes with Glissé enabled, then work
through this deliberately. Any unintended change is a failure worth reporting
with what you were doing.

| Activity | Expected | Pass |
| --- | --- | --- |
| Browsing in Safari, scrolling with two fingers | No change | ☐ |
| Two-finger scroll started right at the edge | No change | ☐ |
| Selecting text by dragging | No change | ☐ |
| Dragging a file across the desktop | No change | ☐ |
| Fast typing with palms near the trackpad | No change | ☐ |
| Typing then immediately touching the edge | Suppressed for ~0.5 s | ☐ |
| Pinch to zoom | No change | ☐ |
| Three/four-finger swipe between desktops | Works normally, no change | ☐ |
| Mission Control (four fingers up) | Works normally, no change | ☐ |
| Notification Centre swipe from the right edge | Works normally, no change | ☐ |
| Casual pointer movement across the whole pad | No change | ☐ |
| Pointer movement starting mid-pad, ending at the edge, then vertical | **No change** (the critical case) | ☐ |
| Resting a finger on the edge without moving | No change | ☐ |
| Resting a finger on the edge for 5 s, then sliding | No change (candidate timed out) | ☐ |
| Force click / click-and-drag at the edge | No unintended change | ☐ |
| Gaming or a full-screen app, if relevant | No change | ☐ |

Note anything that fired unintentionally:

```
```

---

## 4. Options

| Option | Check | Pass |
| --- | --- | --- |
| Fine Control on | Same finger travel produces a much smaller change, still immediate | ☐ |
| Fine Control on | Single-percent adjustments are achievable | ☐ |
| Swap Sides on | Left = volume, right = brightness | ☐ |
| Swap Sides on | Menu labels match the physical behaviour | ☐ |
| Bottom Quarter on | Starting near the top of the edge does nothing | ☐ |
| Bottom Quarter on | Starting in the lower quarter works | ☐ |
| Bottom Quarter on | A gesture started low may slide the full height | ☐ |
| Freeze Cursor on | Pointer stays put while sliding | ☐ |
| Freeze Cursor on | Pointer moves normally again the instant you lift | ☐ |
| Freeze Cursor on | Quit mid-slide (menu → Quit) leaves pointer working | ☐ |
| Freeze Cursor on | `pkill Glissé` mid-slide leaves pointer working | ☐ |
| Haptics off | No ticks, adjustment still smooth | ☐ |
| macOS On-Screen Display off | No HUD, adjustment still works and is continuous | ☐ |
| macOS On-Screen Display on, Accessibility denied | No HUD, menu explains why, value still changes | ☐ |
| Slide to zero volume | The real macOS **mute** HUD appears | ☐ |
| Brightness on a pinned/external display | Value changes, no HUD (documented) | ☐ |
| Pause While Typing off | Edge works immediately after a keystroke | ☐ |
| Left/Right edge = Nothing | That edge is inert | ☐ |
| Enabled off | Nothing responds, icon dims, settings preserved | ☐ |
| Enabled back on | Works again without restart | ☐ |

### Modifier

| Mode | Check | Pass |
| --- | --- | --- |
| Hold Option | Edge does nothing without Option held | ☐ |
| Hold Option | Works while Option is held | ☐ |
| Hold Option | Releasing Option mid-slide ends the gesture | ☐ |
| Hold Option | Option still behaves normally elsewhere (⌥-click, ⌥-drag) | ☐ |
| Toggle Control | First press activates; icon un-dims | ☐ |
| Toggle Control | Second press deactivates; icon dims; menu says "Paused" | ☐ |
| Toggle Control | Control still works normally as a modifier | ☐ |

### Three-finger middle click

| Check | Expected | Pass |
| --- | --- | --- |
| Deliberate three-finger tap | Exactly one middle click (test in a browser: opens link in new tab) | ☐ |
| Ten taps in a row | Exactly ten clicks, never eleven | ☐ |
| Three-finger hold (>0.5 s) | No click | ☐ |
| Three-finger swipe | No click, macOS gesture works | ☐ |
| Two-finger tap | No click | ☐ |
| Four-finger tap | No click | ☐ |
| Tap during an edge slide | No click | ☐ |

---

## 5. Audio device changes — app stays running throughout

| Transition | Then test the right edge | Pass |
| --- | --- | --- |
| Internal speakers → Bluetooth headphones / AirPods | Controls the new device | ☐ |
| AirPods → internal speakers | Controls speakers | ☐ |
| Internal → wired headphones | Controls headphones | ☐ |
| Internal → USB audio interface | Controls it, or menu says unsupported | ☐ |
| Internal → HDMI / external display audio | Controls it, or menu says unsupported | ☐ |
| Device disconnected mid-slide | No crash, no stuck gesture | ☐ |
| Menu shows the current device name | Correct after every transition | ☐ |

---

## 6. Displays — app stays running throughout

| Transition | Check | Pass |
| --- | --- | --- |
| Built-in only | Left edge controls built-in backlight | ☐ |
| Connect USB-C display | Appears in Settings → Displays with a backend | ☐ |
| Connect HDMI display | Appears with a backend | ☐ |
| DDC-capable external | Brightness actually changes | ☐ |
| DDC-capable external | Native VCP max is reported (not assumed 100) | ☐ |
| Non-DDC external (dock / DisplayLink) | Marked unsupported, no crash, no hang | ☐ |
| Brightness Target = Main Display | Follows which display is main | ☐ |
| Brightness Target = Display Under Cursor | Follows the pointer | ☐ |
| Brightness Target = All Supported | Both displays move together | ☐ |
| Pin a specific display | Only that one moves | ☐ |
| Disconnect a display mid-slide | No crash, no stuck gesture | ☐ |
| Reconnect it | Detected again without restarting the app | ☐ |
| Change display arrangement | No crash, targets still correct | ☐ |
| Rotate / change resolution | No crash | ☐ |
| Monitor sleeps and wakes | Brightness still controllable | ☐ |

---

## 7. Sleep / wake — 10 cycles, zero restarts

For each cycle: confirm volume **and** brightness work, close the lid (or
`pmset sleepnow`), wait ≥ 30 s, open, unlock, then test both again.

| # | Volume after wake | Brightness after wake | Notes | Pass |
| --- | --- | --- | --- | --- |
| 1 | ☐ | ☐ | | ☐ |
| 2 | ☐ | ☐ | | ☐ |
| 3 | ☐ | ☐ | | ☐ |
| 4 | ☐ | ☐ | | ☐ |
| 5 | ☐ | ☐ | | ☐ |
| 6 | ☐ | ☐ | | ☐ |
| 7 | ☐ | ☐ | | ☐ |
| 8 | ☐ | ☐ | | ☐ |
| 9 | ☐ | ☐ | | ☐ |
| 10 | ☐ | ☐ | | ☐ |

Also:

| Check | Expected | Pass |
| --- | --- | --- |
| Display sleep only (no system sleep), then wake | Works | ☐ |
| Lock screen, unlock | Works | ☐ |
| Fast user switch away and back | Works | ☐ |
| Sleep while a gesture is active | Wakes with no stuck gesture, pointer free | ☐ |
| Lid closed with an external display (clamshell) | Volume works; brightness targets the external | ☐ |

---

## 8. Trackpad hot-plug

| Transition | Check | Pass |
| --- | --- | --- |
| Connect a Magic Trackpad over Bluetooth | Appears; both trackpads work | ☐ |
| Slide on built-in, then on Magic Trackpad | Independent, no interference | ☐ |
| A finger on each simultaneously | Only one gesture drives at a time | ☐ |
| Disconnect the Magic Trackpad | Built-in keeps working, no crash | ☐ |
| Disconnect it mid-slide | No stuck gesture, pointer free | ☐ |
| Reconnect | Works again without restarting | ☐ |
| Bluetooth off then on | Recovers | ☐ |

---

## 9. Permissions

| Check | Expected | Pass |
| --- | --- | --- |
| First launch, nothing granted | Edge sliding, volume, brightness all work | ☐ |
| First launch | Typing-pause and middle-click menu items are disabled with a tooltip | ☐ |
| Enable Pause While Typing without permission | Explains why, offers System Settings | ☐ |
| Grant Accessibility while running | Features light up without restarting | ☐ |
| Revoke Accessibility while running | No crash; dependent features go quiet; edges still work | ☐ |
| Permissions… when granted | Reports Granted | ☐ |
| Decline once | Not asked again on subsequent launches | ☐ |
| Move the app, relaunch | No crash; re-grant if macOS asks | ☐ |

---

## 10. Login item and lifecycle

| Check | Expected | Pass |
| --- | --- | --- |
| App in /Applications, Launch at Login on | Survives a reboot and starts silently | ☐ |
| Launch at Login off | Does not start after reboot | ☐ |
| Menu state matches System Settings → Login Items | Always | ☐ |
| Turn off, quit, relaunch | Still off | ☐ |
| Change several settings, quit, relaunch | All preserved | ☐ |
| Quit from the menu | Exits cleanly, no crash report | ☐ |
| Quit with a gesture active | Exits cleanly, pointer free | ☐ |
| Relaunch immediately | No duplicate menu bar icon | ☐ |

---

## 11. Resources

Measure with Activity Monitor or `ps -o %cpu,rss -p $(pgrep -x Glissé)`.

| Metric | Target | Measured | Pass |
| --- | --- | --- | --- |
| Idle CPU (60 s, no touching) | ≈ 0% | | ☐ |
| CPU during continuous sliding | < 5% | | ☐ |
| Memory footprint (`footprint -p`) | < 40 MB | | ☐ |
| Bundle size | < 5 MB | | ☐ |
| No thermal or fan change while idle | | | ☐ |
| Battery: no measurable drain versus app quit | | | ☐ |

---

## 12. Stability

| Check | Expected | Pass |
| --- | --- | --- |
| 4+ hours of normal use | No crash, no degradation | ☐ |
| `log show --predicate 'subsystem == "xyz.glisse.Glisse"' --last 4h` | No repeated errors | ☐ |
| `~/Library/Logs/DiagnosticReports` | No Glissé crash reports | ☐ |
| Diagnostics window open for 10 minutes | No leak, CPU stays low | ☐ |
| Rapid enable/disable 20 times | No crash, no stuck state | ☐ |
| Rapid open/close of Settings 20 times | No crash | ☐ |

---

## Sign-off

```
Blocking issues     :
Non-blocking issues :
Tuning changes made : edge width =        vertical intent =
                      sensitivity =       typing pause =
Verdict             : ship / fix first
```
