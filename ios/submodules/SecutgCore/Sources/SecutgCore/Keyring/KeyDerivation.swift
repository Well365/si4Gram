import Clibsodium
import Foundation

/// PLAN.md 3.3: key_id = <master_id>.<yyyymmdd>, master_id = blake2b(master)[0:8] hex (32-byte digest truncated),
/// session_key = crypto_kdf_derive_from_key(32, yyyymmdd, "tg-e1-kd", master). Labels are UTC and aligned to
/// epoch_days on the Unix day count, exactly like Web A / Android.
public enum KeyDerivation {
    public static let kdfContext = "tg-e1-kd"
    public static let masterKeyBytes = 32
    public static let sessionKeyBytes = 32
    private static let masterIdBytes = 8
    private static let digestBytes = 32
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000
    private static let keyIdRegex = try! NSRegularExpression(pattern: "^([0-9a-f]{16})\\.(\\d{8})$")

    public struct KeyId: Equatable {
        public let masterId: String
        public let label: String
    }

    public static func generateMasterKey() -> [UInt8] {
        return SecutgSodium.randomBytes(masterKeyBytes)
    }

    public static func computeMasterId(_ masterKey: [UInt8]) throws -> String {
        try assertMasterKey(masterKey)
        SecutgSodium.ensureReady()
        var digest = [UInt8](repeating: 0, count: digestBytes)
        guard crypto_generichash(&digest, digestBytes, masterKey, UInt64(masterKey.count), nil, 0) == 0 else {
            throw SecutgCryptoError.sodiumFailure("generichash failed")
        }
        return Hex.encode(digest[0..<masterIdBytes])
    }

    /// PLAN.md 3.8: next day's master of a forward-secrecy chat, `blake2b(32, "tg-e1-ratchet-v1" || master)`
    public static let ratchetContext = "tg-e1-ratchet-v1"
    public static func deriveRatchetNext(_ masterKey: [UInt8]) throws -> [UInt8] {
        try assertMasterKey(masterKey)
        SecutgSodium.ensureReady()
        let input = Array(ratchetContext.utf8) + masterKey
        var out = [UInt8](repeating: 0, count: masterKeyBytes)
        guard crypto_generichash(&out, masterKeyBytes, input, UInt64(input.count), nil, 0) == 0 else {
            throw SecutgCryptoError.sodiumFailure("generichash failed")
        }
        return out
    }

    public static func deriveSessionKey(masterKey: [UInt8], label: String) throws -> [UInt8] {
        try assertMasterKey(masterKey)
        guard let subkeyId = UInt64(label) else { throw SecutgCryptoError.invalidKeyId }
        SecutgSodium.ensureReady()
        var subKey = [UInt8](repeating: 0, count: sessionKeyBytes)
        let context = Array(kdfContext.utf8).map { CChar(bitPattern: $0) }
        guard crypto_kdf_derive_from_key(&subKey, sessionKeyBytes, subkeyId, context, masterKey) == 0 else {
            throw SecutgCryptoError.sodiumFailure("kdf failed")
        }
        return subKey
    }

    public static func toEpochLabel(nowMs: Int64, epochDays: Int) -> String {
        let day = floorDiv(nowMs, dayMs)
        let epochStart = day - floorMod(day, Int64(max(1, epochDays)))
        return formatDay(epochStart)
    }

    /// Unix day index of a yyyymmdd label, or nil when it is not a real date.
    public static func parseEpochLabel(_ label: String) -> Int64? {
        let chars = Array(label.utf8)
        guard chars.count == 8, chars.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let year = Int(label.prefix(4)), let month = Int(label.dropFirst(4).prefix(2)), let day = Int(label.suffix(2)),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }
        return daysFromCivil(year: year, month: month, day: day)
    }

    /// Past is history and stays readable; the future is bounded by the tolerance.
    public static func isLabelAcceptable(_ label: String, nowMs: Int64, epochTolerance: Int) -> Bool {
        guard let labelDay = parseEpochLabel(label) else { return false }
        return labelDay <= floorDiv(nowMs, dayMs) + Int64(epochTolerance)
    }

    public static func buildKeyId(masterId: String, label: String) -> String {
        return "\(masterId).\(label)"
    }

    public static func parseKeyId(_ keyId: String) -> KeyId? {
        guard let match = keyIdRegex.wholeMatch(keyId) else { return nil }
        let groups = match.groups(in: keyId)
        guard groups.count == 2 else { return nil }
        return KeyId(masterId: groups[0], label: groups[1])
    }

    static func assertMasterKey(_ masterKey: [UInt8]) throws {
        guard masterKey.count == masterKeyBytes else { throw SecutgCryptoError.invalidKey }
    }

    // MARK: - Proleptic Gregorian arithmetic (Howard Hinnant), so no Calendar / locale is involved.

    private static func formatDay(_ dayIndex: Int64) -> String {
        let (y, m, d) = civilFromDays(dayIndex)
        return String(format: "%04d%02d%02d", y, m, d)
    }

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int64(era * 146097 + doe - 719468)
    }

    static func civilFromDays(_ z0: Int64) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(m <= 2 ? y + 1 : y), Int(m), Int(d))
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
        return a - floorDiv(a, b) * b
    }
}
