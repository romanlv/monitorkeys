/// DDC/CI message codec, written from the public VESA DDC/CI and MCCS specifications.
///
/// Wire format of a host → display message (the I²C data address byte is sent separately):
///   [0x80 | payloadLength, payload..., checksum]
/// where checksum = XOR of the display's write address (0x6E), the host source address (0x51)
/// and every byte before it. Display → host replies use 0x50 as the virtual host address in their checksum.
public enum MCCS {
    /// 7-bit I²C address of the DDC/CI endpoint in a monitor.
    public static let i2cAddress: UInt8 = 0x37
    /// Host source address; also used as the I²C "data address" byte.
    public static let hostAddress: UInt8 = 0x51
    static let displayWriteAddress: UInt8 = 0x6E
    static let replyChecksumSeed: UInt8 = 0x50

    public enum Opcode: UInt8 {
        case getVCPRequest = 0x01
        case getVCPReply = 0x02
        case setVCP = 0x03
    }

    public enum Code {
        /// Luminance (backlight).
        public static let luminance: UInt8 = 0x10
        /// Audio: speaker volume.
        public static let speakerVolume: UInt8 = 0x62
        /// Audio mute (low byte 1 = muted, 2 = not muted; the high byte is screen blanking, left at 0).
        public static let audioMute: UInt8 = 0x8D
    }

    public enum MuteValue {
        public static let muted: UInt16 = 1
        public static let unmuted: UInt16 = 2
    }

    /// Outcome of a valid Get VCP reply.
    public enum Reply: Equatable, Sendable {
        case value(Reading)
        /// The display answered, saying it does not implement this code.
        case unsupported
    }

    public struct Reading: Equatable, Sendable {
        public var current: UInt16
        public var maximum: UInt16
    }

    public static func setVCP(code: UInt8, value: UInt16) -> [UInt8] {
        frame(payload: [Opcode.setVCP.rawValue, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static func getVCP(code: UInt8) -> [UInt8] {
        frame(payload: [Opcode.getVCPRequest.rawValue, code])
    }

    static func frame(payload: [UInt8]) -> [UInt8] {
        var bytes = [0x80 | UInt8(payload.count)] + payload
        bytes.append(xor(bytes, seed: displayWriteAddress ^ hostAddress))
        return bytes
    }

    /// Parse a Get VCP reply. Accepts a buffer with leading or trailing junk, but only a frame
    /// with a valid checksum, a zero result code and the requested VCP code.
    public static func parseGetVCPReply(_ bytes: [UInt8], code: UInt8) -> Reading? {
        if case .value(let r)? = parseGetVCP(bytes, code: code) { return r }
        return nil
    }

    /// Like `parseGetVCPReply`, but tells "unsupported code" apart from "no valid reply".
    public static func parseGetVCP(_ bytes: [UInt8], code: UInt8) -> Reply? {
        // Frame: 6E 88 02 rc code type maxH maxL curH curL chk
        let frameLength = 11
        guard bytes.count >= frameLength else { return nil }
        for start in 0...(bytes.count - frameLength) {
            let f = Array(bytes[start ..< start + frameLength])
            // Some Apple Silicon display buses hand back the host address (0x51) where the length
            // byte (0x88) belongs. The display's checksum is still computed over 0x88, so we
            // validate against the canonical frame.
            guard f[0] == displayWriteAddress,
                  f[1] == 0x88 || f[1] == hostAddress,
                  f[2] == Opcode.getVCPReply.rawValue,
                  f[4] == code else { continue }
            var canonical = Array(f[0 ..< 10])
            canonical[1] = 0x88
            guard xor(canonical, seed: replyChecksumSeed) == f[10] else { continue }
            guard f[3] == 0x00 else { return .unsupported }
            return .value(Reading(current: UInt16(f[8]) << 8 | UInt16(f[9]),
                                  maximum: UInt16(f[6]) << 8 | UInt16(f[7])))
        }
        return nil
    }

    static func xor(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}
