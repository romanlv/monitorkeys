import SwiftUI
import MonitorKeysCore

/// The "Day schedule" window: three levels, two times, a location, and the resulting curve.
struct ScheduleView: View {
    @Bindable var scheduler: DayScheduler
    var displayName: (CGDirectDisplayID) -> String

    @State private var query = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var locator = CurrentLocation()

    var body: some View {
        Form {
            Section {
                Toggle("Adjust brightness through the day", isOn: $scheduler.enabled)
                DayCurve(scheduler: scheduler)
                    .frame(height: 110)
                    .opacity(scheduler.enabled ? 1 : 0.45)
                Text(status).font(.callout).foregroundStyle(.secondary)
                ForEach(heldDisplays, id: \.0) { display, until in
                    HStack {
                        Text("\(displayName(display)) is held at your setting until \(until.formatted(date: .omitted, time: .shortened)).")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        // Computed from the same moment as the label, so it changes the phase it names.
                        let adoption = scheduler.adoption(display)
                        let phase = adoption?.phase ?? scheduler.phaseNow
                        Button("Use for \(phase.rawValue)") { scheduler.adopt(display, phase: phase) }
                            .help("Make this display's brightness the \(phase.rawValue) level")
                            .disabled(adoption == nil)
                        Button("Resume") { scheduler.resume(display) }
                    }
                }
            }

            Section("Levels") {
                level("Day", $scheduler.plan.dayLevel)
                level("Evening", $scheduler.plan.eveningLevel)
                level("Night", $scheduler.plan.nightLevel)
            }

            Section {
                DatePicker("Wake up", selection: time(\.wakeMinute), displayedComponents: .hourAndMinute)
                DatePicker("Bedtime", selection: time(\.bedtimeMinute), displayedComponents: .hourAndMinute)
                Picker("Changes take", selection: $scheduler.plan.transitionMinutes) {
                    ForEach([15.0, 30, 60, 90, 120], id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
            } header: {
                Text("Times")
            } footer: {
                Text("Day turns to Evening around sunset and back around sunrise. Night is fully reached at bedtime and is over by the time you wake up.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("City", text: $query, prompt: Text("City, e.g. Toronto"))
                        .labelsHidden()
                        .onSubmit(search)
                    Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    Button(action: locate) { Image(systemName: "location") }
                        .help("Use this Mac's location").disabled(busy)
                }
                Text(problem ?? placeText).font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
            } header: {
                Text("Location (for sunrise and sunset)")
            }

            Section {
                Toggle("Also adjust the built-in display", isOn: $scheduler.includeBuiltIn)
            } footer: {
                Text("Leave this off if the built-in display uses macOS automatic brightness. Moving a slider or pressing the brightness keys holds that display until the next change in the schedule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: pieces

    private func level(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func time(_ keyPath: WritableKeyPath<DaySchedule, Double>) -> Binding<Date> {
        Binding {
            Self.today(atMinute: scheduler.plan[keyPath: keyPath])
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            scheduler.plan[keyPath: keyPath] = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        }
    }

    private var heldDisplays: [(CGDirectDisplayID, Date)] {
        scheduler.enabled ? scheduler.held.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } : []
    }

    private var status: String {
        let sun = scheduler.sun
        var sunText: String
        switch scheduler.sunDay {
        case .sunNeverSets?: sunText = "The sun doesn't set today."
        case .sunNeverRises?: sunText = "The sun doesn't rise today."
        default: sunText = "Sunrise \(clock(sun.sunrise)), sunset \(clock(sun.sunset))."
        }
        if scheduler.place == nil { sunText += " (Default times. Set a location for real ones.)" }
        let level = Int((scheduler.targetNow * 100).rounded())
        return "Now: \(scheduler.phaseNow.rawValue), \(level)%. \(sunText)"
    }

    private var placeText: String {
        guard let p = scheduler.place else { return "Not set." }
        return "\(p.name): \(String(format: "%.2f", p.latitude)), \(String(format: "%.2f", p.longitude))"
    }

    private func clock(_ minutes: Double) -> String {
        Self.today(atMinute: minutes).formatted(date: .omitted, time: .shortened)
    }

    /// Today's wall-clock time for a minute of the day (correct on daylight-saving change days too).
    static func today(atMinute minutes: Double) -> Date {
        let m = Int(minutes.rounded()) % 1440
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if let place = try await PlaceLookup.search(q) { scheduler.place = place; query = "" }
                else { problem = "No place found for “\(q)”." }
            } catch {
                problem = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private func locate() {
        busy = true
        problem = nil
        locator.request { coordinate in
            DispatchQueue.main.async {
                busy = false
                guard let coordinate else {
                    problem = "Location unavailable. Allow MonitorKeys in System Settings → Privacy & Security → Location Services, or search for a city."
                    return
                }
                scheduler.place = Place(name: "Current location", latitude: coordinate.latitude,
                                        longitude: coordinate.longitude)
            }
        }
    }
}

/// 24-hour preview of the schedule with sunrise/sunset marks and a dot for now.
private struct DayCurve: View {
    var scheduler: DayScheduler

    var body: some View {
        let plan = scheduler.plan
        let sun = scheduler.sun
        let nowMinute = DayScheduler.minuteOfDay(scheduler.now)
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let x = { (m: Double) in m / 1440 * w }
                let y = { (l: Double) in h - l * (h - 6) - 3 }
                let samples = stride(from: 0.0, through: 1440, by: 5).map { ($0, plan.level(atMinute: $0, sun: sun)) }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for (m, l) in samples { p.addLine(to: CGPoint(x: x(m), y: y(l))) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Color.yellow.opacity(0.45), Color.orange.opacity(0.15)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        for (i, (m, l)) in samples.enumerated() {
                            let pt = CGPoint(x: x(m), y: y(l))
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                    }
                    .stroke(Color.orange, lineWidth: 1.5)
                    ForEach([sun.sunrise, sun.sunset], id: \.self) { m in
                        Path { p in
                            p.move(to: CGPoint(x: x(m), y: 0))
                            p.addLine(to: CGPoint(x: x(m), y: h))
                        }
                        .stroke(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    Circle().fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .position(x: x(nowMinute), y: y(plan.level(atMinute: nowMinute, sun: sun)))
                }
            }
            HStack {
                ForEach(["0:00", "6:00", "12:00", "18:00", "24:00"], id: \.self) { label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    if label != "24:00" { Spacer() }
                }
            }
        }
    }
}
