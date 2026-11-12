import Testing
import Foundation
@testable import MonitorKeysCore

@Suite struct MCCSTests {
    @Test func setLuminancePacketMatchesSpecLayout() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        #expect(MCCS.setVCP(code: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    @Test func getLuminanceRequestMatchesSpecExample() {
        #expect(MCCS.getVCP(code: 0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func sixteenBitValuesSplitHighLow() {
        let p = MCCS.setVCP(code: 0x10, value: 0x0123)
        #expect(p[3] == 0x01 && p[4] == 0x23)
    }

    @Test func parsesValidReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10) == .init(current: 50, maximum: 100))
    }

    @Test func parsesReplyWithTrailingPadding() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2, 0x00]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10)?.current == 50)
    }

    @Test func acceptsReplyWithHostAddressInLengthSlot() {
        // Captured from an LG ULTRAWIDE on an M5 MacBook: byte 1 reads 0x51, checksum assumes 0x88.
        let reply: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3F, 0xFF, 0x2F]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10) == .init(current: 63, maximum: 100))
    }

    @Test func rejectsNullMessage() {
        // "6E 80 BE": display has nothing to say yet.
        let reply: [UInt8] = [0x6E, 0x80, 0xBE, 0x00, 0xE6, 0xD2, 0xD0, 0xA4, 0x0A, 0xF9, 0xAB, 0x2F]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10) == nil)
    }

    @Test func rejectsBadChecksum() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10) == nil)
    }

    @Test func distinguishesUnsupportedCode() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD7]
        #expect(MCCS.parseGetVCP(reply, code: 0x62) == .unsupported)
        #expect(MCCS.parseGetVCPReply(reply, code: 0x62) == nil)
    }

    @Test func parsesSpeakerVolume() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x1E, 0xAC]
        #expect(MCCS.parseGetVCP(reply, code: MCCS.Code.speakerVolume) == .value(.init(current: 30, maximum: 100)))
    }

    @Test func muteWritePacket() {
        #expect(MCCS.setVCP(code: MCCS.Code.audioMute, value: MCCS.MuteValue.muted) == [0x84, 0x03, 0x8D, 0x00, 0x01, 0x34])
    }

    @Test func rejectsWrongCode() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF0]
        #expect(MCCS.parseGetVCPReply(reply, code: 0x10) == nil)
    }
}

@Suite struct RampTests {
    let table = RampTable(policy: RampPolicy(dimmingStart: 0.3, backlightFloor: 0.1, dimmerFloor: 0.2))

    @Test func endpoints() {
        #expect(table.levels(forBrightness: 0) == .init(backlight: 0.1, dimmer: 0.2))
        #expect(table.levels(forBrightness: 1) == .init(backlight: 1, dimmer: 1))
        #expect(table.levels(forBrightness: 0.3) == .init(backlight: 0.1, dimmer: 1))
    }

    @Test func clampsOutOfRange() {
        #expect(table.levels(forBrightness: -1) == table.levels(forBrightness: 0))
        #expect(table.levels(forBrightness: 2) == table.levels(forBrightness: 1))
    }

    @Test func bothChannelsAreMonotonic() {
        var previous = table.levels(forBrightness: 0)
        for i in 1...100 {
            let next = table.levels(forBrightness: Double(i) / 100)
            #expect(next.backlight >= previous.backlight - 1e-12)
            #expect(next.dimmer >= previous.dimmer - 1e-12)
            previous = next
        }
    }

    @Test func reverseRoundTrips() {
        for i in 0...100 {
            let l = Double(i) / 100
            #expect(abs(table.brightness(for: table.levels(forBrightness: l)) - l) < 1e-9)
        }
    }

    @Test func reverseFollowsExternalBacklightChange() {
        // Monitor buttons moved backlight to 55% while the dimmer is at full.
        let l = table.brightness(for: .init(backlight: 0.55, dimmer: 1))
        #expect(abs(table.levels(forBrightness: l).backlight - 0.55) < 1e-9)
    }

