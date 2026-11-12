import AppKit
import CoreLocation
import MapKit
import Observation
import MonitorKeysCore

struct Place: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

/// Moves each display along the day schedule. A manual change (slider, keys) on a display holds
/// that display where you put it until the next ramp starts (sunrise, sunset, bedtime, wake-up).
@Observable
final class DayScheduler {
    var enabled: Bool { didSet { save(); held.removeAll(); scheduled.removeAll(); tick(immediate: true) } }
    var plan: DaySchedule { didSet { save(); held.removeAll(); scheduled.removeAll(); tick(immediate: true) } }
    var place: Place? { didSet { save(); tick(immediate: true) } }
    var includeBuiltIn: Bool { didSet { save(); tick(immediate: true) } }
    /// Displays a manual change is holding, and until when.
    private(set) var held: [CGDirectDisplayID: Date] = [:]
    /// Refreshed every tick so views showing "now" stay current.
    private(set) var now = Date()

    @ObservationIgnored var coordinators: () -> [BlendCoordinator] = { [] }
    @ObservationIgnored private var timer: Timer?
    /// The brightness each display was last moved to by the schedule, to notice changes made elsewhere.
    @ObservationIgnored private var scheduled: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Largest brightness change per tick when following the schedule, so resuming after a hold or
    /// waking from sleep glides instead of jumping.
    private let maxStep = 0.05
    private let tickSeconds: TimeInterval = 30

    init() {
        enabled = defaults.bool(forKey: "schedule.enabled")
        includeBuiltIn = defaults.bool(forKey: "schedule.includeBuiltIn")
        plan = Self.decode(DaySchedule.self, defaults.data(forKey: "schedule.plan")) ?? DaySchedule()
        place = Self.decode(Place.self, defaults.data(forKey: "schedule.place"))
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickSeconds, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: schedule

    var sun: SunTimes { sun(on: now) }

    func sun(on date: Date) -> SunTimes {
        guard let place else { return .fallback }
        return SunClock.scheduleTimes(SunClock.day(on: date, latitude: place.latitude,
                                                   longitude: place.longitude, timeZone: .current))
    }

    var sunDay: SunClock.Day? {
        place.map { SunClock.day(on: now, latitude: $0.latitude, longitude: $0.longitude, timeZone: .current) }
    }

    static func minuteOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
    }

    var targetNow: Double { plan.level(atMinute: Self.minuteOfDay(now), sun: sun) }
    var phaseNow: DaySchedule.Phase { plan.phase(atMinute: Self.minuteOfDay(now), sun: sun) }

    // MARK: driving displays

    func follows(_ c: BlendCoordinator) -> Bool {
        includeBuiltIn || CGDisplayIsBuiltin(c.display) == 0
    }

    /// Call after the user changed a display's brightness by hand.
    func userAdjusted(_ display: CGDirectDisplayID) {
        guard enabled else { return }
        let date = Date()
        let minutes = plan.minutesUntilNextTransition(afterMinute: Self.minuteOfDay(date), sun: sun(on: date))
        held[display] = date.addingTimeInterval(minutes * 60)
        scheduled[display] = nil
    }

    /// Ends the hold on one display, or on all of them.
    func resume(_ display: CGDirectDisplayID? = nil) {
        if let display { held[display] = nil } else { held.removeAll() }
        tick()
    }

    /// Moves every following display toward the schedule; `immediate` skips the glide.
    func tick(immediate: Bool = false) {
        now = Date()
        held = held.filter { $0.value > now }
        guard enabled else { return }
        let target = targetNow
        for c in coordinators() where follows(c) {
            // Apple panels can also be changed by macOS itself (its brightness keys, Control Centre).
            // Reading them is cheap; a level that moved away from ours counts as a manual change.
            if c.backlight is BuiltInBacklight, held[c.display] == nil, scheduled[c.display] != nil, c.resync() {
                userAdjusted(c.display)
            }
            guard held[c.display] == nil else { continue }
            let delta = target - c.brightness
            if abs(delta) > 0.002 {
                c.set(brightness: immediate ? target : c.brightness + min(max(delta, -maxStep), maxStep))
            }
            scheduled[c.display] = c.brightness
        }
    }

    // MARK: persistence

    private func save() {
        defaults.set(enabled, forKey: "schedule.enabled")
        defaults.set(includeBuiltIn, forKey: "schedule.includeBuiltIn")
        defaults.set(try? JSONEncoder().encode(plan), forKey: "schedule.plan")
        if let place { defaults.set(try? JSONEncoder().encode(place), forKey: "schedule.place") }
        else { defaults.removeObject(forKey: "schedule.place") }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

// MARK: finding a location

enum PlaceLookup {
    /// Looks a city up by name with Apple's map search.
    static func search(_ query: String) async throws -> Place? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26, *) { coordinate = item.location.coordinate }
        else { coordinate = item.placemark.coordinate }
        return Place(name: item.name ?? query, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// One-shot "where am I" via Location Services.
final class CurrentLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocationCoordinate2D?) -> Void)?

    func request(_ done: @escaping (CLLocationCoordinate2D?) -> Void) {
        completion = done
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location lookup failed: \(error.localizedDescription, privacy: .public)")
        finish(nil)
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        let done = completion
        completion = nil
        done?(coordinate)
    }
}
