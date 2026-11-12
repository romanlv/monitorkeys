import AppKit
import LumenCore

/// `Lumen --probe` lists displays and their channels and reads current levels. It writes nothing
/// unless `--ddc-set <raw>` is also given, which writes that luminance to external monitors.
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
            if let ms = ProcessInfo.processInfo.environment["LUMEN_REPLY_MS"].flatMap(Int.init) { tuning.replyWaitMs = ms }
            if let ms = ProcessInfo.processInfo.environment["LUMEN_SETTLE_MS"].flatMap(Int.init) { tuning.settleMs = ms }
            if let n = ProcessInfo.processInfo.environment["LUMEN_READ_SENDS"].flatMap(Int.init) { tuning.readRequestSends = n }
            if let bus = BusBacklight(endpoint: ep, tuning: tuning) {
                print("    DDC luminance: max=\(bus.maximum) level=\(bus.read().map { String(format: "%.3f", $0) } ?? "unreadable")")
                if let i = CommandLine.arguments.firstIndex(of: "--ddc-set"), i + 1 < CommandLine.arguments.count,
                   let raw = UInt16(CommandLine.arguments[i + 1]) {
                    print("    write \(raw): \(bus.writeRawNow(min(raw, bus.maximum)) ? "accepted" : "failed")")
                    usleep(100_000)
                    print("    read back: \(bus.read().map { String(format: "%.3f", $0) } ?? "unreadable")")
                }
            } else {
                print("    DDC endpoint found but luminance read failed → software dimming only")
            }
        } else {
            print("    no backlight channel → software dimming only")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
