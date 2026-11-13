# How BetterDisplay's "Brightness (Combined)" works, compared with MonitorKeys

Studied 2026-11-13 against BetterDisplay 5.2.1 (`/Applications/BetterDisplay.app`, arm64 slice,
sha256 of the universal binary `f0b874e4…cbca6`) on the LG ULTRAWIDE (DDC luminance max = 100).

## Sources of evidence

| Source | What it gave |
|---|---|
| `defaults read pro.betterdisplay.BetterDisplay` | Saved values of each brightness controller per display |
| `MonitorKeys --probe` while BetterDisplay was running | The LG's real DDC luminance at that moment |
| Strings in the binary | Setting names and their help text |
| `otool -tvV` disassembly | Where the per-display setting keys are registered |
| REA (Hopper) | Nothing yet: Hopper's initial analysis of the 41 MB binary timed out (see "Open questions") |

## Findings

### 1. Combined brightness is three controllers on one scale

BetterDisplay keeps a separate value for each controller and derives one "combined" value from them.
The saved state for the LG (BetterDisplay's `Display:3`) when the slider showed 69%:

```
value@combinedBrightness-CombinedController@Display:3 = 0.6875
value@hardwareBrightness-DDCController@Display:3      = 0.375    (DDC luminance 37.5 of 100)
value@softwareBrightness-ColorController@Display:3    = 1        (no software dimming)
```

`--probe` read the LG at that moment as **0.380** (raw 38 of 100), which matches the hardware value
above.

The binary's help text describes the same three parts:

> Combine hardware brightness control (if available), software dimming and XDR/HDR upscaling into one
> unified brightness control.

> **Combined brightness - software dimming switchover point:** Below this level on the combined
> brightness scale the app uses additional software dimming (as hardware backlight control reached the
> lowest possible level).

### 2. The switchover point is at 50%, and the hardware half is linear (inferred)

`0.6875 = 0.5 + 0.5 × 0.375` exactly. That fits:

```
combined ∈ [0, p]   → DDC at its minimum, software dimming rises from its floor to 1
combined ∈ [p, 1]   → software at 1, DDC = (combined − p) / (1 − p)        with p = 0.5
```

No `combinedDimmingPoint` key is saved, so the value in use is the app's default. The per-display
setting (registered at `0x1009723a8`, key `combinedDimmingPoint`) is created with a nil default
(`x0 = 0, w1 = 1` at its call site `0x10097bfbc`), so the effective default comes from a global
setting elsewhere. One data point can't separate the switchover point from a curve: if
`combinedCurve` bends the scale, another switchover point could also give 0.6875. **To confirm:** move
the slider to two or three other levels and read DDC with `--probe`, or decompile once Hopper finishes.

### 3. Related settings found in the binary

| Key | Help text (abridged) | MonitorKeys equivalent |
|---|---|---|
| `combinedDimmingPoint` | software dimming switchover point | `dimmingStart` (default **0.3**) |
| `combinedMinHardwareBrightness` | lowest hardware level, on the monitor's own scale, below which software dimming takes over (for PWM sensitivity) | `backlightFloor` (default 0) |
| `combinedCurve` | (no help text; there is also `audioCurve`) | none: MonitorKeys is linear |
| `softwareBrightnessMinOverride` | "lower bound of brightness control in nits. Use 0 to allow full continuous dimming to black." | `dimmerFloor` fixed at **0.15** |
| `softwareDimmingGammaAdjustmentFactor` | "Certain displays (typically those utilizing a backlight technology) produce a more natural image when the gamma is subtly adjusted on software dimming - this gives the image a better contrast." | none: MonitorKeys's overlay is flat black |
| `ddcBacklightOffWhenCombinedDimmedToZero` | turn the backlight off at combined 0 | none |
| `combinedUpscalingMax`, `upscale*` | XDR/HDR upscaling above 100% | n/a: needs an XDR panel or an HDR display in HDR mode; `configuredPotentialEDR` is 1 for the LG, so it isn't in use here |

### 4. Software dimming uses the colour table by default

The software controller in use is `ColorController`, which dims through the gamma/colour table. That's
the method MonitorKeys left in 0.2.4 because it overrides f.lux's tint. BetterDisplay can also dim with
an overlay ("overlay dimming only", "overlay dimming with Metal for additional adjustments"). It
warns that colour-table dimming clips HDR content.

At the time of measurement both displays had an identity gamma table (f.lux daytime, no dimming), so
the colour table played no part in the morning comparison.

## How the two apps compare on the LG

| Slider | BetterDisplay (p = 0.5) | MonitorKeys (dimmingStart = 0.3) |
|---|---|---|
| 100% | DDC 100 | DDC 100 |
| 85.6% (MonitorKeys Day level) | DDC 71 | DDC 79 |
| 69% | DDC 38 (measured) | DDC 56 |
| 50% | DDC 0, no dimming | DDC 29 |
| 30% | DDC 0, software ≈ 60% (if linear) | DDC 0, overlay off |
| 0% | DDC 0, software at its floor, as low as black | DDC 0, overlay at 15% |

What this shows:

- **Peak brightness is the same.** Both reach DDC 100 at the top of the slider, and BetterDisplay can't
  go past 100 on this monitor without HDR upscaling.
- **At the same slider value, BetterDisplay sends a *lower* DDC level.** It gives half the slider to
  software dimming; MonitorKeys gives 30%.
- **Most of BetterDisplay's extra range is at the dark end.** Half the slider is dimming, and that
  dimming can go down to black. MonitorKeys stops at 15%.
- **The "brighter this morning" impression isn't explained by the mapping.** At 09:38 MonitorKeys's
  schedule (Toronto, Day level 0.856, wake-up 07:00) asks for DDC ≈ 79. BetterDisplay was holding the
  LG at DDC 38. Possible causes, none verified:
  - MonitorKeys wasn't running this morning: only BetterDisplay was. So the comparison may be against
    an earlier MonitorKeys state, such as a manual change held until the next transition, or a DDC
    write the monitor dropped.
  - Contrast: dimming through the colour table keeps black levels relative and BetterDisplay adds a
    gamma lift. A flat black overlay lowers contrast as well as brightness, so it looks dimmer at the
    same light output.

## Ideas for MonitorKeys

1. Make `dimmerFloor` adjustable, with 0 allowed (dimming to black), like `softwareBrightnessMinOverride`.
2. Consider a default switchover point of 0.5. That moves DDC lower for any given slider value and gives
   finer steps in the dark range.
3. A perceptual curve (`combinedCurve`): a linear DDC scale crowds the visible change into the low end.
4. Gamma-aware dimming without touching the colour table: a Core Image or Metal overlay could apply
   a slight gamma lift, keeping f.lux working while getting BetterDisplay's better contrast.

## Open questions

- The exact default of `combinedDimmingPoint` and the shape of `combinedCurve`. Needs decompilation or two
  or three more readings.
- REA/Hopper: the session opened at 09:38 timed out during Hopper's initial analysis, and its cleanup
  (`/private/tmp/rea-nZ5Rcj`) was still waiting. Once Hopper finishes, `close_binary` releases it.
  The next attempt should raise `hopper.startup_timeout_ms`, or use the thin arm64 slice
  (`lipo -thin arm64`).

## Follow-up: a likely cause of the dim LG in MonitorKeys

MonitorKeys never read an external monitor back after writing to it. `BlendCoordinator` and
`BusLink` both cache the last value written and skip a write of the same value. So if the LG dropped
a write (the reason `sendsPerValue` defaults to 2), or came back from sleep at a level of its own,
MonitorKeys went on believing its own value. During the Day plateau the target doesn't change, so
nothing was sent again until the evening ramp. The monitor stayed wherever it had ended up.

Changes made in 0.3.0, all in the Advanced menu and listed in the README:

- The write queue moved into `MonitorKeysCore/VCPWriteQueue.swift` so it can be tested without a
  monitor. Once writes pause for 250 ms it reads each code back. On a mismatch it resends twice and logs.
- **Tested on the LG:** with `MONITORKEYS_SENDS=1`, the LG ignored every single write that came right
  after a read, which explains why two sends are needed. The read-back caught each one, and a resend
  sent only once was ignored too. Sending the resend twice fixed it: 40 and 52 both landed. With the
  default two sends, nothing needed resending.
- 5 s after wake, each DDC display's level is sent again.
- DDC monitors are read every 30 s in the background. A changed level is
  followed and holds the schedule. A read that one of our own writes overtakes is discarded.
- Slider response: Linear, or "Finer at the dark end" (exponent 2 within each part of the ramp, with
  breakpoints unchanged). Apple panels stay linear.
- Darkest software dimming: 15%, 10% or 5%.

Not done: the contrast-keeping dimming. An overlay window can only blend a flat colour over what's below
it, so it can't lift dark tones. That takes the colour table (which overrides f.lux) or screen capture
with re-rendering (what BetterDisplay's Metal mode does, and it needs Screen Recording permission).