    @Test func softwareOnlyNeverNeedsBacklight() {
        let t = RampTable(policy: .softwareOnly(dimmerFloor: 0.2))
        #expect(t.levels(forBrightness: 0).dimmer == 0.2)
        #expect(t.levels(forBrightness: 1).dimmer == 1)
        #expect(abs(t.brightness(for: .init(backlight: 1, dimmer: 0.6)) - 0.5) < 1e-9)
    }

    @Test func noSoftwareDimming() {
        let t = RampTable(policy: RampPolicy(dimmingStart: 0, backlightFloor: 0, dimmerFloor: 0.2))
        #expect(t.levels(forBrightness: 0) == .init(backlight: 0, dimmer: 1))
        #expect(t.levels(forBrightness: 0.5) == .init(backlight: 0.5, dimmer: 1))
    }
}

@Suite struct MediaKeyTests {
    private func data1(code: Int, state: Int, repeat r: Bool = false) -> Int {
        (code << 16) | (state << 8) | (r ? 1 : 0)
    }

    @Test func decodesBrightnessUpDown() {
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 2, state: 0x0A))
                == .init(key: .brightness(.up), isDown: true, isRepeat: false))
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 3, state: 0x0B))
                == .init(key: .brightness(.down), isDown: false, isRepeat: false))
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 3, state: 0x0A, repeat: true))?.isRepeat == true)
    }

    @Test func decodesSoundKeys() {
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 0, state: 0x0A))?.key == .volume(.up))
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 1, state: 0x0B))?.key == .volume(.down))
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 7, state: 0x0A))?.key == .mute)
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 0x48) == .volume(.up))
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 0x49) == .volume(.down))
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 0x4A) == .mute)
    }

    @Test func ignoresOtherKeysAndSubtypes() {
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 16, state: 0x0A)) == nil) // play
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 8, data1: data1(code: 0, state: 0x0C)) == nil)
        #expect(MediaKeyDecoder.decodeSystemDefined(subtype: 7, data1: data1(code: 2, state: 0x0A)) == nil)
    }

    @Test func decodesVirtualKeys() {
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 144) == .brightness(.up))
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 145) == .brightness(.down))
        #expect(MediaKeyDecoder.decodeKeyDown(virtualKey: 122) == nil) // F1 as a plain function key
    }

    @Test func stepsOnSixteenthGrid() {
        #expect(LevelStep.next(from: 0.5, key: .up, fine: false) == 9.0 / 16)
        #expect(LevelStep.next(from: 0.5, key: .down, fine: false) == 7.0 / 16)
    }

    @Test func snapsOffGridValues() {
        #expect(LevelStep.next(from: 0.63, key: .up, fine: false) == 11.0 / 16)
        #expect(LevelStep.next(from: 0.63, key: .down, fine: false) == 10.0 / 16)
    }

    @Test func fineStepsAndClamping() {
        #expect(LevelStep.next(from: 0.5, key: .up, fine: true) == 33.0 / 64)
        #expect(LevelStep.next(from: 1, key: .up, fine: false) == 1)
        #expect(LevelStep.next(from: 0, key: .down, fine: false) == 0)
    }
}

@Suite struct DayScheduleTests {
    private func sunTimes(_ y: Int, _ m: Int, _ d: Int, lat: Double, lon: Double, tz: String) -> SunTimes? {
        let zone = TimeZone(identifier: tz)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        guard case .normal(let t) = SunClock.day(on: date, latitude: lat, longitude: lon, timeZone: zone) else { return nil }
        return t
    }

