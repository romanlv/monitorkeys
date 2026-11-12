import AppKit
import MonitorKeysCore

/// `MonitorKeys --probe` lists displays and their channels and reads current levels. It writes nothing
/// unless `--ddc-set <raw>` (luminance) or `--volume-set <raw>` (speaker volume) is also given,
/// which writes that raw value to external monitors.
func argument(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

if CommandLine.arguments.contains("--probe") {
    let ids = DisplayInventory.online()
    let endpoints = BusLocator.externalEndpoints()
    let assigned = BusLocator.assign(ids.filter { CGDisplayIsBuiltin($0) == 0 }, endpoints)
    print("online displays: \(ids.count), external DDC endpoints: \(endpoints.count)")
    for id in ids {
        let builtIn = CGDisplayIsBuiltin(id) != 0
        print("- \(DisplayInventory.name(of: id)) id=\(id) builtin=\(builtIn) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))")
        if let b = BuiltInBacklight(display: id) {
            print("    built-in backlight: \(b.read().map { String(format: "%.3f", $0) } ?? "unreadable")")
        } else if !builtIn, let ep = assigned[id] {
            var tuning = BusTuning()
            if let ms = ProcessInfo.processInfo.environment["MONITORKEYS_REPLY_MS"].flatMap(Int.init) { tuning.replyWaitMs = ms }
            if let ms = ProcessInfo.processInfo.environment["MONITORKEYS_SETTLE_MS"].flatMap(Int.init) { tuning.settleMs = ms }
            if let n = ProcessInfo.processInfo.environment["MONITORKEYS_READ_SENDS"].flatMap(Int.init) { tuning.readRequestSends = n }
            if let n = ProcessInfo.processInfo.environment["MONITORKEYS_SENDS"].flatMap(Int.init) { tuning.sendsPerValue = n }
            let link = BusLink(endpoint: ep, tuning: tuning)
            if let bus = BusBacklight(link: link) {
                print("    DDC luminance: max=\(bus.maximum) level=\(bus.read().map { String(format: "%.3f", $0) } ?? "unreadable")")
                if let raw = argument("--ddc-set").flatMap(UInt16.init) {
                    print("    write \(raw): \(link.writeNow(MCCS.Code.luminance, min(raw, bus.maximum)) ? "accepted" : "failed")")
                    usleep(100_000)
                    print("    read back: \(bus.read().map { String(format: "%.3f", $0) } ?? "unreadable")")
                }
            } else {
                print("    DDC endpoint found but luminance read failed → software dimming only")
            }
            if let speaker = BusSpeaker(link: link) {
                print("    DDC speaker: max=\(speaker.maximum) volume=\(String(format: "%.3f", speaker.volume))"
                      + " mute control=\(speaker.model.hasMuteControl) muted=\(speaker.muted)")
                if let raw = argument("--volume-set").flatMap(UInt16.init) {
                    print("    write volume \(raw): \(link.writeNow(MCCS.Code.speakerVolume, min(raw, speaker.maximum)) ? "accepted" : "failed")")
                    usleep(100_000)
                    speaker.resync()
                    print("    read back: \(String(format: "%.3f", speaker.volume))")
                }
            } else {
                print("    no DDC speaker volume")
            }
        } else {
            print("    no backlight channel → software dimming only")
        }
    }
    exit(0)
}

/// Brings settings over from the app's previous name (bundle id dev.ourapp.lumen), once.
func migrateSettingsFromOldName() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: "migratedFromOldName") else { return }
    for (key, value) in UserDefaults.standard.persistentDomain(forName: "dev.ourapp.lumen") ?? [:]
    where d.object(forKey: key) == nil {
        d.set(value, forKey: key)
    }
    d.set(true, forKey: "migratedFromOldName")
}

migrateSettingsFromOldName()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
