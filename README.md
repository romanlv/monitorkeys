# Lumen

A menu-bar app with one brightness slider per display. Each slider blends the display's hardware
backlight with software dimming, so it can go darker than the backlight alone.

## Build and run

```sh
scripts/build-app.sh      # → build/Lumen.app
open build/Lumen.app
swift test                # core logic tests
```

### Diagnostics (no UI)

```sh
.build/release/Lumen --probe                  # list displays and channels, read levels; writes nothing
.build/release/Lumen --probe --ddc-set 63     # also write raw luminance 63 to external monitors
LUMEN_READ_SENDS=1 LUMEN_REPLY_MS=100 LUMEN_SETTLE_MS=50 .build/release/Lumen --probe   # try bus timings
```

## How it works

| Piece | File |
|---|---|
| Lumen → (backlight, dimmer) ramp, and the reverse | `Sources/LumenCore/Ramp.swift` |
| DDC/CI message codec (VESA MCCS: Set/Get VCP, checksums, reply validation) | `Sources/LumenCore/MCCS.swift` |
| External monitor backlight over DDC (coalesced writes, tunable timing) | `Sources/Lumen/BusBacklight.swift` |
| Apple panel backlight, gamma dimmer | `Sources/Lumen/Channels.swift` |
| Per-display coordinator (writes only channels that changed) | `Sources/Lumen/BlendCoordinator.swift` |
| Menu, settings, display hot-plug and wake handling | `Sources/Lumen/AppDelegate.swift` |
| Brightness key decoding and stepping | `Sources/LumenCore/BrightnessKeys.swift` |
| Event tap for the keys, on-screen level indicator | `Sources/Lumen/BrightnessKeyTap.swift` |
| Sunrise/sunset maths and the day curve | `Sources/LumenCore/DaySchedule.swift` |
| Schedule driver, location lookup | `Sources/Lumen/DayScheduler.swift` |
| Day Schedule window | `Sources/Lumen/ScheduleView.swift` |

- **Ramp.** Above "software dimming below" (default 30%), only the backlight moves, from its floor up to
  max. Below it, the backlight stays at its floor and the gamma dimmer goes down to 15%.
- **Launch changes no backlight.** The slider starts from the backlight level the hardware reports. Launch only
  resets leftover gamma dimming. If the day schedule is on, it then glides displays toward the schedule.
- **DDC writes are sent once by default**, never repeated for an unchanged value, and coalesced
  while you drag. "DDC sends per change" and "DDC settle time" in the menu tune this per setup.
- **Read requests are sent twice** before reading the reply, because the tested monitor answered a
  single request with a DDC null message.
- **Quitting restores the gamma** on every display.

## Brightness keys (F1/F2)

In the menu, under **"Brightness keys control external display"**, pick which display the keys follow:
- **Display under the pointer** (default).
- **Display with the active window:** the display showing most of the front window of the app you're
  using. If that app has no window, the display under the pointer is used instead.

macOS then asks for Accessibility permission (System Settings → Privacy & Security → Accessibility).
- **That display is external:** the keys move its slider in 1/16 steps (1/64 with Option+Shift),
  including the software dimming below the backlight's range, and a small level indicator appears on it.
- **That display is the built-in one:** the keys pass through untouched, and macOS handles them as usual.

**Signing.** macOS remembers the Accessibility permission per signing identity. Run `scripts/make-signing-cert.sh`
once: it creates a self-signed certificate in `signing/lumen.keychain-db`, a project-local keychain that is
not your login keychain and is ignored by git. `build-app.sh` then signs with it, and the permission survives
rebuilds. Without the certificate, the app is ad-hoc signed, and the permission must be granted again after every rebuild.

The tap receives every key-down event, but it only reads the key code to recognise the brightness keys, and
returns every other event unchanged. Nothing is stored or logged (`Sources/Lumen/BrightnessKeyTap.swift`).

## Day schedule

Turn on **"Adjust brightness through the day"** in the menu. Then set the levels in **Day Schedule…**.
- **Three levels:** Day, Evening and Night. Each is the same combined value as the slider, so Night can go
  below the backlight's minimum.
- **Day ↔ Evening** follows the sun: the change is centred on sunset and on sunrise. Sunrise and sunset come
  from your location, found by city search or this Mac's location. Without a location, Lumen uses 7:00 and 19:00.
- **Evening → Night** is complete at bedtime, and **Night** is over by wake-up.
- **Every change is gradual.** It takes the "Changes take" time (60 minutes by default).
- **Manual changes win.** Moving a slider or pressing the brightness keys holds that display until the next
  change in the schedule starts. "Resume schedule" in the menu ends the hold early.
- **Built-in display:** left alone unless you turn on "Also adjust the built-in display".

## Tested on

M5 MacBook Pro, macOS 26.6, with an LG ULTRAWIDE (DDC luminance read and write accepted) and the built-in XDR panel.

## Not built (yet)

The URL scheme, the Shortcuts action, per-display settings, Intel Macs, HDR upscaling above 100%, and
re-syncing after the monitor's own buttons change brightness (use "Re-read hardware levels").