    @Test func torontoSolsticesMatchAlmanac() throws {
        // Published times: Jun 21 sunrise 5:36, sunset 21:03 (EDT); Dec 21 sunrise 7:48, sunset 16:43 (EST).
        let june = try #require(sunTimes(2026, 6, 21, lat: 43.65, lon: -79.38, tz: "America/Toronto"))
        #expect(abs(june.sunrise - (5 * 60 + 36)) < 4)
        #expect(abs(june.sunset - (21 * 60 + 3)) < 4)
        let dec = try #require(sunTimes(2026, 12, 21, lat: 43.65, lon: -79.38, tz: "America/Toronto"))
        #expect(abs(dec.sunrise - (7 * 60 + 48)) < 4)
        #expect(abs(dec.sunset - (16 * 60 + 43)) < 4)
    }

    @Test func polarDayAndNight() {
        let zone = TimeZone(identifier: "Europe/Oslo")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let june = cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let dec = cal.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
        #expect(SunClock.day(on: june, latitude: 78.2, longitude: 15.6, timeZone: zone) == .sunNeverSets)
        #expect(SunClock.day(on: dec, latitude: 78.2, longitude: 15.6, timeZone: zone) == .sunNeverRises)
    }

    let sun = SunTimes(sunrise: 7 * 60, sunset: 17 * 60)
    let plan = DaySchedule(dayLevel: 1, eveningLevel: 0.6, nightLevel: 0.2,
                           wakeMinute: 7 * 60, bedtimeMinute: 23 * 60, transitionMinutes: 60)

    @Test func plateausHitEachLevel() {
        #expect(plan.level(atMinute: 12 * 60, sun: sun) == 1)
        #expect(abs(plan.level(atMinute: 20 * 60, sun: sun) - 0.6) < 1e-9)
        #expect(abs(plan.level(atMinute: 3 * 60, sun: sun) - 0.2) < 1e-9)
        #expect(plan.phase(atMinute: 12 * 60, sun: sun) == .day)
        #expect(plan.phase(atMinute: 20 * 60, sun: sun) == .evening)
        #expect(plan.phase(atMinute: 3 * 60, sun: sun) == .night)
    }

    @Test func sunsetIsCentredAndBedtimeFinishesOnTime() {
        #expect(abs(plan.level(atMinute: 17 * 60, sun: sun) - 0.8) < 1e-9) // halfway at sunset
        #expect(abs(plan.level(atMinute: 23 * 60, sun: sun) - 0.2) < 1e-9) // fully night at bedtime
        #expect(abs(plan.level(atMinute: 22 * 60, sun: sun) - 0.6) < 1e-9) // ramp starts an hour before
    }

    @Test func curveIsContinuous() {
        var previous = plan.level(atMinute: 0, sun: sun)
        for m in stride(from: 1.0, through: 1440, by: 1) {
            let next = plan.level(atMinute: m, sun: sun)
            #expect(abs(next - previous) < 0.03)
            previous = next
        }
    }

    @Test func bedtimeAfterMidnightAndBeforeSunset() {
        let late = DaySchedule(dayLevel: 1, eveningLevel: 0.6, nightLevel: 0.2,
                               wakeMinute: 9 * 60, bedtimeMinute: 60, transitionMinutes: 30)
        #expect(abs(late.level(atMinute: 23.5 * 60, sun: sun) - 0.6) < 1e-9)
        #expect(abs(late.level(atMinute: 4 * 60, sun: sun) - 0.2) < 1e-9)
        #expect(abs(late.level(atMinute: 8 * 60, sun: sun) - 0.2) < 1e-9) // still asleep after sunrise
        // Summer far north: bedtime before sunset goes straight from day to night.
        let summer = SunTimes(sunrise: 4 * 60, sunset: 22.5 * 60)
        #expect(abs(plan.level(atMinute: 23.2 * 60, sun: summer) - 0.2) < 1e-9)
    }

    @Test func manualChangeHoldsUntilNextRamp() {
        // 12:00 → sunset ramp starts 16:30.
        #expect(plan.minutesUntilNextTransition(afterMinute: 12 * 60, sun: sun) == 4.5 * 60)
        // 23:30 → wake ramp starts 06:00 next day.
        #expect(plan.minutesUntilNextTransition(afterMinute: 23.5 * 60, sun: sun) == 6.5 * 60)
    }
}

