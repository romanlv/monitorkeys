/// Direction of a stepping key.
public enum StepDirection: Equatable, Hashable, Sendable {
    case up, down
}

/// Keyboard brightness and sound keys, decoded from the two event shapes macOS delivers them in.
public enum MediaKey: Equatable, Hashable, Sendable {
    case brightness(StepDirection)
    case volume(StepDirection)
    case mute
}

public struct MediaKeyPress: Equatable, Sendable {
    public var key: MediaKey
    public var isDown: Bool
    public var isRepeat: Bool
}

public enum MediaKeyDecoder {
    /// Auxiliary control buttons subtype of a system-defined (type 14) event.
    static let auxControlButtons: Int16 = 8

    /// Key codes inside data1 (IOKit hidsystem ev_keymap.h, NX_KEYTYPE_*).
    static func key(forAuxCode code: Int) -> MediaKey? {
        switch code {
        case 0: .volume(.up)
        case 1: .volume(.down)
        case 2: .brightness(.up)
        case 3: .brightness(.down)
        case 7: .mute
        default: nil
        }
    }

    /// data1 layout: bits 16-31 key code; bits 8-15 key state (0x0A down, 0x0B up); bit 0 repeat.
    public static func decodeSystemDefined(subtype: Int16, data1: Int) -> MediaKeyPress? {
        guard subtype == auxControlButtons, let key = key(forAuxCode: (data1 >> 16) & 0xFFFF) else { return nil }
        switch (data1 >> 8) & 0xFF {
        case 0x0A: return MediaKeyPress(key: key, isDown: true, isRepeat: data1 & 1 != 0)
        case 0x0B: return MediaKeyPress(key: key, isDown: false, isRepeat: false)
        default: return nil
        }
    }

    /// Virtual key codes some keyboards send as plain key events for the same keys
    /// (HIToolbox Events.h: kVK_VolumeUp/Down/Mute, and the brightness keys).
    public static func decodeKeyDown(virtualKey: Int64) -> MediaKey? {
        switch virtualKey {
        case 144: .brightness(.up)
        case 145: .brightness(.down)
        case 0x48: .volume(.up)
        case 0x49: .volume(.down)
        case 0x4A: .mute
        default: nil
        }
    }
}

public enum LevelStep {
    /// Moves one notch on a 16-step grid (64 with `fine`), snapping off-grid values to the next notch.
    public static func next(from value: Double, key: StepDirection, fine: Bool) -> Double {
        let steps = fine ? 64.0 : 16.0
        let position = value * steps
        let target: Double
        switch key {
        case .up: target = (position + 1e-6).rounded(.down) + 1
        case .down: target = (position - 1e-6).rounded(.up) - 1
        }
        return min(max(target / steps, 0), 1)
    }
}
