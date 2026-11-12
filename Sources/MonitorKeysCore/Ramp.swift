/// How one "brightness" value (0...1) is split between the hardware backlight and the software dimmer.
public struct RampPolicy: Codable, Equatable, Sendable {
    /// Point on the brightness scale below which the backlight stays at its floor and only the dimmer moves.
    public var dimmingStart: Double
    /// Lowest backlight level ever requested (0...1). Raise it if low PWM levels bother you.
    public var backlightFloor: Double
    /// Lowest dimmer level (0...1). Keeps the screen from going fully black.
    public var dimmerFloor: Double

    public init(dimmingStart: Double = 0.3, backlightFloor: Double = 0, dimmerFloor: Double = 0.15) {
        self.dimmingStart = dimmingStart
        self.backlightFloor = backlightFloor
        self.dimmerFloor = dimmerFloor
    }

    /// For displays without a controllable backlight: the whole scale is software dimming.
    public static func softwareOnly(dimmerFloor: Double = 0.15) -> RampPolicy {
        RampPolicy(dimmingStart: 1, backlightFloor: 1, dimmerFloor: dimmerFloor)
    }

    var normalized: RampPolicy {
        RampPolicy(dimmingStart: dimmingStart.clamped01,
                   backlightFloor: backlightFloor.clamped01,
                   dimmerFloor: dimmerFloor.clamped01)
    }
}

public struct ChannelLevels: Equatable, Sendable {
    public var backlight: Double
    public var dimmer: Double
    public init(backlight: Double, dimmer: Double) {
        self.backlight = backlight
        self.dimmer = dimmer
    }
}

/// One linear piece of the ramp: as brightness moves across `brightness`, each channel moves across its range.
public struct RampSegment: Equatable, Sendable {
    public var brightness: ClosedRange<Double>
    public var backlight: ClosedRange<Double>
    public var dimmer: ClosedRange<Double>
}

/// Ordered, non-overlapping segments covering brightness 0...1.
public struct RampTable: Equatable, Sendable {
    public let segments: [RampSegment]

    public init(policy: RampPolicy) {
        let p = policy.normalized
        var s: [RampSegment] = []
        if p.dimmingStart > 0 {
            // Low end: backlight parked at its floor, dimmer rises to full.
            s.append(RampSegment(brightness: 0...p.dimmingStart,
                                 backlight: p.backlightFloor...p.backlightFloor,
                                 dimmer: min(p.dimmerFloor, 1)...1))
        }
        if p.dimmingStart < 1 {
            // High end: dimmer at full, backlight rises from its floor to max.
            s.append(RampSegment(brightness: p.dimmingStart...1,
                                 backlight: p.backlightFloor...1,
                                 dimmer: 1...1))
        }
        segments = s
    }

    /// Forward mapping: brightness → channel levels.
    public func levels(forBrightness value: Double) -> ChannelLevels {
        let l = value.clamped01
        guard let seg = segments.first(where: { $0.brightness.contains(l) }) ?? segments.last else {
            return ChannelLevels(backlight: 1, dimmer: 1)
        }
        let t = seg.brightness.span > 0 ? (l - seg.brightness.lowerBound) / seg.brightness.span : 1
        return ChannelLevels(backlight: seg.backlight.lerp(t), dimmer: seg.dimmer.lerp(t))
    }

    /// Reverse mapping: observed channel levels → brightness. Used when the backlight is changed elsewhere
    /// (for example with the monitor's own buttons) so the slider can follow it.
    public func brightness(for levels: ChannelLevels) -> Double {
        let eps = 1e-6
        if levels.dimmer < 1 - eps, let seg = segments.first(where: { $0.dimmer.span > eps }) {
            return seg.brightness.lerp(seg.dimmer.fraction(of: levels.dimmer))
        }
        if let seg = segments.first(where: { $0.backlight.span > eps }) {
            return seg.brightness.lerp(seg.backlight.fraction(of: levels.backlight))
        }
        return 1
    }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

extension ClosedRange where Bound == Double {
    var span: Double { upperBound - lowerBound }
    func lerp(_ t: Double) -> Double { lowerBound + span * t.clamped01 }
    func fraction(of value: Double) -> Double { span > 0 ? ((value - lowerBound) / span).clamped01 : 1 }
}
