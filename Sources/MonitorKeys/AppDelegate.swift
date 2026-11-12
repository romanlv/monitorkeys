import AppKit
import SwiftUI
import MonitorKeysCore

/// Persisted user settings.
struct Settings {
    private let d = UserDefaults.standard
    var dimmingStart: Double {
        get { d.object(forKey: "dimmingStart") as? Double ?? 0.3 }
        nonmutating set { d.set(newValue, forKey: "dimmingStart") }
    }
    var backlightFloor: Double {
        get { d.object(forKey: "backlightFloor") as? Double ?? 0 }
        nonmutating set { d.set(newValue, forKey: "backlightFloor") }
    }
    var sendsPerValue: Int {
        get { d.object(forKey: "sendsPerValue") as? Int ?? 2 }
        nonmutating set { d.set(newValue, forKey: "sendsPerValue") }
    }
    var settleMs: Int {
        get { d.object(forKey: "settleMs") as? Int ?? 20 }
        nonmutating set { d.set(newValue, forKey: "settleMs") }
    }
    var brightnessKeys: Bool {
        get { d.object(forKey: "brightnessKeys") as? Bool ?? false }
        nonmutating set { d.set(newValue, forKey: "brightnessKeys") }
    }
    var soundKeys: Bool {
        get { d.object(forKey: "soundKeys") as? Bool ?? false }
        nonmutating set { d.set(newValue, forKey: "soundKeys") }
    }
    var keyTarget: KeyTargetMode {
        get { d.string(forKey: "keyTarget").flatMap(KeyTargetMode.init(rawValue:)) ?? .pointer }
        nonmutating set { d.set(newValue.rawValue, forKey: "keyTarget") }
    }
    var policy: RampPolicy { RampPolicy(dimmingStart: dimmingStart, backlightFloor: backlightFloor, dimmerFloor: 0.15) }
    var tuning: BusTuning {
        var t = BusTuning()
        t.sendsPerValue = sendsPerValue
        t.settleMs = settleMs
        return t
    }
}