@Suite struct PolarScheduleTests {
    let plan = DaySchedule(dayLevel: 1, eveningLevel: 0.6, nightLevel: 0.2,
                           wakeMinute: 7 * 60, bedtimeMinute: 23 * 60, transitionMinutes: 60)

    @Test func midnightSunIsDayUntilBedtime() {
        let sun = SunClock.scheduleTimes(.sunNeverSets)
        for m in stride(from: 8.0 * 60, through: 21.5 * 60, by: 30) {
            #expect(plan.level(atMinute: m, sun: sun) == 1)
        }
    }

    @Test func polarNightNeverReachesDay() {
        let sun = SunClock.scheduleTimes(.sunNeverRises)
        for m in stride(from: 8.0 * 60, through: 21.5 * 60, by: 30) {
            #expect(abs(plan.level(atMinute: m, sun: sun) - 0.6) < 1e-9)
        }
    }
}

@Suite struct NearPolarScheduleTests {
    @Test func sunsetAfterMidnightStaysDayAtNoon() {
        // Tromsø, mid-May: sunrise ~01:09, sunset ~00:12 the next night (wrapped to 11.8 minutes).
        let plan = DaySchedule(dayLevel: 1, eveningLevel: 0.6, nightLevel: 0.2,
                               wakeMinute: 7 * 60, bedtimeMinute: 23 * 60, transitionMinutes: 120)
        let sun = SunTimes(sunrise: 68.8, sunset: 11.8)
        #expect(plan.level(atMinute: 12 * 60, sun: sun) == 1)
    }

    @Test func shortNightWithLateSunsetKeepsEveningAfterSunset() {
        // Sunset 00:30, sunrise 03:30: three hours of evening when the ramps don't cover the night.
        let plan = DaySchedule(dayLevel: 1, eveningLevel: 0.6, nightLevel: 0.2,
                               wakeMinute: 12 * 60, bedtimeMinute: 11 * 60, transitionMinutes: 30)
        let sun = SunTimes(sunrise: 210, sunset: 30)
        #expect(plan.level(atMinute: 18 * 60, sun: sun) == 1)
        #expect(abs(plan.level(atMinute: 120, sun: sun) - 0.6) < 1e-9) // 02:00, between the ramps
    }
}

@Suite struct SpeakerTests {
    @Test func muteControlIsUsedWhenPresent() {
        var m = SpeakerModel(volume: 0.4, muted: false, hasMuteControl: true)
        #expect(m.toggleMute() == [.mute(true)])
        #expect(m.audibleVolume == 0 && m.volume == 0.4)
        #expect(m.toggleMute() == [.mute(false)])
    }

    @Test func muteFallsBackToZeroVolume() {
        var m = SpeakerModel(volume: 0.4, muted: false, hasMuteControl: false)
        #expect(m.setMuted(true) == [.volume(0)])
        #expect(m.setMuted(true) == [])
        #expect(m.setMuted(false) == [.volume(0.4)])
    }

    @Test func changingVolumeUnmutes() {
        var a = SpeakerModel(volume: 0.4, muted: true, hasMuteControl: true)
        #expect(a.setVolume(0.5) == [.volume(0.5), .mute(false)]) // level first, so the old level never plays
        #expect(!a.muted)
        var b = SpeakerModel(volume: 0.4, muted: true, hasMuteControl: false)
        #expect(b.setVolume(0.5) == [.volume(0.5)])
        #expect(!b.muted)
    }

    @Test func volumeClamps() {
        var m = SpeakerModel(volume: 2, muted: false, hasMuteControl: false)
        #expect(m.volume == 1)
        #expect(m.setVolume(-1) == [.volume(0)])
    }

