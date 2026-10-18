import Clibsodium
import Foundation

/// The data-bearing watermark codec (PLAN.md 3.21.1), ported from Web A `src/secutg/watermark/codec.ts`.
///
/// The payload is **decoded**, not verified against a candidate list. The earlier design hashed the identities into
/// a 64-bit tag, which meant an investigator had to already know the chat and every member in order to enumerate
/// candidates and compare. In practice a leaked screenshot arrives with the names painted out and no indication of
/// which group it came from — the candidate list cannot be built at all, and a verify-only scheme is then not slow
/// but useless.
///
/// Nothing is lost by the change. The stated reason for the tag was that reverse engineering the scheme must reveal
/// no identities, and that still holds: **the spreading codes are derived from the project key**, so without the key
/// the pattern cannot even be demodulated, let alone read.
///
/// This type is shared verbatim with the macOS client (it consumes this repository as `submodules/telegram-ios`),
/// so it must stay free of UIKit / AppKit / TelegramCore and must keep matching `vectors/watermark.json` bit for bit.
public enum WatermarkCodec {
    /// Chips per tile, and therefore per code.
    public static let chips = WatermarkCarrier.tile * WatermarkCarrier.tile

    /// Fixed bits that carry no data; they exist so the decoder can find the phase before decoding.
    public static let pilotBits = 16

    /// Field widths, in bits. Sign-magnitude for the ids, the chat id being negative for groups and channels.
    public static let versionBits = 4
    public static let viewerIdBits = 48
    public static let chatIdBits = 48
    public static let timeBucketBits = 24

    public static let dataBits = versionBits + viewerIdBits + chatIdBits + timeBucketBits

    /// A checksum over the data bits, and it is not a nicety.
    ///
    /// Without it a marginal reading returns *identities* rather than nothing: the sixteen pilot bits lock the phase
    /// long before the data bits are individually reliable, so a crop slightly too small decodes to a well-formed but
    /// wrong account. For a forensic tool, confidently naming an uninvolved person is far worse than saying nothing,
    /// so a failed checksum refuses the reading.
    public static let crcBits = 16

    /// Pilot bits first, then the payload, then its checksum.
    public static let totalBits = pilotBits + dataBits + crcBits

    /// An arbitrary but fixed pattern — anything the decoder and the encoder agree on.
    public static let pilotPattern: [UInt8] = [1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 1]

    public static let version = 2

    /// The identities a screen is carrying. Ids are Telegram's own signed 64-bit ids, narrowed to 48 bits here.
    public struct Fields: Equatable {
        /// the account looking at this screen — the one a leaked screenshot points at
        public let viewerId: Int64
        /// chat id in the shared format: positive for users, negative for groups and channels
        public let chatId: Int64
        /// which time window the screen was being looked at in
        public let timeBucket: Int

        public init(viewerId: Int64, chatId: Int64, timeBucket: Int) {
            self.viewerId = viewerId
            self.chatId = chatId
            self.timeBucket = timeBucket
        }
    }

    public struct Unpacked: Equatable {
        public let version: Int
        public let viewerId: Int64
        public let chatId: Int64
        public let timeBucket: Int
        /// how many pilot bits came out wrong — the decoder's own estimate of whether it is looking at a watermark
        public let pilotErrors: Int
        /// false means the bits did not survive: the fields are garbage and must not be reported
        public let checksumOk: Bool
    }

    public enum WatermarkError: Error, Equatable, CustomStringConvertible {
        case idOutOfRange(Int64)
        case invalidProjectKey
        case badBitCount(Int)

        public var description: String {
            switch self {
            case .idOutOfRange(let value): return "[secutg] watermark id out of range: \(value)"
            case .invalidProjectKey: return "[secutg] watermark project key must be 32 bytes"
            case .badBitCount(let count): return "[secutg] watermark needs \(WatermarkCodec.totalBits) bits, got \(count)"
            }
        }
    }

