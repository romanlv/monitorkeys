import CoreGraphics
import Foundation
import IOKit

/// macOS calls that have no public header. Resolved at runtime so a missing symbol degrades a
/// channel instead of crashing the app.
enum SystemSymbols {
    typealias BrightnessGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias BrightnessSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"

    static let getBrightness = resolve(displayServices, "DisplayServicesGetBrightness", BrightnessGet.self)
    static let setBrightness = resolve(displayServices, "DisplayServicesSetBrightness", BrightnessSet.self)
    static let avServiceCreate = resolve(ioKit, "IOAVServiceCreateWithService", AVServiceCreate.self)
    static let avServiceRead = resolve(ioKit, "IOAVServiceReadI2C", AVServiceI2C.self)
    static let avServiceWrite = resolve(ioKit, "IOAVServiceWriteI2C", AVServiceI2C.self)

    private static func resolve<T>(_ library: String, _ name: String, _: T.Type) -> T? {
        guard let handle = dlopen(library, RTLD_LAZY), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
