import Foundation

/// Sunrise and sunset as minutes after local midnight.
public struct SunTimes: Equatable, Sendable {
    public var sunrise: Double
    public var sunset: Double
    public init(sunrise: Double, sunset: Double) {
        self.sunrise = sunrise
        self.sunset = sunset
    }

    /// Used when no location is set, and as the basis for polar day/night.
    public static let fallback = SunTimes(sunrise: 7 * 60, sunset: 19 * 60)
}

public enum SunClock {
    public enum Day: Equatable, Sendable {
        case normal(SunTimes)
        case sunNeverSets
        case sunNeverRises
    }

    /// Sunrise and sunset for the calendar day containing `date` in `timeZone`, using the NOAA
    /// low-precision solar equations (good to a couple of minutes away from the poles).
    public static func day(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> Day {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let daysInYear = Double(cal.range(of: .day, in: .year, for: date)?.count ?? 365)

        let g = 2 * Double.pi / daysInYear * (dayOfYear - 1) // fractional year at local noon
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                               - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
                 + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)

        let lat = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180 // refraction and the sun's radius included
        let cosH = (cos(zenith) - sin(lat) * sin(decl)) / (cos(lat) * cos(decl))
        if cosH > 1 { return .sunNeverRises }
        if cosH < -1 { return .sunNeverSets }
        let hourAngle = acos(cosH) * 180 / .pi

        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let offset = Double(timeZone.secondsFromGMT(for: noon)) / 60
        let rise = 720 - 4 * (longitude + hourAngle) - eqTime + offset
        let set = 720 - 4 * (longitude - hourAngle) - eqTime + offset
        return .normal(SunTimes(sunrise: wrap(rise), sunset: wrap(set)))
    }

    /// Times to schedule against: real ones, or the fallback stretched to all-day / all-night.
    public static func scheduleTimes(_ day: Day) -> SunTimes {
        switch day {
        case .normal(let t): return t
        case .sunNeverSets: return SunTimes(sunrise: 0, sunset: 1439)
        case .sunNeverRises: return SunTimes(sunrise: 720, sunset: 720) // equal times: no daylight
        }
    }
}

/// The brightness plan for a day: three levels and the times between them.
///
/// - Day → Evening follows the sun: the change is centred on sunset (and the reverse on sunrise).
/// - Evening → Night finishes at bedtime; Night → normal finishes at wake-up.
/// Every change is a gradual ramp lasting `transitionMinutes`.
public struct DaySchedule: Codable, Equatable, Sendable {
    public var dayLevel: Double
    public var eveningLevel: Double
    public var nightLevel: Double
    /// Minutes after local midnight.
    public var wakeMinute: Double
    public var bedtimeMinute: Double
    public var transitionMinutes: Double

    public init(dayLevel: Double = 1, eveningLevel: Double = 0.6, nightLevel: Double = 0.3,
                wakeMinute: Double = 7 * 60, bedtimeMinute: Double = 23 * 60, transitionMinutes: Double = 60) {
        self.dayLevel = dayLevel
        self.eveningLevel = eveningLevel
        self.nightLevel = nightLevel
        self.wakeMinute = wakeMinute
        self.bedtimeMinute = bedtimeMinute
        self.transitionMinutes = transitionMinutes
    }

    public enum Phase: String, Sendable { case day = "Day", evening = "Evening", night = "Night" }

    /// How much "daylight" (0...1) and how much "night" (0...1) apply at a minute of the day.
    func weights(atMinute m: Double, sun: SunTimes) -> (daylight: Double, night: Double) {
        let t = max(transitionMinutes, 1)
        let daylight: Double
        if sun.sunrise == sun.sunset {
            daylight = 0 // polar night
        } else if wrap(sun.sunset - sun.sunrise) + t >= 1440 {
            daylight = 1 // day plus its ramps covers the whole clock (sunset may be after midnight)
        } else {
            daylight = Self.plateau(m, from: sun.sunrise - t / 2, to: sun.sunset + t / 2, ramp: t)
        }
        let night = Self.plateau(m, from: bedtimeMinute - t, to: wakeMinute, ramp: t)
        return (daylight, night)
    }

    /// Target lumen (0...1) at a minute of the local day.
    public func level(atMinute m: Double, sun: SunTimes) -> Double {
        let w = weights(atMinute: m, sun: sun)
        let sunLevel = eveningLevel + (dayLevel - eveningLevel) * w.daylight
        return min(max(sunLevel + (nightLevel - sunLevel) * w.night, 0), 1)
    }

    public func phase(atMinute m: Double, sun: SunTimes) -> Phase {
        let w = weights(atMinute: m, sun: sun)
        if w.night >= 0.5 { return .night }
        return w.daylight >= 0.5 ? .day : .evening
    }

    /// Minutes from `m` until the next ramp starts (sunrise, sunset, bedtime or wake-up).
    /// A manual change holds until then.
    public func minutesUntilNextTransition(afterMinute m: Double, sun: SunTimes) -> Double {
        let t = max(transitionMinutes, 1)
        let starts = [sun.sunrise - t / 2, sun.sunset - t / 2, bedtimeMinute - t, wakeMinute - t]
        return starts.map { wrap($0 - m) }.map { $0 < 0.5 ? $0 + 1440 : $0 }.min() ?? 1440
    }

    /// 1 inside the cyclic span [from, to], 0 outside, with smooth ramps of `ramp` minutes at both
    /// ends, inside the span. Ramps shrink if the span is too short for both. A span of a whole day
    /// or more is 1 everywhere.
    static func plateau(_ m: Double, from: Double, to: Double, ramp: Double) -> Double {
        if to - from >= 1440 { return 1 }
        let length = wrap(to - from)
        guard length > 0 else { return 0 }
        let r = min(ramp, length / 2)
        let x = wrap(m - from)
        guard x <= length else { return 0 }
        return min(smooth(x / r), smooth((length - x) / r))
    }

    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

/// Wraps minutes into 0..<1440.
func wrap(_ minutes: Double) -> Double {
    let r = minutes.truncatingRemainder(dividingBy: 1440)
    return r < 0 ? r + 1440 : r
}