    /// The 32-byte project key the spreading codes are derived from.
    public static let projectKeyBytes = 32

    // MARK: - Bit packing

    private static func pushBits(_ bits: inout [UInt8], _ value: UInt64, _ width: Int) {
        var i = width - 1
        while i >= 0 {
            bits.append(UInt8((value >> UInt64(i)) & 1))
            i -= 1
        }
    }

    private static func takeBits(_ bits: [UInt8], at: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width {
            value = (value << 1) | UInt64(bits[at + i] != 0 ? 1 : 0)
        }
        return value
    }

    /// Sign-magnitude, so a negative chat id costs one bit rather than a two's-complement convention.
    private static func toSignMagnitude(_ value: Int64, width: Int) throws -> UInt64 {
        let magnitude = value < 0 ? UInt64(value.magnitude) : UInt64(value)
        let limit = UInt64(1) << UInt64(width - 1)
        guard magnitude < limit else { throw WatermarkError.idOutOfRange(value) }
        return (value < 0 ? limit : 0) | magnitude
    }

    private static func fromSignMagnitude(_ raw: UInt64, width: Int) -> Int64 {
        let limit = UInt64(1) << UInt64(width - 1)
        let magnitude = Int64(raw & (limit - 1))
        return (raw & limit) != 0 ? -magnitude : magnitude
    }

    /// CRC-16/CCITT over a run of bits, MSB first (init 0xFFFF, poly 0x1021).
    public static func crc(_ bits: [UInt8], from: Int, to: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for i in from..<to {
            crc ^= UInt16(bits[i] != 0 ? 1 : 0) << 15
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
        }
        return crc
    }

    /// The bits that go on the screen: pilot, then version, viewer, chat, time, then the checksum over the data.
    public static func pack(_ fields: Fields) throws -> [UInt8] {
        var bits = pilotPattern
        bits.reserveCapacity(totalBits)
        pushBits(&bits, UInt64(version), versionBits)
        pushBits(&bits, try toSignMagnitude(fields.viewerId, width: viewerIdBits), viewerIdBits)
        pushBits(&bits, try toSignMagnitude(fields.chatId, width: chatIdBits), chatIdBits)
        // Truncated to its field like every other, matching the reference: the bucket overflows some time in 2289.
        pushBits(&bits, UInt64(bitPattern: Int64(fields.timeBucket)), timeBucketBits)
        pushBits(&bits, UInt64(crc(bits, from: pilotBits, to: bits.count)), crcBits)
        return bits
    }

    /// Reads the fields back. `pilotErrors` and `checksumOk` are what a caller must look at before believing a word
    /// of the rest: a failed checksum means the reading is refused, never reported.
    public static func unpack(_ bits: [UInt8]) throws -> Unpacked {
        guard bits.count >= totalBits else { throw WatermarkError.badBitCount(bits.count) }
        var pilotErrors = 0
        for i in 0..<pilotBits where (bits[i] != 0 ? 1 : 0) != pilotPattern[i] {
            pilotErrors += 1
        }
        var at = pilotBits
        let version = Int(takeBits(bits, at: at, width: versionBits))
        at += versionBits
        let viewerId = fromSignMagnitude(takeBits(bits, at: at, width: viewerIdBits), width: viewerIdBits)
        at += viewerIdBits
        let chatId = fromSignMagnitude(takeBits(bits, at: at, width: chatIdBits), width: chatIdBits)
        at += chatIdBits
        let timeBucket = Int(takeBits(bits, at: at, width: timeBucketBits))
        at += timeBucketBits
        let checksumOk = UInt16(takeBits(bits, at: at, width: crcBits)) == crc(bits, from: pilotBits, to: at)
        return Unpacked(version: version, viewerId: viewerId, chatId: chatId, timeBucket: timeBucket,
                        pilotErrors: pilotErrors, checksumOk: checksumOk)
    }

    // MARK: - Spreading

