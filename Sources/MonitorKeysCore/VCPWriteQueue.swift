import Foundation

/// The write side of one monitor's DDC link, without the bus itself.
///
/// Values are coalesced per VCP code: while one is on the bus, a newer value for the same code
/// replaces the pending one, so dragging a slider never queues up a backlog. A value equal to the
/// last one written for that code is skipped. Codes are written in the order they were first queued.
/// When `verifies` is on and the writes pause, each code written is read back and sent once more if
/// the monitor didn't take it: some monitors drop a write now and then, even one sent twice.
public final class VCPWriteQueue: @unchecked Sendable {
    /// What the queue needs from the bus. Every call happens inside `drain`, on the caller's thread.
    public struct Bus {
        /// Sends a value; false when it could not be delivered.
        public var send: (_ code: UInt8, _ value: UInt16) -> Bool
        /// The monitor's current value for a code; nil when it gave no answer.
        public var read: (_ code: UInt8) -> UInt16?
        /// Waits one short step while checking whether the writes have paused.
        public var pause: () -> Void
        public init(send: @escaping (UInt8, UInt16) -> Bool, read: @escaping (UInt8) -> UInt16?,
                    pause: @escaping () -> Void) {
            self.send = send
            self.read = read
            self.pause = pause
        }
    }

    public enum Event: Equatable, Sendable {
        case writeFailed(code: UInt8, value: UInt16)
        /// The monitor reported `reported` after a write of `value`; it is being sent again.
        case resending(code: UInt8, reported: UInt16, value: UInt16)
        /// Still `reported` after the second write.
        case notTaken(code: UInt8, reported: UInt16, value: UInt16)
    }

    private let lock = NSLock()
    private var pending: [(code: UInt8, value: UInt16)] = []
    private var draining = false
    private var lastSent: [UInt8: UInt16] = [:]
    /// Codes whose last write failed or was refused: what the monitor holds is not what we sent.
    private var unconfirmed: Set<UInt8> = []
    private var _verifies: Bool
    /// How many `pause` steps without a new write count as the writes having paused.
    public let quietSteps: Int

    public init(verifies: Bool = true, quietSteps: Int = 10) {
        _verifies = verifies
        self.quietSteps = quietSteps
    }

    public var verifies: Bool {
        get { lock.withLock { _verifies } }
        set { lock.withLock { _verifies = newValue } }
    }

    /// Queues `value` for `code`. Returns true when no drain is running and the caller must start one.
    public func enqueue(_ code: UInt8, _ value: UInt16) -> Bool {
        lock.withLock {
            if let i = pending.firstIndex(where: { $0.code == code }) { pending[i].value = value }
            else { pending.append((code, value)) }
            if draining { return false }
            draining = true
            return true
        }
    }

    /// True when the last write of `code` failed or the monitor refused it, until a write goes
    /// through. The monitor's value then isn't ours, but it wasn't changed on the monitor either.
    public func isUnconfirmed(_ code: UInt8) -> Bool {
        lock.withLock { unconfirmed.contains(code) }
    }

    /// Clears `isUnconfirmed` once the monitor's actual value has been read and accepted.
    public func confirm(_ code: UInt8) {
        lock.withLock { _ = unconfirmed.remove(code) }
    }

    /// Records the monitor's value for `code` as read or written outside the queue.
    public func note(_ code: UInt8, _ value: UInt16) {
        lock.withLock { lastSent[code] = value }
    }

    /// Forgets the last value written for `code`, so the next write of it goes on the bus even if
    /// unchanged. For when the monitor may have changed it on its own (after sleep, for example).
    public func forget(_ code: UInt8) {
        lock.withLock { lastSent[code] = nil }
    }

    /// Writes everything queued, including what is queued while it runs, then returns. Only one
    /// drain runs at a time: start it only when `enqueue` returns true.
    public func drain(_ bus: Bus, report: (Event) -> Void = { _ in }) {
        // Codes written in this run and not yet read back, with the value they should now hold.
        var unverified: [UInt8: UInt16] = [:]
        while true {
            let next: (code: UInt8, value: UInt16)? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            if let (code, value) = next {
                if value == lock.withLock({ lastSent[code] }) { continue }
                if bus.send(code, value) {
                    lock.withLock { lastSent[code] = value; unconfirmed.remove(code) }
                    unverified[code] = value
                } else {
                    report(.writeFailed(code: code, value: value))
                    lock.withLock { _ = unconfirmed.insert(code) }
                    unverified[code] = nil // an older value must not be checked or resent over this one
                }
                continue
            }
            if verifies, !unverified.isEmpty {
                // Only once the values stop changing (a slider drag has ended).
                if newWriteArrives(bus) { continue }
                // One quiet period covers every code written; stop early if a new write comes in.
                while lock.withLock({ pending.isEmpty }), let (code, value) = unverified.popFirst() {
                    verify(code, value, bus, report)
                }
                continue
            }
            let done: Bool = lock.withLock {
                if pending.isEmpty { draining = false }
                return !draining
            }
            if done { return }
        }
    }

    private func newWriteArrives(_ bus: Bus) -> Bool {
        for _ in 0..<max(quietSteps, 1) {
            bus.pause()
            if lock.withLock({ !pending.isEmpty }) { return true }
        }
        return false
    }

    /// Reads `code` back and sends `value` once more if the monitor reports something else.
    private func verify(_ code: UInt8, _ value: UInt16, _ bus: Bus, _ report: (Event) -> Void) {
        // The value the monitor reports instead of `value`; nil when it matches or gave no answer.
        func mismatch() -> UInt16? {
            guard let v = bus.read(code) else {
                // No answer (a monitor still waking, say): nothing to resend on, but don't vouch for it.
                lock.withLock { _ = unconfirmed.insert(code) }
                return nil
            }
            // Some monitors report a high byte alongside a single-byte setting such as mute.
            let singleByte = code == MCCS.Code.audioMute
            return v == value || (singleByte && v & 0xFF == value) ? nil : v
        }
        guard let reported = mismatch() else { return }
        report(.resending(code: code, reported: reported, value: value))
        // Two sends, each repeated as the link's own setting says (so four transfers by default): a
        // monitor that ignored the value may ignore one (the tested LG drops a write that comes right
        // after a read, and its sends-per-change may be set to once). Setting a value is idempotent.
        let first = bus.send(code, value)
        guard bus.send(code, value) || first else {
            report(.writeFailed(code: code, value: value))
            note(code, reported) // the monitor doesn't hold `value`: don't skip it as a repeat next time
            lock.withLock { _ = unconfirmed.insert(code) }
            return
        }
        if let still = mismatch() {
            report(.notTaken(code: code, reported: still, value: value))
            note(code, still) // so the same value is tried again next time
            lock.withLock { _ = unconfirmed.insert(code) }
        }
    }
}
