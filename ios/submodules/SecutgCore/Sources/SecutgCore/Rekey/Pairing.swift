import Clibsodium
import Foundation

/// One-to-one auto pairing (PLAN.md 3.7): both peers derive the chat master from an X25519 agreement,
/// so the master itself never travels. Byte-identical to Web A's rekey/pairing.ts.
public enum Pairing {
    static let pairContext = "tg-e1-pair-v1"
    static let safetyContext = "tg-e1-safety-v1"
    private static let pkBytes = 32
    private static let masterBytes = 32
    private static let digestBytes = 32
    private static let safetyDigits = 12

    /// `blake2b(32, "tg-e1-pair-v1" || scalarmult(own_sk, peer_pk) || pk_lo || pk_hi)`
    public static func deriveMaster(ownX25519Sk: [UInt8], ownX25519Pk: [UInt8], peerX25519Pk: [UInt8]) throws -> [UInt8] {
        guard ownX25519Sk.count == pkBytes, ownX25519Pk.count == pkBytes, peerX25519Pk.count == pkBytes else {
            throw SecutgCryptoError.invalidKey
        }
        SecutgSodium.ensureReady()
        var shared = [UInt8](repeating: 0, count: pkBytes)
        guard crypto_scalarmult(&shared, ownX25519Sk, peerX25519Pk) == 0 else {
            throw SecutgCryptoError.sodiumFailure("scalarmult failed")
        }
        let (lo, hi) = sorted(ownX25519Pk, peerX25519Pk)
        return try hash(Array(pairContext.utf8) + shared + lo + hi, count: masterBytes)
    }

    /// Twelve digits both peers read out to each other; identical on both sides.
    public static func safetyCode(_ ownX25519Pk: [UInt8], _ peerX25519Pk: [UInt8]) throws -> String {
        guard ownX25519Pk.count == pkBytes, peerX25519Pk.count == pkBytes else { throw SecutgCryptoError.invalidKey }
        let (lo, hi) = sorted(ownX25519Pk, peerX25519Pk)
        let digest = try hash(Array(safetyContext.utf8) + lo + hi, count: digestBytes)
        let value = digest[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_000_000
        let digits = String(repeating: "0", count: safetyDigits - String(value).count) + String(value)
        let groups = stride(from: 0, to: safetyDigits, by: 4).map { start -> Substring in
            let from = digits.index(digits.startIndex, offsetBy: start)
            return digits[from..<digits.index(from, offsetBy: 4)]
        }
        return groups.joined(separator: " ")
    }

    private static func hash(_ input: [UInt8], count: Int) throws -> [UInt8] {
        SecutgSodium.ensureReady()
        var out = [UInt8](repeating: 0, count: count)
        guard crypto_generichash(&out, count, input, UInt64(input.count), nil, 0) == 0 else {
            throw SecutgCryptoError.sodiumFailure("generichash failed")
        }
        return out
    }

    /// Unsigned lexicographic (memcmp) order from byte 0
    private static func sorted(_ a: [UInt8], _ b: [UInt8]) -> ([UInt8], [UInt8]) {
        for i in 0..<a.count where a[i] != b[i] { return a[i] < b[i] ? (a, b) : (b, a) }
        return (a, b)
    }
}