    /// One spreading code, `chips` of -1 / +1, derived from the project key with a keyed BLAKE2b.
    ///
    /// This is what replaces encrypting the payload: without the key the codes are unknown, so the pattern cannot be
    /// demodulated and the bits are unreadable. Someone who reverse engineers the scheme learns the shape of it and
    /// nothing about anyone.
    public static func spreadingCode(projectKey: [UInt8], index: Int) throws -> [Int8] {
        guard projectKey.count == projectKeyBytes else { throw WatermarkError.invalidProjectKey }
        SecutgSodium.ensureReady()
        var out = [Int8](repeating: 0, count: chips)
        var produced = 0
        var counter = 0
        let blockBytes = 64
        var block = [UInt8](repeating: 0, count: blockBytes)
        while produced < chips {
            var seed = [UInt8](repeating: 0, count: 8)
            seed[0] = UInt8((index >> 8) & 0xFF)
            seed[1] = UInt8(index & 0xFF)
            seed[2] = UInt8((counter >> 8) & 0xFF)
            seed[3] = UInt8(counter & 0xFF)
            // "wm2c", so these codes cannot collide with any other use of the project key
            seed[4] = 0x77; seed[5] = 0x6D; seed[6] = 0x32; seed[7] = 0x63
            guard crypto_generichash(&block, blockBytes, seed, UInt64(seed.count), projectKey, projectKey.count) == 0 else {
                throw SecutgCryptoError.sodiumFailure("generichash failed")
            }
            var byte = 0
            while byte < blockBytes && produced < chips {
                var bit = 0
                while bit < 8 && produced < chips {
                    out[produced] = ((block[byte] >> UInt8(bit)) & 1) != 0 ? 1 : -1
                    produced += 1
                    bit += 1
                }
                byte += 1
            }
            counter += 1
        }
        return out
    }

    /// Every code for one key, built once and reused across tiles and candidates.
    public static func spreadingCodes(projectKey: [UInt8]) throws -> [[Int8]] {
        return try (0..<totalBits).map { try spreadingCode(projectKey: projectKey, index: $0) }
    }

    /// Superimposes the codes and takes the sign.
    ///
    /// Hard limiting costs roughly 2 dB against sending the analogue sum, and buys something worth more: the output
    /// is still two-valued, so the tile, the 2x2 chips and the additive overlay downstream are all unchanged.
    ///
    /// The accumulator is integral — 156 values of ±1 — so a 32-bit integer sum is exactly the Float32 sum the
    /// reference computes, ties at zero included (`>= 0` maps to `+1` in both).
    public static func modulate(bits: [UInt8], codes: [[Int8]]) -> [Int8] {
        var sum = [Int32](repeating: 0, count: chips)
        for bitIndex in 0..<codes.count {
            let sign: Int32 = (bitIndex < bits.count && bits[bitIndex] != 0) ? 1 : -1
            let code = codes[bitIndex]
            for chip in 0..<chips {
                sum[chip] += sign * Int32(code[chip])
            }
        }
        return sum.map { $0 >= 0 ? 1 : -1 }
    }

    /// Correlates the folded residual against each code; the sign of each is that bit.
    public static func demodulate(accumulator: [Float], codes: [[Int8]]) -> (bits: [UInt8], margins: [Float]) {
        var bits = [UInt8](repeating: 0, count: codes.count)
        var margins = [Float](repeating: 0, count: codes.count)
        for bitIndex in 0..<codes.count {
            let code = codes[bitIndex]
            var sum: Float = 0
            for chip in 0..<chips {
                sum += accumulator[chip] * Float(code[chip])
            }
            bits[bitIndex] = sum >= 0 ? 1 : 0
            margins[bitIndex] = abs(sum)
        }
        return (bits, margins)
    }

    /// The whole encode path in one call, which is all a renderer needs: identities in, ±1 chips out.
    public static func carrier(projectKey: [UInt8], fields: Fields) throws -> [Int8] {
        return modulate(bits: try pack(fields), codes: try spreadingCodes(projectKey: projectKey))
    }
}