    @Test func routingLeavesSystemControlledOutputsToMacOS() {
        #expect(SpeakerRouting.pick(outputName: "LG ULTRAWIDE", viaDisplayCable: true, hasSystemVolume: true,
                                    monitors: ["LG ULTRAWIDE"]) == nil)
    }

    @Test func routingMatchesByName() {
        #expect(SpeakerRouting.pick(outputName: "lg ultrawide", viaDisplayCable: true, hasSystemVolume: false,
                                    monitors: ["DELL U2720Q", "LG ULTRAWIDE"]) == 1)
    }

    @Test func routingFallsBackToTheOnlyMonitorOnDisplayCable() {
        #expect(SpeakerRouting.pick(outputName: "Monitor audio", viaDisplayCable: true, hasSystemVolume: false,
                                    monitors: ["LG ULTRAWIDE"]) == 0)
        #expect(SpeakerRouting.pick(outputName: "Monitor audio", viaDisplayCable: true, hasSystemVolume: false,
                                    monitors: ["A", "B"]) == nil)
        #expect(SpeakerRouting.pick(outputName: "USB DAC", viaDisplayCable: false, hasSystemVolume: false,
                                    monitors: ["LG ULTRAWIDE"]) == nil)
    }
}

@Suite struct BinaryWatchTests {
    /// Runs `body` with `source` copied into its own temporary folder; the folder is removed afterwards.
    private func withCopy(of source: String? = nil, _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("exe")
        if let source {
            try FileManager.default.copyItem(atPath: source, toPath: file.path)
        } else {
            try Data("v1".utf8).write(to: file)
        }
        try body(file)
    }

    private func watch(_ file: URL) -> BinaryWatch { BinaryWatch(code: file, executable: file.path) }

    /// Starts the watch; the returned semaphore is signalled when its callback runs.
    private func arm(_ watch: BinaryWatch) -> DispatchSemaphore {
        let fired = DispatchSemaphore(value: 0)
        watch.watch(queue: DispatchQueue(label: "test")) { fired.signal() }
        return fired
    }