enum DisplayInventory {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "Display \(id)"
    }

    /// One coordinator per online display, each with the best backlight channel available.
    ///
    /// Coordinators in `keeping` whose display is still online are reused as they are, so a working
    /// DDC channel is not re-created (and not raced) on every hot-plug. External displays that ended
    /// up with software dimming only are probed again (the monitor may have been in standby), and
    /// the replacement continues at the same brightness.
    static func coordinators(settings: Settings, keeping: [BlendCoordinator] = [],
                             reprobe: Bool = false) -> [BlendCoordinator] {
        let ids = online()
        let reusable = keeping.filter { ids.contains($0.display) && !(reprobe && $0.needsProbe) }
        let kept = Dictionary(uniqueKeysWithValues: reusable.map { ($0.display, $0) })
        let previous = Dictionary(uniqueKeysWithValues: keeping.map { ($0.display, $0) })
        let needed = ids.filter { kept[$0] == nil }

        // Buses already driven by a kept channel are off the table for the new ones.
        let inUse = Set(reusable.compactMap(\.busID))
        let neededExternal = needed.filter { CGDisplayIsBuiltin($0) == 0 }
        let assigned = neededExternal.isEmpty ? [:] : BusLocator.assign(
            neededExternal, BusLocator.externalEndpoints().filter { !inUse.contains($0.registryID) })

        return ids.map { id in
            if let c = kept[id] { return c }
            var backlight: BacklightChannel? = BuiltInBacklight(display: id)
            var speaker: BusSpeaker?
            if backlight == nil, CGDisplayIsBuiltin(id) == 0, let ep = assigned[id] {
                let link = BusLink(endpoint: ep, tuning: settings.tuning)
                backlight = BusBacklight(link: link)
                speaker = BusSpeaker(link: link)
            }
            // A replacement takes over the gamma its predecessor left on the display.
            let old = previous[id]
            let c = BlendCoordinator(display: id, name: name(of: id), backlight: backlight, speaker: speaker,
                                     policy: settings.policy, dimmer: old?.dimmerLevel ?? 1)
            if let old { c.set(brightness: old.brightness) }
            return c
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private var statusItem: NSStatusItem!
    private var coordinators: [BlendCoordinator] = []
    private let keyTap = MediaKeyTap()
    private let hud = LevelHUD()
    private var trustPoll: Timer?
    private let scheduler = DayScheduler()
    private var scheduleWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GammaDimmer.resetAll()
        coordinators = DisplayInventory.coordinators(settings: settings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        // Keys act on an external display (active window's or pointer's); the built-in panel stays with macOS.
        keyTap.mode = settings.keyTarget
        keyTap.target = { [unowned self] id in
            CGDisplayIsBuiltin(id) == 0 ? coordinators.first { $0.display == id } : nil
        }
        keyTap.onChange = { [unowned self] c in
            scheduler.userAdjusted(c.display)
            hud.show(level: c.brightness, on: c.display)
        }
        // Sound keys act on monitor speakers only while the Mac plays through them and macOS can't set their volume.
        keyTap.speakerTarget = { [unowned self] in speakerForCurrentOutput() }
        keyTap.onSpeakerChange = { [unowned self] c in
            guard let s = c.speaker else { return }
            hud.show(level: s.audibleVolume, on: c.display,
                     symbol: s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        keyTap.brightnessKeys = settings.brightnessKeys
        keyTap.soundKeys = settings.soundKeys
        if settings.brightnessKeys || settings.soundKeys { enableKeyTap(prompt: true) }

        scheduler.coordinators = { [unowned self] in coordinators }
        scheduler.start()
    }

    // MARK: day schedule

    private func showScheduleWindow() {
        if scheduleWindow == nil {
            let view = ScheduleView(scheduler: scheduler) { DisplayInventory.name(of: $0) }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Day Schedule"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            scheduleWindow = window
        }
        NSApp.activate()
        scheduleWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: keys

    private var wantsKeyTap: Bool { settings.brightnessKeys || settings.soundKeys }

    private func enableKeyTap(prompt: Bool) {
        if MediaKeyTap.isTrusted, keyTap.start() { return }
        if prompt, !MediaKeyTap.isTrusted { MediaKeyTap.promptForTrust() }
        // Permission is granted in System Settings while we keep running; start as soon as it lands
        // (and keep retrying if the tap still cannot be created).
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.wantsKeyTap else { timer.invalidate(); self.trustPoll = nil; return }
            guard MediaKeyTap.isTrusted, self.keyTap.start() else { return }
            timer.invalidate()
            self.trustPoll = nil
        }
    }

    private func setBrightnessKeys(_ mode: KeyTargetMode?) {
        if let mode {
            settings.keyTarget = mode
            keyTap.mode = mode
        }
        updateKeyTap { settings.brightnessKeys = mode != nil }
    }

    private func setSoundKeys(_ on: Bool) {
        updateKeyTap { settings.soundKeys = on }
    }

    /// Applies a settings change, then starts the tap if a feature now needs it, or stops it if none does.
    private func updateKeyTap(_ change: () -> Void) {
        let wasWanted = wantsKeyTap
        change()
        keyTap.brightnessKeys = settings.brightnessKeys
        keyTap.soundKeys = settings.soundKeys
        if wasWanted == wantsKeyTap { return }
        if wantsKeyTap {
            enableKeyTap(prompt: true)
        } else {
            trustPoll?.invalidate()
            trustPoll = nil
            keyTap.stop()
        }
    }

    /// The display whose speakers the sound keys should drive right now, if any.
    private func speakerForCurrentOutput() -> BlendCoordinator? {
        guard let output = AudioOutput.current() else { return nil }
        let candidates = coordinators.filter { $0.speaker != nil }
        return SpeakerRouting.pick(outputName: output.name, viaDisplayCable: output.viaDisplayCable,
                                   hasSystemVolume: output.hasSystemVolume,
                                   monitors: candidates.map(\.name)).map { candidates[$0] }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GammaDimmer.resetAll() // never leave a display dimmed by a process that is gone
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for c in coordinators {
            if c.backlight is BuiltInBacklight { c.resync() }
            let item = NSMenuItem()
            let detail = c.backlight?.kind ?? "software dimming only"
            item.view = SliderRow(title: "\(c.name) — \(detail)", value: c.brightness) { [weak self, weak c] v in
                guard let c else { return }
                c.set(brightness: v)
                self?.scheduler.userAdjusted(c.display)
            }
            menu.addItem(item)
        }
        for c in coordinators {
            guard let speaker = c.speaker else { continue }
            let item = NSMenuItem()
            item.view = SliderRow(title: "\(c.name) — speaker volume", value: speaker.volume) { [weak speaker] v in
                speaker?.setVolume(v)
            }
            menu.addItem(item)
            let mute = ClosureMenuItem(title: "Mute \(c.name)") { [weak speaker] in speaker?.toggleMute() }
            mute.state = speaker.muted ? .on : .off
            menu.addItem(mute)
        }
        menu.addItem(.separator())
        let follow = ClosureMenuItem(title: "Adjust brightness through the day") { [unowned self] in scheduler.enabled.toggle() }
        follow.state = scheduler.enabled ? .on : .off
        menu.addItem(follow)
        if scheduler.enabled, let until = scheduler.held.values.max() {
            let time = until.formatted(date: .omitted, time: .shortened)
            menu.addItem(ClosureMenuItem(title: "Resume schedule (holding your setting until \(time))") { [unowned self] in
                scheduler.resume()
            })
        }
        menu.addItem(ClosureMenuItem(title: "Day Schedule…") { [unowned self] in showScheduleWindow() })
        menu.addItem(.separator())
        // Tuning for unusual monitors; the defaults suit most setups, so it stays out of the way.
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let tuning = NSMenu()
        tuning.addItem(choices("Software dimming below", [("Off", 0.0), ("20%", 0.2), ("30%", 0.3), ("40%", 0.4), ("50%", 0.5)],
                               current: settings.dimmingStart) { [unowned self] v in settings.dimmingStart = v; updatePolicy() })
        tuning.addItem(choices("Backlight floor", [("0%", 0.0), ("10%", 0.1), ("20%", 0.2), ("30%", 0.3)],
                               current: settings.backlightFloor) { [unowned self] v in settings.backlightFloor = v; updatePolicy() })
        tuning.addItem(choices("DDC sends per change", [("Once", 1), ("Twice", 2)],
                               current: settings.sendsPerValue) { [unowned self] v in settings.sendsPerValue = v; updateTuning() })
        tuning.addItem(choices("DDC settle time", [("20 ms", 20), ("50 ms", 50), ("100 ms", 100)],
                               current: settings.settleMs) { [unowned self] v in settings.settleMs = v; updateTuning() })
        advanced.submenu = tuning
        let current: KeyTargetMode? = settings.brightnessKeys ? settings.keyTarget : nil
        menu.addItem(choices("Brightness keys control external display",
                             [("Off", nil)] + KeyTargetMode.allCases.map { ($0.title, Optional($0)) },
                             current: current) { [unowned self] mode in setBrightnessKeys(mode) })
        let sound = ClosureMenuItem(title: "Sound keys control monitor speakers") { [unowned self] in
            setSoundKeys(!settings.soundKeys)
        }
        sound.state = settings.soundKeys ? .on : .off
        menu.addItem(sound)
        if wantsKeyTap && !keyTap.isRunning {
            let note = NSMenuItem(title: "Waiting for Accessibility permission…", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(ClosureMenuItem(title: "Re-read hardware levels") { [unowned self] in
            refreshDisplays(reprobe: true)
            coordinators.forEach { $0.resync(); $0.speaker?.resync() }
        })
        menu.addItem(advanced)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit MonitorKeys") { NSApp.terminate(nil) })
    }

    private func choices<T: Equatable>(_ title: String, _ options: [(String, T)], current: T,
                                       onPick: @escaping (T) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let item = ClosureMenuItem(title: label) { onPick(value) }
            item.state = value == current ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func updatePolicy() { coordinators.forEach { $0.policy = settings.policy } }
    private func updateTuning() {
        // A monitor's backlight and speaker share one link.
        coordinators.compactMap { ($0.backlight as? BusBacklight)?.link ?? $0.speaker?.link }
            .forEach { $0.tuning = settings.tuning }
    }

    /// Adds coordinators for new displays, drops those for removed ones, and keeps the rest as they
    /// are. With `reprobe` (wake, "Re-read hardware levels"), external displays without a DDC channel
    /// are probed again; that costs a registry walk and DDC reads, so it is not done on every
    /// screen-parameter change.
    private func refreshDisplays(reprobe: Bool = false) {
        let changed = Set(DisplayInventory.online()) != Set(coordinators.map(\.display))
        if changed || (reprobe && coordinators.contains(where: \.needsProbe)) {
            coordinators = DisplayInventory.coordinators(settings: settings, keeping: coordinators, reprobe: reprobe)
        }
    }

    @objc private func screensChanged() {
        refreshDisplays()
        // Reconfiguration can reset gamma ramps; put back any dimming we had.
        coordinators.forEach { $0.reassertDimmer() }
        scheduler.tick()
    }

    @objc private func didWake() {
        refreshDisplays(reprobe: true) // a monitor that was in standby may answer DDC now
        coordinators.forEach { $0.reassertDimmer() }
        scheduler.tick()
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func fire() { handler() }
}

/// A label above a continuous slider, for use inside a menu.
final class SliderRow: NSView {
    private let onChange: (Double) -> Void

    init(title: String, value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 18, y: 28, width: 270, height: 16)
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: #selector(moved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 270, height: 22)
        addSubview(label)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    @objc private func moved(_ sender: NSSlider) { onChange(sender.doubleValue) }
}
