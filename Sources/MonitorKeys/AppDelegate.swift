import AppKit
import ServiceManagement
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
    /// How dark software dimming goes at the bottom of the scale (1 = no dimming). Not 0: the overlay
    /// sits above menus, so a fully black screen would hide the menu needed to undo it.
    var dimmerFloor: Double {
        get { d.object(forKey: "dimmerFloor") as? Double ?? 0.15 }
        nonmutating set { d.set(newValue, forKey: "dimmerFloor") }
    }
    /// Slider response: 1 = linear, `RampPolicy.perceptualCurve` = finer steps at the dark end.
    var curve: Double {
        get { d.object(forKey: "curve") as? Double ?? 1 }
        nonmutating set { d.set(newValue, forKey: "curve") }
    }
    /// Read DDC monitors now and then, so a change made with their buttons (or another app) moves
    /// the slider and holds the schedule, as it does on Apple panels.
    var followMonitorChanges: Bool {
        get { d.object(forKey: "followMonitorChanges") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "followMonitorChanges") }
    }
    var verifiesWrites: Bool {
        get { d.object(forKey: "verifiesWrites") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "verifiesWrites") }
    }
    var policy: RampPolicy {
        RampPolicy(dimmingStart: dimmingStart, backlightFloor: backlightFloor, dimmerFloor: dimmerFloor, curve: curve)
    }
    var tuning: BusTuning {
        var t = BusTuning()
        t.sendsPerValue = sendsPerValue
        t.settleMs = settleMs
        t.verifiesWrites = verifiesWrites
        return t
    }
}

extension NSScreen {
    static func forDisplay(_ id: CGDirectDisplayID) -> NSScreen? {
        screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
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
        NSScreen.forDisplay(id)?.localizedName ?? "Display \(id)"
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
            // A replacement takes over its predecessor's dimming overlay.
            let old = previous[id]
            let c = BlendCoordinator(display: id, name: name(of: id), backlight: backlight, speaker: speaker,
                                     policy: settings.policy, shade: old?.shade)
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
    private let scheduler = DayScheduler()
    private var scheduleWindow: NSWindow?
    private let binary = BinaryWatch()
    private var checkPending = false
    /// The app on disk was deleted, moved, or changed while no tap was running; none is started
    /// again until the app is reopened.
    private var codeChanged = false
    private var safetyPoll: Timer?
    private var monitorPoll: Timer?
    private let monitorPollSeconds: TimeInterval = 30
    /// From sleep until the monitors are sent their levels again after wake: a read in between would
    /// take the level a monitor woke at for a change made on it.
    private var monitorPollPaused = false
    /// Counts sleeps and wakes, so a post-wake step scheduled before the latest one is dropped.
    private var wakeGeneration = 0
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSafetyChecks() // first, so the key tap is never up without them
        clearOldGammaDimmingOnce()
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        // Display sleep while the Mac stays awake puts monitors in standby too.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake),
                                                          name: NSWorkspace.screensDidWakeNotification, object: nil)

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
        if wantsKeyTap { enableKeyTap(prompt: true) }
        updateSafetyPoll()

