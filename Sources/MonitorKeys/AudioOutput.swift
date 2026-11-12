import CoreAudio
import Foundation

/// The Mac's current sound output, as Core Audio reports it.
struct AudioOutput {
    let name: String
    /// True for outputs that carry sound over a display cable (DisplayPort, HDMI).
    let viaDisplayCable: Bool
    /// True when macOS can change this output's volume itself (built-in speakers, USB, Bluetooth…).
    let hasSystemVolume: Bool

    static func current() -> AudioOutput? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        var nameAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameOK = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &name) == noErr
        let transport: UInt32 = value(device, kAudioDevicePropertyTransportType) ?? 0
        return AudioOutput(name: nameOK ? (name?.takeRetainedValue() as String? ?? "") : "",
                           viaDisplayCable: transport == kAudioDeviceTransportTypeDisplayPort
                                         || transport == kAudioDeviceTransportTypeHDMI,
                           hasSystemVolume: hasSettableVolume(device))
    }

    /// A settable output volume on the main element or on the first channel.
    private static func hasSettableVolume(_ device: AudioDeviceID) -> Bool {
        [kAudioObjectPropertyElementMain, 1].contains { element in
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &a)
                && AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func value<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var a = address(selector)
        var v: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
}
