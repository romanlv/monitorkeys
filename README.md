# MonitorKeys

A small macOS menu-bar app for external monitors on Apple Silicon:

- **Brightness:** one slider per display. It drives the monitor's backlight over DDC/CI, then dims
  further below the backlight's minimum with a dark overlay, which leaves colour apps such as f.lux
  alone. The overlay doesn't dim the pointer, the screen saver, the lock screen, or a game that
  takes over the whole display.
- **Brightness keys:** F1/F2 control the external display under the pointer, or the one with the
  active window. The built-in display stays with macOS.
- **Monitor speakers:** a volume slider and mute, plus volume and mute keys, while the Mac plays through the
  monitor (DisplayPort/HDMI audio that macOS can't control).
- **Day schedule:** brightness follows sunrise and sunset, with Day, Evening and Night levels and a
  bedtime. A manual change holds until the next transition.
- **Open at Login:** a menu toggle that registers the app as a macOS login item.

## Install

1. Download `MonitorKeys.zip` from [Releases](../../releases/latest).
2. Unzip it and move `MonitorKeys.app` to `/Applications`.
3. The app isn't notarized, so clear the download flag once before opening it:

```sh
xattr -dr com.apple.quarantine /Applications/MonitorKeys.app
open /Applications/MonitorKeys.app
```

Requires macOS 14+ on Apple Silicon.

## Build

Requires Swift 6.

```sh
scripts/make-signing-cert.sh   # optional, once: local signing so Accessibility permission survives rebuilds
scripts/build-app.sh           # → build/MonitorKeys.app
open build/MonitorKeys.app
swift test
```

The keyboard features need Accessibility permission (System Settings → Privacy & Security → Accessibility).

## Diagnostics

```sh
.build/release/MonitorKeys --probe                    # list displays, read backlight and speaker levels
.build/release/MonitorKeys --probe --ddc-set 50       # write raw luminance
.build/release/MonitorKeys --probe --volume-set 10    # write raw speaker volume
```

Bus timing can be overridden with the `MONITORKEYS_SENDS`, `MONITORKEYS_SETTLE_MS`, `MONITORKEYS_REPLY_MS` and `MONITORKEYS_READ_SENDS`
environment variables. The menu's **Advanced** submenu has the same knobs.

## Notes

- **Commands are sent twice by default.** Some monitors silently drop a single DDC write, and setting a
  value twice is harmless.
- **Monitor support varies.** The monitor must support DDC/CI, and not every monitor exposes speaker volume
  (VCP 0x62) or mute (0x8D).
- **Tested on** an M5 MacBook Pro with an LG UltraWide, macOS 26.
