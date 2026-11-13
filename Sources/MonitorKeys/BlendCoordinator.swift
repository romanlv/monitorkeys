import CoreGraphics
import Foundation
import MonitorKeysCore

/// Owns one display: turns a brightness value into backlight + dimmer writes, and only writes a channel
/// whose level actually changed.
final class BlendCoordinator {
    let display: CGDirectDisplayID
    let name: String
    let backlight: BacklightChannel?
    /// The monitor's speakers, when it reports a DDC speaker volume. Rides along on the same bus.
    let speaker: BusSpeaker?
    /// Software dimming below the backlight's floor. A replacement coordinator for the same display
    /// takes it over and starts from its level.
    let shade: Shade
    private var table: RampTable
    private var written: ChannelLevels
    private(set) var brightness: Double

    var policy: RampPolicy {
        didSet { table = RampTable(policy: Self.effective(policy, hasBacklight: backlight != nil)); apply() }
    }

    /// Starts from what the hardware reports now, so creating a coordinator writes nothing.
    /// `shade` is the dimming overlay of the coordinator this one replaces for the same display, if any.
    init(display: CGDirectDisplayID, name: String, backlight: BacklightChannel?, speaker: BusSpeaker? = nil,
         policy: RampPolicy, shade: Shade? = nil) {
        self.display = display
        self.name = name
        self.backlight = backlight
        self.speaker = speaker
        self.shade = shade ?? Shade(display: display)
        self.policy = policy
        let table = RampTable(policy: Self.effective(policy, hasBacklight: backlight != nil))
        self.table = table
        let current = ChannelLevels(backlight: backlight?.read() ?? 1, dimmer: self.shade.level)
        self.written = current
        self.brightness = table.brightness(for: current)
    }

    /// An external display that has no backlight channel yet; worth probing for DDC again.
    var needsProbe: Bool { backlight == nil && CGDisplayIsBuiltin(display) == 0 }

    /// The DDC bus this display's channels use, if any.
    var busID: UInt64? { (backlight as? BusBacklight)?.link.registryID ?? speaker?.link.registryID }

    func set(brightness value: Double) {
        brightness = min(max(value, 0), 1)
        apply()
    }

    /// Pick up a backlight change made elsewhere (monitor buttons, macOS brightness keys).
    /// Returns true when the hardware level had moved away from what we last wrote.
    @discardableResult
    func resync() -> Bool {
        guard let level = backlight?.read() else { return false }
        let moved = abs(level - written.backlight) > 0.01
        written.backlight = level
        if moved, written.dimmer < 1 {
            // Someone else is adjusting brightness: stop dimming on top of their choice.
            shade.write(1)
            written.dimmer = 1
        }
        brightness = table.brightness(for: written)
        return moved
    }

    private func apply() {
        let target = table.levels(forBrightness: brightness)
        if let backlight, abs(target.backlight - written.backlight) > 0.0005 {
            backlight.write(target.backlight)
            written.backlight = target.backlight
        }
        if abs(target.dimmer - written.dimmer) > 0.0005 {
            shade.write(target.dimmer)
            written.dimmer = target.dimmer
        }
    }

    private static func effective(_ p: RampPolicy, hasBacklight: Bool) -> RampPolicy {
        hasBacklight ? p : .softwareOnly(dimmerFloor: p.dimmerFloor)
    }
}
