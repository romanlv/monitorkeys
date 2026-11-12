import Foundation

/// Volume and mute for a monitor's speakers, as the user sees them, plus the hardware writes each
/// change needs. Monitors without a mute control are muted by setting the volume to 0; the
/// volume to come back to is kept either way.
public struct SpeakerModel: Equatable, Sendable {
    public enum Write: Equatable, Sendable {
        case volume(Double)
        case mute(Bool)
    }

    /// Volume to play at when not muted, 0...1.
    public private(set) var volume: Double
    public private(set) var muted: Bool
    public let hasMuteControl: Bool

    public init(volume: Double, muted: Bool, hasMuteControl: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
        self.hasMuteControl = hasMuteControl
    }

    /// What the volume indicator should show.
    public var audibleVolume: Double { muted ? 0 : volume }

    /// Sets the volume. Changing the volume while muted unmutes, as macOS does with its own keys.
    public mutating func setVolume(_ value: Double) -> [Write] {
        volume = min(max(value, 0), 1)
        guard muted else { return [.volume(volume)] }
        muted = false
        return hasMuteControl ? [.volume(volume), .mute(false)] : [.volume(volume)]
    }

    public mutating func setMuted(_ value: Bool) -> [Write] {
        guard value != muted else { return [] }
        muted = value
        if hasMuteControl { return [.mute(value)] }
        return [.volume(value ? 0 : volume)]
    }

    public mutating func toggleMute() -> [Write] { setMuted(!muted) }
}

/// Decides which monitor's speakers the sound keys should drive.
public enum SpeakerRouting {
    /// - Returns: the index into `monitors` (names of monitors with a DDC speaker control) to drive,
    ///   or nil to leave the keys to macOS.
    ///
    /// macOS handles any output whose volume it can set itself. Otherwise the output's name is
    /// matched against the monitor names (Core Audio names a display's audio after the display);
    /// when the name matches none but the sound goes over a display cable to the only monitor
    /// with a speaker control, that monitor is used.
    public static func pick(outputName: String, viaDisplayCable: Bool, hasSystemVolume: Bool,
                            monitors: [String]) -> Int? {
        guard !hasSystemVolume else { return nil }
        let wanted = outputName.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty, let i = monitors.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return i
        }
        return viaDisplayCable && monitors.count == 1 ? 0 : nil
    }
}
