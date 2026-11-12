import Foundation
import IOKit
import LumenCore

/// One external monitor's DDC/CI connection. Every control on that monitor (backlight, speaker)
/// goes through the same link, so bus transactions never overlap.
///
/// Writes are coalesced per VCP code: while one is on the bus, a newer value for the same code
/// replaces the pending one, so dragging a slider never queues up a backlog. A value equal to the
/// last one written for that code is skipped. Codes are written in the order they were first queued.
final class BusLink {
    private let endpoint: BusEndpoint // keeps the registry node alive while the link exists
    private var service: CFTypeRef { endpoint.service }
    /// Which bus this link drives (see `BusEndpoint.registryID`).
    var registryID: UInt64 { endpoint.registryID }
    private let queue = DispatchQueue(label: "dev.ourapp.lumen.bus")
    private let lock = NSLock()
    private var pending: [(code: UInt8, value: UInt16)] = []
    private var draining = false
    private var lastSent: [UInt8: UInt16] = [:]
    private var _tuning: BusTuning

    init(endpoint: BusEndpoint, tuning: BusTuning) {
        self.endpoint = endpoint
        _tuning = tuning
    }

    var tuning: BusTuning {
        get { lock.withLock { _tuning } }
        set { lock.withLock { _tuning = newValue } }
    }

    /// Blocking read. Nil when the monitor gave no valid answer.
    func read(_ code: UInt8) -> MCCS.Reply? {
        let reply = queue.sync { readVCP(code) }
        if case .value(let r)? = reply { lock.withLock { lastSent[code] = r.current } }
        return reply
    }

    func write(_ code: UInt8, _ value: UInt16) {
        let start: Bool = lock.withLock {
            if let i = pending.firstIndex(where: { $0.code == code }) { pending[i].value = value }
            else { pending.append((code, value)) }
            if draining { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    /// Blocking write that bypasses the "unchanged" skip. Used by the CLI.
    func writeNow(_ code: UInt8, _ value: UInt16) -> Bool {
        queue.sync {
            let ok = send(MCCS.setVCP(code: code, value: value))
            if ok { lock.withLock { lastSent[code] = value } }
            return ok
        }
    }

    private func drain() {
        while true {
            let next: (code: UInt8, value: UInt16)? = lock.withLock {
                if pending.isEmpty { draining = false; return nil }
                return pending.removeFirst()
            }
            guard let (code, value) = next else { return }
            if value == lock.withLock({ lastSent[code] }) { continue }
            if send(MCCS.setVCP(code: code, value: value)) {
                lock.withLock { lastSent[code] = value }
            } else {
                log.error("DDC write of \(value) to VCP \(code) failed after retries")
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
