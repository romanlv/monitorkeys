import Foundation
import IOKit
import MonitorKeysCore

/// One external monitor's DDC/CI connection. Every control on that monitor (backlight, speaker)
/// goes through the same link, so bus transactions never overlap. Writes go through a
/// `VCPWriteQueue`: coalesced per code, repeats skipped, and read back once they pause.
final class BusLink {
    private let endpoint: BusEndpoint // keeps the registry node alive while the link exists
    private var service: CFTypeRef { endpoint.service }
    /// Which bus this link drives (see `BusEndpoint.registryID`).
    var registryID: UInt64 { endpoint.registryID }
    private let queue = DispatchQueue(label: "dev.ourapp.monitorkeys.bus")
    private let lock = NSLock()
    private let writes: VCPWriteQueue
    private var _tuning: BusTuning

    init(endpoint: BusEndpoint, tuning: BusTuning) {
        self.endpoint = endpoint
        _tuning = tuning
        writes = VCPWriteQueue(verifies: tuning.verifiesWrites)
    }

    var tuning: BusTuning {
        get { lock.withLock { _tuning } }
        set {
            lock.withLock { _tuning = newValue }
            writes.verifies = newValue.verifiesWrites
        }
    }

    /// Blocking read. Nil when the monitor gave no valid answer. Runs after every write queued
    /// before it has gone out.
    func read(_ code: UInt8) -> MCCS.Reply? {
        queue.sync {
            let reply = readVCP(code)
            // On the queue, so a drain can't send a newer value between the read and this note.
            if case .value(let r)? = reply { writes.note(code, r.current) }
            return reply
        }
    }

    func write(_ code: UInt8, _ value: UInt16) {
        if writes.enqueue(code, value) { queue.async { self.drain() } }
    }

    /// Blocking write that bypasses the "unchanged" skip. Used by the CLI.
    func writeNow(_ code: UInt8, _ value: UInt16) -> Bool {
        queue.sync {
            let ok = send(MCCS.setVCP(code: code, value: value))
            if ok { writes.note(code, value) }
            return ok
        }
    }

    /// The last write of `code` failed or was refused (see `VCPWriteQueue.isUnconfirmed`).
    func isUnconfirmed(_ code: UInt8) -> Bool {
        writes.isUnconfirmed(code)
    }

    /// The monitor's value for `code` has been read and taken as it is.
    func confirm(_ code: UInt8) {
        writes.confirm(code)
    }

    /// The next write of `code` goes on the bus even if it repeats the last value.
    func forget(_ code: UInt8) {
        writes.forget(code)
    }

    private func drain() {
        let bus = VCPWriteQueue.Bus(
            send: { [unowned self] code, value in send(MCCS.setVCP(code: code, value: value)) },
            read: { [unowned self] code in
                if case .value(let r)? = readVCP(code) { return r.current }
                return nil
            },
            pause: { usleep(25_000) }) // ten steps: writes count as paused after 250 ms
        writes.drain(bus) { event in
            switch event {
            case .writeFailed(let code, let value):
                log.error("DDC write of \(value) to VCP \(code) failed after retries")
            case .resending(let code, let reported, let value):
                log.info("monitor reports \(reported) for VCP \(code) after a write of \(value); sending again")
            case .notTaken(let code, let reported, let value):
                log.error("monitor keeps reporting \(reported) for VCP \(code) after writes of \(value)")
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

    private func readVCP(_ code: UInt8) -> MCCS.Reply? {
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
            if status == kIOReturnSuccess, let parsed = MCCS.parseGetVCP(reply, code: code) {
                return parsed // a value, or a definite "not supported": no point retrying either
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

/// External monitor backlight over DDC/CI (MCCS luminance, VCP 0x10).
final class BusBacklight: BacklightChannel {
    let kind = "DDC backlight"
    let link: BusLink
    let maximum: UInt16

    /// Fails when the monitor does not answer a luminance read; the display then gets software dimming only.
    init?(link: BusLink) {
        guard case .value(let r)? = link.read(MCCS.Code.luminance), r.maximum > 0 else { return nil }
        self.link = link
        maximum = r.maximum
    }

    func read() -> Double? {
        guard case .value(let r)? = link.read(MCCS.Code.luminance), r.maximum > 0 else { return nil }
        return Double(r.current) / Double(r.maximum)
    }

    func write(_ level: Double) {
        link.write(MCCS.Code.luminance, UInt16((min(max(level, 0), 1) * Double(maximum)).rounded()))
    }

    /// Our last write failed or the monitor refused it.
    var isUnconfirmed: Bool { link.isUnconfirmed(MCCS.Code.luminance) }
    func confirm() { link.confirm(MCCS.Code.luminance) }

    /// Sends `level` even if it is what was last written, and checks that it took.
    func rewrite(_ level: Double) {
        link.forget(MCCS.Code.luminance)
        write(level)
    }
}

/// A monitor's built-in speakers (or headphone jack) over DDC/CI: MCCS speaker volume (VCP 0x62)
/// and, where the monitor has it, audio mute (VCP 0x8D).
final class BusSpeaker {
    let link: BusLink
    let maximum: UInt16
    private(set) var model: SpeakerModel

    /// Fails when the monitor does not report a speaker volume.
    init?(link: BusLink) {
        guard case .value(let v)? = link.read(MCCS.Code.speakerVolume), v.maximum > 0 else { return nil }
        self.link = link
        maximum = v.maximum
        var muted = false
        var hasMute = false
        if case .value(let m)? = link.read(MCCS.Code.audioMute) {
            hasMute = true
            muted = m.current & 0xFF == MCCS.MuteValue.muted
        }
        model = SpeakerModel(volume: Double(v.current) / Double(v.maximum), muted: muted, hasMuteControl: hasMute)
    }

    var volume: Double { model.volume }
    var muted: Bool { model.muted }
    var audibleVolume: Double { model.audibleVolume }

    /// Picks up changes made with the monitor's own buttons.
    func resync() {
        guard case .value(let v)? = link.read(MCCS.Code.speakerVolume), v.maximum > 0 else { return }
        let level = Double(v.current) / Double(v.maximum)
        if model.hasMuteControl {
            guard case .value(let m)? = link.read(MCCS.Code.audioMute) else { return }
            model = SpeakerModel(volume: level, muted: m.current & 0xFF == MCCS.MuteValue.muted, hasMuteControl: true)
        } else if !(model.muted && v.current == 0) { // still at the 0 we set for mute: keep the volume to return to
            model = SpeakerModel(volume: level, muted: false, hasMuteControl: false)
        }
    }

    func setVolume(_ value: Double) { apply(model.setVolume(value)) }
    func setMuted(_ value: Bool) { apply(model.setMuted(value)) }
    func toggleMute() { apply(model.toggleMute()) }

    private func apply(_ writes: [SpeakerModel.Write]) {
        for w in writes {
            switch w {
            case .volume(let v): link.write(MCCS.Code.speakerVolume, UInt16((v * Double(maximum)).rounded()))
            case .mute(let m): link.write(MCCS.Code.audioMute, m ? MCCS.MuteValue.muted : MCCS.MuteValue.unmuted)
            }
        }
    }
}
