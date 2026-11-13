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
    /// Bumped by every backlight write and by `dropReadsInProgress`; a background read that started
    /// before a bump is out of date.
    private var readGeneration = 0
    /// A background read is running; another isn't started on top of it.
    private var reading = false
    /// An unconfirmed write was sent once more; if that doesn't take either, the monitor's level stands.
    private var retriedUnconfirmed = false
    private(set) var brightness: Double

    var policy: RampPolicy {
        didSet {
            table = RampTable(policy: Self.effective(policy, backlight: backlight))
            // Keep the screen as it is: the same channel levels sit at a new place on the new scale.
            // apply() then only enforces limits the new policy adds, such as a higher floor.
            brightness = table.brightness(for: written)
            apply()
        }
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
        let table = RampTable(policy: Self.effective(policy, backlight: backlight))
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
        return adopt(level)
    }

    /// `resync` with the read done off the main thread, for DDC monitors whose reads take a while.
    /// Calls back on the main thread with whether the level had moved; a read overtaken by a write
    /// of ours is dropped (reported as not moved).
    func resyncInBackground(_ done: @escaping (Bool) -> Void) {
        guard let backlight, !reading else { return done(false) }
        reading = true
        let generation = readGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A DDC read waits for every write queued before it, so it sees our latest value.
            let level = backlight.read()
            DispatchQueue.main.async {
                self?.reading = false
                guard let self, let level, generation == self.readGeneration else { return done(false) }
                done(self.adopt(level))
            }
        }
    }

    /// A background read already running is ignored when it finishes (sleep may change the level).
    func dropReadsInProgress() {
        readGeneration += 1
    }

    private func adopt(_ level: Double) -> Bool {
        let bus = backlight as? BusBacklight
        // A DDC level is a whole step of the monitor: compare in steps, so our unrounded value counts
        // as the step it was sent as, and a single press of the monitor's buttons still counts.
        let same = bus.map { b in
            (level * Double(b.maximum)).rounded() == (written.backlight * Double(b.maximum)).rounded()
        } ?? (abs(level - written.backlight) <= 0.01)
        guard !same else {
            bus?.confirm() // the monitor holds our level after all
            retriedUnconfirmed = false
            return false
        }
        if let bus, bus.isUnconfirmed {
            // Our last write failed, went unanswered or was refused, so this level is the monitor's,
            // not a change made on it. Send ours once more; if that doesn't take either, show what the
            // screen is really at and nothing more: the dimming stays and nothing is held.
            if !retriedUnconfirmed {
                retriedUnconfirmed = true
                readGeneration += 1
                bus.rewrite(written.backlight)
                return false
            }
            retriedUnconfirmed = false
            bus.confirm()
            written.backlight = level
            brightness = table.brightness(for: written)
            return false
        }
        retriedUnconfirmed = false
        written.backlight = level
        if written.dimmer < 1 {
            // Someone else is adjusting brightness: stop dimming on top of their choice.
            shade.write(1)
            written.dimmer = 1
        }
        brightness = table.brightness(for: written)
        return true
    }

    /// Some monitors come back from sleep or standby at a level of their own, which the caches
    /// here and in the link would never notice. Sends the current backlight level again.
    func reassert() {
        guard let bus = backlight as? BusBacklight else { return }
        readGeneration += 1
        bus.rewrite(written.backlight)
        // The speaker may also have woken at its own volume: don't skip the next choice as unchanged.
        if let link = speaker?.link {
            link.forget(MCCS.Code.speakerVolume)
            link.forget(MCCS.Code.audioMute)
        }
    }

    private func apply() {
        let target = table.levels(forBrightness: brightness)
        if let backlight, abs(target.backlight - written.backlight) > 0.0005 {
            backlight.write(target.backlight)
            written.backlight = target.backlight
            readGeneration += 1
            retriedUnconfirmed = false // a new value gets its own retry
        }
        if abs(target.dimmer - written.dimmer) > 0.0005 {
            shade.write(target.dimmer)
            written.dimmer = target.dimmer
        }
    }

    private static func effective(_ p: RampPolicy, backlight: BacklightChannel?) -> RampPolicy {
        guard let backlight else { return .softwareOnly(dimmerFloor: p.dimmerFloor, curve: p.curve) }
        var p = p
        // Apple panels' brightness scale is already perceptual; a curve on top would bend it twice.
        if backlight is BuiltInBacklight { p.curve = 1 }
        return p
    }
}
