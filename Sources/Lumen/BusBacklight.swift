import CoreGraphics
import Foundation
import IOKit
import LumenCore

/// Timing knobs for the display bus. Monitors differ a lot; these are user-tunable.
struct BusTuning: Equatable {
    /// Pause before every bus transaction.
    var settleMs: Int = 20
    /// How many times one value is sent. 1 is the polite default; some monitors need 2.
    var sendsPerValue: Int = 1
    /// Extra attempts after a failed send.
    var retries: Int = 2
    /// Pause after a failed send.
    var backoffMs: Int = 30
    /// How many times a read request is sent before reading the reply. Some monitors ignore the first.
    var readRequestSends: Int = 2
    /// Wait between a read request and reading the reply. MCCS asks for at least 40 ms; slow monitors need more.
    var replyWaitMs: Int = 50
}

/// One external monitor's DDC/CI endpoint, as found in the I/O registry. Owns a retain on the
/// registry node for as long as the endpoint (or a channel using it) is alive.
final class BusEndpoint {
    let vendor: UInt32?
    let product: UInt32?
    let serial: UInt32?
    let service: CFTypeRef
    /// Registry entry ID of the DDC service node: identifies the physical bus across enumerations.
    let registryID: UInt64
    private let node: io_object_t

    init(vendor: UInt32?, product: UInt32?, serial: UInt32?, service: CFTypeRef, registryID: UInt64, node: io_object_t) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.service = service
        self.registryID = registryID
        self.node = node
    }

    deinit { IOObjectRelease(node) }
}

enum BusLocator {
    /// Walks the registry in order. Each framebuffer node carries the attached display's identity,
    /// and the DDC service node for that display sits below it.
    static func externalEndpoints() -> [BusEndpoint] {
        guard let create = SystemSymbols.avServiceCreate else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var identity: (vendor: UInt32?, product: UInt32?, serial: UInt32?) = (nil, nil, nil)
        var found: [BusEndpoint] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            switch className(of: entry) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                identity = productIdentity(of: entry)
            case "DCPAVServiceProxy":
                guard property(entry, "Location") as? String == "External" else { continue }
                IOObjectRetain(entry) // keep the node alive for the service's lifetime
                if let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    var id: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(entry, &id)
                    found.append(BusEndpoint(vendor: identity.vendor, product: identity.product,
                                             serial: identity.serial, service: service, registryID: id,
                                             node: entry))
                } else {
                    IOObjectRelease(entry)
                }
            default:
                break
            }
        }
        return found
    }

    /// Pairs external displays with endpoints, each endpoint used at most once: exact
    /// vendor/model/serial first, then vendor/model in registry order, then, if exactly one display
    /// and one endpoint are left, those two.
    static func assign(_ displays: [CGDirectDisplayID], _ endpoints: [BusEndpoint]) -> [CGDirectDisplayID: BusEndpoint] {
        var free = Array(endpoints.indices)
        var result: [CGDirectDisplayID: BusEndpoint] = [:]
        func claim(_ display: CGDirectDisplayID, where test: (BusEndpoint) -> Bool) {
            guard result[display] == nil, let i = free.first(where: { test(endpoints[$0]) }) else { return }
            free.removeAll { $0 == i }
            result[display] = endpoints[i]
        }
        for d in displays {
            claim(d) { $0.vendor == CGDisplayVendorNumber(d) && $0.product == CGDisplayModelNumber(d)
                       && $0.serial == CGDisplaySerialNumber(d) }
        }
        for d in displays {
            claim(d) { $0.vendor == CGDisplayVendorNumber(d) && $0.product == CGDisplayModelNumber(d) }
        }
        let unmatched = displays.filter { result[$0] == nil }
        if unmatched.count == 1, free.count == 1 { result[unmatched[0]] = endpoints[free[0]] }
        return result
    }

    private static func className(of entry: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buffer)
        return String(cString: buffer)
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func productIdentity(of entry: io_object_t) -> (UInt32?, UInt32?, UInt32?) {
        let attrs = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        return ((attrs?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                (attrs?["ProductID"] as? NSNumber)?.uint32Value,
                (attrs?["SerialNumber"] as? NSNumber)?.uint32Value)
    }
}

