import Foundation

/// PLAN.md review HIGH-2: the hard byte ceilings a relay response must never be allowed to exceed, computed
/// once as pure functions so both the production streaming transport and this file's own tests agree on them.
/// Without these, a malicious — or merely misconfigured — relay a user points secuTG at could make the app
/// buffer an unbounded response and OOM, just by answering any request with more bytes than it should.
public enum RelayCap {
    /// XChaCha20-Poly1305's fixed envelope overhead (PLAN.md 3.48.2): a 24-byte nonce plus a 16-byte Poly1305
    /// tag, prepended/appended around the ciphertext.
    public static let envelopeOverheadBytes = 24 + 16

    /// PLAN.md 3.48.1's absolute plaintext ceiling (`RelayL1.maxBytes`, 20 MiB) plus the envelope overhead —
    /// the most any single `GET /v1/items/{id}` body may ever legitimately be, for ANY reference, even before
    /// that reference's own `n` is known. Used as a sanity clamp on top of the per-item cap below.
    public static let absoluteItemCeilingBytes = RelayL1.maxBytes + envelopeOverheadBytes

    /// `/v1/info` and `/v1/items/{id}/meta` only ever return small, fixed-shape JSON (PLAN.md 3.48.3) — this is
    /// the cap for both, independent of any particular item.
    public static let metadataCapBytes = 16 * 1024

    /// The exact number of bytes a `GET /v1/items/{id}` body must be for a given `L1:` reference: the plaintext
    /// size `n` the reference carries, plus the envelope overhead when the reference has a content key (`k`) —
    /// i.e. the relay is serving the sealed blob, not the plaintext.
    public static func expectedItemBytes(plaintextSize: Int, isEncrypted: Bool) -> Int {
        return plaintextSize + (isEncrypted ? envelopeOverheadBytes : 0)
    }

    /// The cap to enforce for one `GET /v1/items/{id}` fetch: `expectedItemBytes`, clamped to never exceed the
    /// absolute ceiling regardless of what a (locally-parsed, but still untrusted-content-wise) reference claims.
    public static func itemCap(plaintextSize: Int, isEncrypted: Bool) -> Int {
        return min(expectedItemBytes(plaintextSize: plaintextSize, isEncrypted: isEncrypted), absoluteItemCeilingBytes)
    }

    /// Whether a response may proceed given a claimed length known up front (`URLResponse.expectedContentLength`,
    /// which is `-1` when the server didn't say) — an unknown length always passes this check, because it is the
    /// streaming byte counter's job (`exceedsCapSoFar`) to catch that case as bytes actually arrive.
    public static func isAcceptableClaimedLength(_ length: Int64, cap: Int) -> Bool {
        guard length >= 0 else { return true }
        return length <= Int64(cap)
    }

    /// Whether `receivedBytes` accumulated so far already exceeds `cap` — call this as bytes stream in and
    /// cancel the transfer the moment it returns true, never waiting for the body to finish.
    public static func exceedsCapSoFar(receivedBytes: Int, cap: Int) -> Bool {
        return receivedBytes > cap
    }

    /// The final-length check for a completed, in-cap item download: it must be exactly `expectedBytes`, not
    /// merely "at most" — anything shorter is truncated (an encrypted blob would already fail to open on a
    /// short read, but an unencrypted one would not notice at all without this), and anything longer would
    /// already have tripped `exceedsCapSoFar` during the transfer.
    public static func isExactLength(_ actualBytes: Int, expectedBytes: Int) -> Bool {
        return actualBytes == expectedBytes
    }
}
