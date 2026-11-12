import CoreGraphics
import Foundation
import IOKit
import LumenCore

/// Timing knobs for the display bus. Monitors differ a lot; these are user-tunable.
struct BusTuning: Equatable {
    /// Pause before every bus transaction.
    var settleMs: Int = 20
    /// How many times one value is sent. Setting a VCP value is idempotent, so a repeat is harmless,
    /// and some monitors (the tested LG ULTRAWIDE) silently drop a single send.
    var sendsPerValue: Int = 2
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
