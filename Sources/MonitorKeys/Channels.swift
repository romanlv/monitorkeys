import CoreGraphics
import Foundation
import os

let log = Logger(subsystem: "dev.ourapp.monitorkeys", category: "channels")

/// A hardware brightness control, 0...1.
protocol BacklightChannel: AnyObject {
    var kind: String { get }
    func read() -> Double?
    func write(_ level: Double)
}

/// Apple panels (built-in, Studio Display, Pro Display XDR) via the system brightness service.
final class BuiltInBacklight: BacklightChannel {
    let kind = "built-in backlight"
    private let display: CGDirectDisplayID

    init?(display: CGDirectDisplayID) {
        self.display = display
        guard SystemSymbols.setBrightness != nil, read() != nil else { return nil }
    }

    func read() -> Double? {
        guard let get = SystemSymbols.getBrightness else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? Double(value) : nil
    }

    func write(_ level: Double) {
        _ = SystemSymbols.setBrightness?(display, Float(level))
    }
}
