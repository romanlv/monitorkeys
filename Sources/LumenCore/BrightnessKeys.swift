/// Keyboard brightness keys, decoded from the two event shapes macOS delivers them in.
public enum BrightnessKey: Equatable, Hashable, Sendable {
    case up, down
}

public struct BrightnessKeyPress: Equatable, Sendable {
    public var key: BrightnessKey
    public var isDown: Bool
    public var isRepeat: Bool
}

public enum BrightnessKeyDecoder {
    /// Auxiliary control buttons subtype of a system-defined (type 14) event.
    static let auxControlButtons: Int16 = 8
    /// Key codes inside data1 (IOKit hidsystem ev_keymap.h): NX_KEYTYPE_BRIGHTNESS_UP / _DOWN.
    static let brightnessUpCode = 2
    static let brightnessDownCode = 3
    /// Virtual key codes some keyboards send as plain key-down events for the same keys.
    static let brightnessUpVirtualKey: Int64 = 144
    static let brightnessDownVirtualKey: Int64 = 145

    /// data1 layout: bits 16-31 key code; bits 8-15 key state (0x0A down, 0x0B up); bit 0 repeat.
    public static func decodeSystemDefined(subtype: Int16, data1: Int) -> BrightnessKeyPress? {
        guard subtype == auxControlButtons else { return nil }
        let code = (data1 >> 16) & 0xFFFF
        let state = (data1 >> 8) & 0xFF
        let key: BrightnessKey
        switch code {
        case brightnessUpCode: key = .up
        case brightnessDownCode: key = .down
        default: return nil
        }
        switch state {
        case 0x0A: return BrightnessKeyPress(key: key, isDown: true, isRepeat: data1 & 1 != 0)
        case 0x0B: return BrightnessKeyPress(key: key, isDown: false, isRepeat: false)
        default: return nil
        }
    }

    public static func decodeKeyDown(virtualKey: Int64) -> BrightnessKey? {
        switch virtualKey {
        case brightnessUpVirtualKey: return .up
        case brightnessDownVirtualKey: return .down
        default: return nil
        }
    }
}

public enum LumenStep {
    /// Moves one notch on a 16-step grid (64 with `fine`), snapping off-grid values to the next notch.
    public static func next(from value: Double, key: BrightnessKey, fine: Bool) -> Double {
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
