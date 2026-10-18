import Clibsodium
import Foundation

/// PLAN.md 3.25.2: a short code every client derives the same way from an X25519 identity public key, so a user
/// can point at "the device holding this key" without the protocol ever naming devices. Not a security code
/// (`Pairing.safetyCode` stays the only thing used to verify a key exchange) — device codes exist purely so two
/// people (or one person's two machines) can read out a short string and agree they mean the same key.
/// Byte-identical to Web A `src/secutg/keyring/device.ts`.
public enum DeviceIdentity {
    static let context = "tg-e1-device-v1"
    private static let pkBytes = 32
    private static let digestBytes = 32
    private static let idBytes = 8
    /// 30 bits = exactly six 5-bit Crockford digits, high bits first
    private static let codeChars = 6
    private static let codeGroup = 3
    private static let codeMask: UInt32 = 0x3FFFFFFF
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let deviceIdRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{16}$")

    /// PLAN.md 3.25.3 `peerSeenDeviceIds`: first-seen order, oldest dropped once full
    public static let maxSeenDeviceIds = 8
    /// PLAN.md 3.25.3 `deviceLabels[...].label`: trimmed, plain text, no markup, at most this many characters
    public static let labelMaxChars = 40

    public struct Identity: Equatable {
        /// 16 lowercase hex chars; the only thing ever persisted (never the public key itself)
        public let deviceId: String
        /// `XXX-XXX`, six Crockford base32 chars derived from the same digest as `deviceId`
        public let deviceCode: String
    }

    /// 16 lowercase hex chars: `blake2b(32, "tg-e1-device-v1" || x25519_pk)[0:8]`
    public static func isValidDeviceId(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return deviceIdRegex.firstMatch(in: value, range: range) != nil
    }

    /// PLAN.md 3.25.2. Both fields come from one unkeyed blake2b digest of the device's X25519 public key:
    /// `deviceId` is its first 8 bytes as hex, `deviceCode` folds the same first 4 bytes into a 30-bit integer and
    /// renders it as six Crockford base32 characters. Deriving both from one digest is what lets `deviceCode(forId:)`
    /// recover the code from a stored `deviceId` alone, without ever keeping the public key around.
    public static func derive(x25519Pk: [UInt8]) throws -> Identity {
        guard x25519Pk.count == pkBytes else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let input = Array(context.utf8) + x25519Pk
        var digest = [UInt8](repeating: 0, count: digestBytes)
        guard crypto_generichash(&digest, digestBytes, input, UInt64(input.count), nil, 0) == 0 else {
            throw SecutgCryptoError.sodiumFailure("generichash failed")
        }
        return Identity(deviceId: Hex.encode(digest[0..<idBytes]), deviceCode: encodeDeviceCode(digest))
    }

    /// Recovers the `XXX-XXX` display code from a stored `device_id` alone: its first 8 hex bytes already contain
    /// the 4 bytes `deviceCode` is built from, so the public key is never needed again once the id has been
    /// derived once.
    public static func deviceCode(forId deviceId: String) -> String? {
        guard isValidDeviceId(deviceId), let bytes = Hex.decode(deviceId) else { return nil }
        return encodeDeviceCode(bytes)
    }

    private static func encodeDeviceCode(_ bytes: [UInt8]) -> String {
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) & codeMask
        var code = ""
        for shift in stride(from: codeChars - 1, through: 0, by: -1) {
            code.append(alphabet[Int((value >> UInt32(shift * 5)) & 0x1F)])
        }
        let split = code.index(code.startIndex, offsetBy: codeGroup)
        return "\(code[code.startIndex..<split])-\(code[split...])"
    }

    /// Appends `deviceId` to a `peerSeenDeviceIds`-style list: first-seen order, no duplicates, oldest dropped once
    /// the list would exceed `maxSeenDeviceIds` (PLAN.md 3.25.3).
    public static func pushSeenDeviceId(_ seen: [String]?, _ deviceId: String) -> [String] {
        var list = seen ?? []
        if list.contains(deviceId) { return list }
        list.append(deviceId)
        return list.count > maxSeenDeviceIds ? Array(list.suffix(maxSeenDeviceIds)) : list
    }

    /// Trims and caps a device label at `labelMaxChars`; an empty result means "no label"
    public static func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(labelMaxChars))
    }
}