        scheduler.coordinators = { [unowned self] in coordinators }
        scheduler.start()
        updateMonitorPoll()
    }

    // MARK: following DDC monitors

    /// Following needs the read-back: without it, a write the monitor dropped would look like a
    /// change made on it. Paused around sleep and wake.
    private var monitorPollWanted: Bool {
        settings.followMonitorChanges && settings.verifiesWrites && !monitorPollPaused
    }

    /// Reads each DDC monitor's backlight every 30 s while "Follow changes made on the monitor" is on.
    private func updateMonitorPoll() {
        let wanted = monitorPollWanted
        if wanted, monitorPoll == nil {
            let timer = Timer(timeInterval: monitorPollSeconds, repeats: true) { [unowned self] _ in pollMonitors() }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            monitorPoll = timer
        } else if !wanted {
            monitorPoll?.invalidate()
            monitorPoll = nil
        }
    }

    /// A DDC level that moved away from ours was changed on the monitor or by another app: the
    /// slider follows it and the schedule holds that display, like a change made here.
    private func pollMonitors() {
        guard monitorPollWanted else { return } // a menu click may land between a change and the timer's removal
        for c in coordinators where c.backlight is BusBacklight {
            c.resyncInBackground { [weak self, weak c] moved in
                guard let self, let c, moved else { return }
                log.info("\(c.name, privacy: .public) backlight was changed elsewhere; following it")
                scheduler.userAdjusted(c.display)
            }
        }
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

    // MARK: safety

    /// Keeps the key tap from locking up the Mac's input. If the app on disk is deleted, moved, or
    /// changed while it runs, macOS can no longer verify it and WindowServer drops every key and
    /// click the tap hands back, leaving the user no way to quit it. So a running tap makes the app
    /// quit by itself: right after a change to its executable (file watch) or within a few seconds
    /// (poll, which also catches a moved folder or an edited Info.plist). Without a running tap
    /// nothing is at risk; the app keeps working but starts no tap until it is reopened.
    ///
    /// The same poll keeps the tap in line with Accessibility permission: it is removed when the
    /// permission goes away and started once it is granted.
    private func startSafetyChecks() {
        // A copy over the executable arrives as a burst of write events: check 0.2 s after the first
        // (not after the last, so a slow copy doesn't leave a broken tap up), once per burst.
        binary.watch { [unowned self] in
            guard !checkPending else { return }
            checkPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [unowned self] in
                checkPending = false
                checkSafety()
            }
        }

        // `kill` (as build-app.sh does before replacing the bundle) gets the same cleanup as Quit,
        // run on the main thread like everything else that touches the tap. Received off
        // the main thread, so that if it is stuck the app still goes within 2 s (the tap with it).
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [unowned self] in
            DispatchQueue.main.async { [unowned self] in
                cleanUp()
                exit(0)
            }
            Thread.sleep(forTimeInterval: 2)
            _exit(0)
        }
        term.resume()
        terminationSignal = term
    }

    /// Runs the poll only while there is a tap to guard or wait for.
    private func updateSafetyPoll() {
        let needed = (wantsKeyTap && !codeChanged) || keyTap.isRunning
        if needed, safetyPoll == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [unowned self] _ in checkSafety() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common) // keep checking while a menu is open
            safetyPoll = timer
        } else if !needed {
            safetyPoll?.invalidate()
            safetyPoll = nil
        }
    }

    /// Acts on a change to the app on disk: quits if a tap is running, otherwise keeps the keys off
    /// until the app is reopened. Returns true only while the code is unchanged. Not a plain query.
    private func quitOrDisableKeysIfCodeChanged() -> Bool {
        if !codeChanged, binary.isIntact { return true }
        if keyTap.isRunning {
            log.error("\(self.binary.code.path, privacy: .public) was deleted, moved, or changed; quitting so the key tap can't block input")
            cleanUp()
            exit(0) // at once: NSApp.terminate can be postponed, e.g. by a modal alert
        }
        if !codeChanged {
            log.error("\(self.binary.code.path, privacy: .public) was deleted, moved, or changed; the keyboard keys stay off until MonitorKeys is reopened")
            codeChanged = true
            updateSafetyPoll()
        }
        return false
    }

    private func checkSafety() {
        guard wantsKeyTap || keyTap.isRunning else { return } // no tap, nothing to block input
        guard quitOrDisableKeysIfCodeChanged() else { return }
        let trusted = MediaKeyTap.isTrusted
        if keyTap.isRunning, !trusted {
            log.error("Accessibility permission was lost; removing the key tap until it is granted again")
            keyTap.stop()
        } else if !keyTap.isRunning, trusted, wantsKeyTap {
            keyTap.start()
        }
    }

    /// Up to 0.2.3 the app dimmed through the colour tables. macOS restores a process's tables when
    /// it exits (checked on macOS 26, even on SIGKILL), but in case an older macOS left a crashed
    /// copy's dimming behind, reset them once after upgrading. Not on a fresh install and never
    /// again: the reset also wipes f.lux's tint until f.lux redraws.
    private func clearOldGammaDimmingOnce() {
        let key = "colorTablesReleased"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        let upgrading = !(Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:))?.isEmpty ?? true)
        if upgrading { CGDisplayRestoreColorSyncSettings() }
        defaults.set(true, forKey: key)
    }

    /// What every way of quitting must do before the process exits: no tap left behind. Dimming
    /// needs no undoing: the overlay windows go with the process.
    private func cleanUp() {
        keyTap.stop()
    }

    // MARK: keys

    private var wantsKeyTap: Bool { settings.brightnessKeys || settings.soundKeys }

    /// Starts the tap now if permission is there; otherwise the safety poll starts it once it is granted.
    private func enableKeyTap(prompt: Bool) {
        guard quitOrDisableKeysIfCodeChanged() else { return }
        if MediaKeyTap.isTrusted { keyTap.start() } else if prompt { MediaKeyTap.promptForTrust() }
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
            keyTap.stop()
        }
        updateSafetyPoll()
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
        cleanUp()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A slider in the menu's first item draws without the filled part of its track (macOS 26),
        // so the sliders start below a thin empty item.
        let top = NSMenuItem()
        top.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 4))
        menu.addItem(top)
        for c in coordinators {
            if c.backlight is BuiltInBacklight { c.resync() }
            let item = NSMenuItem()
            let detail = c.backlight?.kind ?? "software dimming only"
            let row = SliderRow(title: "\(c.name) — \(detail)", value: c.brightness) { [weak self, weak c] v in
                guard let c else { return }
                c.set(brightness: v)
                self?.scheduler.userAdjusted(c.display)
            }
            item.view = row
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
        scheduler.refreshNow() // expired holds go, and the phase named below is the current one
        if scheduler.enabled, let until = scheduler.held.values.max() {
            let time = until.formatted(date: .omitted, time: .shortened)
            menu.addItem(ClosureMenuItem(title: "Resume schedule (holding your setting until \(time))") { [unowned self] in
                scheduler.resume()
            })
            let held = coordinators.filter { scheduler.held[$0.display] != nil }
            for c in held {
                guard let a = scheduler.adoption(c.display) else { continue }
                let percent = Int((c.brightness * 100).rounded())
                let level = Int((a.level * 100).rounded())
                let whose = held.count > 1 ? "\(c.name)'s " : ""
                // During a ramp the phase level that keeps the schedule at this brightness differs from it.
                let title = level == percent
                    ? "Use \(whose)\(percent)% as the \(a.phase.rawValue) level"
                    : "Keep \(whose)\(percent)% in the schedule (\(a.phase.rawValue) level \(level)%)"
                menu.addItem(ClosureMenuItem(title: title) { [unowned self] in scheduler.adopt(c.display, phase: a.phase) })
            }
        }
        menu.addItem(ClosureMenuItem(title: "Day Schedule…") { [unowned self] in showScheduleWindow() })
        menu.addItem(.separator())
        // Tuning for unusual monitors; the defaults suit most setups, so it stays out of the way.
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let tuning = NSMenu()
        tuning.autoenablesItems = false // so isEnabled below sticks
        tuning.addItem(choices("Software dimming below", [("Off", 0.0), ("20%", 0.2), ("30%", 0.3), ("40%", 0.4), ("50%", 0.5)],
                               current: settings.dimmingStart) { [unowned self] v in settings.dimmingStart = v; updatePolicy() })
        tuning.addItem(choices("Slider response", [("Linear", 1.0), ("Finer at the dark end", RampPolicy.perceptualCurve)],
                               current: settings.curve) { [unowned self] v in settings.curve = v; updatePolicy() })
        tuning.addItem(choices("Darkest software dimming", [("15%", 0.15), ("10%", 0.1), ("5%", 0.05)],
                               current: settings.dimmerFloor) { [unowned self] v in settings.dimmerFloor = v; updatePolicy() })
        tuning.addItem(choices("Backlight floor", [("0%", 0.0), ("10%", 0.1), ("20%", 0.2), ("30%", 0.3)],
                               current: settings.backlightFloor) { [unowned self] v in settings.backlightFloor = v; updatePolicy() })
        tuning.addItem(choices("DDC sends per change", [("Once", 1), ("Twice", 2)],
                               current: settings.sendsPerValue) { [unowned self] v in settings.sendsPerValue = v; updateTuning() })
        tuning.addItem(choices("DDC settle time", [("20 ms", 20), ("50 ms", 50), ("100 ms", 100)],
                               current: settings.settleMs) { [unowned self] v in settings.settleMs = v; updateTuning() })
        tuning.addItem(.separator())
        let verify = ClosureMenuItem(title: "Check that DDC changes took") { [unowned self] in
            settings.verifiesWrites.toggle(); updateTuning(); updateMonitorPoll()
        }
        verify.state = settings.verifiesWrites ? .on : .off
        tuning.addItem(verify)
        let followMonitor = ClosureMenuItem(title: "Follow changes made on the monitor") { [unowned self] in
            settings.followMonitorChanges.toggle(); updateMonitorPoll()
        }
        followMonitor.state = settings.followMonitorChanges && settings.verifiesWrites ? .on : .off
        followMonitor.isEnabled = settings.verifiesWrites // needs the read-back to tell a dropped write apart
        tuning.addItem(followMonitor)
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
            let title = codeChanged ? "MonitorKeys was moved or changed: reopen it to use the keys"
                                    : "Waiting for Accessibility permission…"
            let note = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        let login = ClosureMenuItem(title: "Open at Login") { [unowned self] in toggleOpenAtLogin() }
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(ClosureMenuItem(title: "Re-read hardware levels") { [unowned self] in
            refreshDisplays(reprobe: true)
            coordinators.forEach { $0.resync(); $0.speaker?.resync() }
        })
        menu.addItem(advanced)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit MonitorKeys") { NSApp.terminate(nil) })
    }

    /// The login item is the app bundle itself, registered with macOS; the system keeps the on/off state.
    private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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
        scheduler.tick()
    }

    /// Mac or display sleep: no reads until the monitors have been sent their levels after waking.
    @objc private func willSleep() {
        pauseMonitorPoll()
    }

    /// Stops the poll, drops reads in flight (they may finish after wake with its level), and
    /// cancels a pending post-wake step.
    private func pauseMonitorPoll() {
        wakeGeneration += 1
        monitorPollPaused = true
        updateMonitorPoll()
        coordinators.forEach { $0.dropReadsInProgress() }
    }

    @objc private func didWake() {
        refreshDisplays(reprobe: true) // a monitor that was in standby may answer DDC now
        scheduler.tick()
        afterMonitorsWake()
    }

    @objc private func screensDidWake() {
        afterMonitorsWake()
    }

    /// Monitors can take a few seconds to listen again, and some wake at a level of their own.
    /// Reading them before that level is replaced would follow it as a change made on the monitor.
    private func afterMonitorsWake() {
        pauseMonitorPoll() // also when no sleep notification came first
        let generation = wakeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, generation == wakeGeneration else { return } // slept or woke again since
            coordinators.forEach { $0.reassert() }
            monitorPollPaused = false
            updateMonitorPoll()
        }
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