/// External monitor backlight over DDC/CI (MCCS luminance, VCP 0x10).
///
/// Writes are coalesced: while one is on the bus, newer requests replace the pending value, so
/// dragging a slider never queues up a backlog. A value equal to the last one written is skipped.
final class BusBacklight: BacklightChannel {
    let kind = "DDC backlight"
    private let endpoint: BusEndpoint // keeps the registry node alive while this channel exists
    private var service: CFTypeRef { endpoint.service }
    /// Which bus this channel drives (see `BusEndpoint.registryID`).
    var registryID: UInt64 { endpoint.registryID }
    private let queue = DispatchQueue(label: "dev.ourapp.lumen.bus")
    private let lock = NSLock()
    private var pending: UInt16?
    private var draining = false
    private var lastSent: UInt16?
    private var _tuning: BusTuning
    private(set) var maximum: UInt16 = 100

    var tuning: BusTuning {
        get { lock.withLock { _tuning } }
        set { lock.withLock { _tuning = newValue } }
    }

    /// Fails when the monitor does not answer a luminance read; the display then gets software dimming only.
    init?(endpoint: BusEndpoint, tuning: BusTuning) {
        self.endpoint = endpoint
        _tuning = tuning
        guard let reading = queue.sync(execute: { readVCP(MCCS.Code.luminance) }), reading.maximum > 0 else {
            return nil
        }
        maximum = reading.maximum
        lastSent = reading.current
    }

    func read() -> Double? {
        guard let r = queue.sync(execute: { readVCP(MCCS.Code.luminance) }), r.maximum > 0 else { return nil }
        lock.withLock { lastSent = r.current }
        return Double(r.current) / Double(r.maximum)
    }

    func write(_ level: Double) {
        let raw = UInt16((min(max(level, 0), 1) * Double(maximum)).rounded())
        let start: Bool = lock.withLock {
            pending = raw
            if draining { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    /// Blocking write of a raw luminance value, bypassing the "unchanged" skip. Used by the CLI.
    func writeRawNow(_ value: UInt16) -> Bool {
        queue.sync {
            let ok = send(MCCS.setVCP(code: MCCS.Code.luminance, value: value))
            if ok { lock.withLock { lastSent = value } }
            return ok
        }
    }

    private func drain() {
        while true {
            let next: UInt16? = lock.withLock {
                let v = pending
                pending = nil
                if v == nil { draining = false }
                return v
            }
            guard let value = next else { return }
            if value == lock.withLock({ lastSent }) { continue }
            if send(MCCS.setVCP(code: MCCS.Code.luminance, value: value)) {
                lock.withLock { lastSent = value }
            } else {
                log.error("DDC luminance write of \(value) failed after retries")
            }
        }
    }

    // MARK: bus transactions (always on `queue`)

    private func send(_ packet: [UInt8]) -> Bool {
        let t = tuning
        var delivered = 0
        var failures = 0
        while delivered < max(t.sendsPerValue, 1) {
            if transfer(write: packet) {
                delivered += 1
            } else {
                failures += 1
                if failures > t.retries { return delivered > 0 }
                usleep(UInt32(t.backoffMs) * 1000)
            }
        }
        return true
    }

    private func readVCP(_ code: UInt8) -> MCCS.Reading? {
        let t = tuning
        for _ in 0...max(t.retries, 0) {
            let sent = (0..<max(t.readRequestSends, 1)).map { _ in transfer(write: MCCS.getVCP(code: code)) }
            guard sent.contains(true) else {
                usleep(UInt32(t.backoffMs) * 1000)
                continue
            }
            usleep(UInt32(t.replyWaitMs) * 1000)
            var reply = [UInt8](repeating: 0, count: 12)
            let status = SystemSymbols.avServiceRead.map {
                $0(service, UInt32(MCCS.i2cAddress), UInt32(MCCS.hostAddress), &reply, UInt32(reply.count))
            } ?? kIOReturnUnsupported
            log.debug("DDC read status \(status) bytes \(reply.map { String(format: "%02x", $0) }.joined(separator: " "))")
            if status == kIOReturnSuccess, let reading = MCCS.parseGetVCPReply(reply, code: code) {
                return reading
            }
            usleep(UInt32(t.backoffMs) * 1000)
        }
        return nil
    }

    private func transfer(write packet: [UInt8]) -> Bool {
        guard let write = SystemSymbols.avServiceWrite else { return false }
        usleep(UInt32(tuning.settleMs) * 1000)
        var bytes = packet
        return write(service, UInt32(MCCS.i2cAddress), UInt32(MCCS.hostAddress), &bytes, UInt32(bytes.count)) == kIOReturnSuccess
    }
}