    /// Overwrites `file` in place, keeping its inode, the way `cp` onto an existing file does.
    private func overwrite(_ file: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// Where each architecture starts in a universal binary ([0] for a thin one). Only the host's
    /// slice is validated, so a change must hit every slice to be sure of reaching it.
    private func sliceOffsets(_ bytes: Data) -> [Int] {
        func u32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } } // big-endian
        func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) << 32 | UInt64(u32(at + 4)) }
        switch u32(0) {
        case 0xCAFEBABE: return (0..<Int(u32(4))).map { Int(u32(8 + $0 * 20 + 8)) }   // fat_arch
        case 0xCAFEBABF: return (0..<Int(u32(4))).map { Int(u64(8 + $0 * 32 + 8)) }   // fat_arch_64
        default: return [0]
        }
    }

    @Test func untouchedFileIsIntact() throws {
        try withCopy { #expect(watch($0).isIntact) }
    }

    @Test func untouchedSignedBinaryIsIntact() throws {
        try withCopy(of: "/usr/bin/true") { #expect(watch($0).isIntact) }
    }

    @Test func signedBinaryOverwrittenInPlaceIsNotIntactAndFires() throws {
        try withCopy(of: "/usr/bin/true") { file in
            let w = watch(file)
            let fired = arm(w)
            try overwrite(file, with: try Data(contentsOf: URL(fileURLWithPath: "/bin/echo")))
            #expect(fired.wait(timeout: .now() + 2) == .success)
            #expect(!w.isIntact)
        }
    }

    @Test func signedBinaryWithOneByteChangedIsNotIntact() throws {
        try withCopy(of: "/usr/bin/true") { file in
            let w = watch(file)
            var bytes = try Data(contentsOf: file)
            for offset in sliceOffsets(bytes) { bytes[offset + 64] ^= 0xFF } // load commands, signed
            try overwrite(file, with: bytes)
            #expect(!w.isIntact) // after a second try, in case the read failure was transient
        }
    }

    @Test func signedBinaryWithOnlyMetadataTouchedStaysIntact() throws {
        try withCopy(of: "/usr/bin/true") { file in
            let w = watch(file)
            #expect(setxattr(file.path, "dev.test", "x", 1, 0, 0) == 0) // bumps ctime, not the code
            #expect(w.isIntact)
            #expect(w.isIntact)
        }
    }

    @Test func unsignedFileOverwrittenInPlaceIsNotIntact() throws {
        try withCopy { file in
            let w = watch(file)
            try overwrite(file, with: Data("v2!".utf8))
            #expect(!w.isIntact)
        }
    }

    @Test func deletedFileIsNotIntactAndFires() throws {
        try withCopy { file in
            let w = watch(file)
            let fired = arm(w)
            try FileManager.default.removeItem(at: file)
            #expect(fired.wait(timeout: .now() + 2) == .success)
            #expect(!w.isIntact)
        }
    }

    @Test func fileReplacedByRenameIsNotIntactAndFires() throws {
        try withCopy { file in
            let w = watch(file)
            let replacement = file.deletingLastPathComponent().appendingPathComponent("new")
            try Data("v2".utf8).write(to: replacement)
            let fired = arm(w)
            #expect(rename(replacement.path, file.path) == 0)
            #expect(fired.wait(timeout: .now() + 2) == .success)
            #expect(!w.isIntact)
        }
    }

    @Test func fileDeletedAndRecreatedIsNotIntact() throws {
        try withCopy { file in
            let w = watch(file)
            try FileManager.default.removeItem(at: file)
            try Data("v1".utf8).write(to: file)
            #expect(!w.isIntact)
        }
    }

    @Test func movedParentFolderIsNotIntact() throws {
        try withCopy { file in
            let w = watch(file)
            let dir = file.deletingLastPathComponent()
            let moved = dir.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: dir, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            #expect(!w.isIntact)
        }
    }

    @Test func missingFileAtStartCountsAsIntact() {
        let path = "/nonexistent/\(UUID().uuidString)"
        #expect(BinaryWatch(code: URL(fileURLWithPath: path), executable: path).isIntact)
    }
}

/// The app's own case: a signed .app bundle, where the signature also covers Info.plist and every
/// file in the bundle.
@Suite struct BinaryWatchBundleTests {
    /// Runs `body` with a freshly built, ad-hoc signed Test.app; its folder is removed afterwards.
    private func withSignedBundle(_ body: (_ app: URL, _ exe: URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Test.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("Test")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: exe.path)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.test.binarywatch", "CFBundleExecutable": "Test",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        try body(app, exe)
    }

    @Test func untouchedBundleIsIntact() throws {
        try withSignedBundle { app, exe in
            let w = BinaryWatch(code: app, executable: exe.path)
            #expect(w.isIntact)
            #expect(w.isIntact)
        }
    }

    @Test func editedInfoPlistIsNotIntact() throws {
        try withSignedBundle { app, exe in
            let w = BinaryWatch(code: app, executable: exe.path)
            let plist = app.appendingPathComponent("Contents/Info.plist")
            var dict = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
            dict["CFBundleVersion"] = "99"
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
            #expect(!w.isIntact)
        }
    }

    @Test func fileAddedToTheBundleIsNotIntact() throws {
        try withSignedBundle { app, exe in
            let w = BinaryWatch(code: app, executable: exe.path)
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: resources.appendingPathComponent("extra.txt"))
            #expect(!w.isIntact)
        }
    }

    @Test func metadataOnTheBundleStaysIntact() throws {
        try withSignedBundle { app, exe in
            let w = BinaryWatch(code: app, executable: exe.path)
            #expect(setxattr(app.path, "dev.test", "x", 1, 0, 0) == 0) // like LaunchServices' last-used date
            #expect(w.isIntact)
        }
    }
}
