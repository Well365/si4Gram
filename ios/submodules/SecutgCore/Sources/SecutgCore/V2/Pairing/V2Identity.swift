import Foundation

/// This device's P2 identity — an Ed25519 signing keypair plus a long-term X25519 encapsulation
/// keypair (v1.4 section 31/34: "each device keeps an independent Ed25519 identity and X25519
/// encapsulation public key" — INDEPENDENT, not derived from the signing key). Ported from the
/// `Identity` type in `src/secutg/v2/pairing/processor.ts` and `org.telegram.secutg.v2.pairing.Identity`.
///
/// Unused by the five-step exchange itself (which uses a fresh EPHEMERAL X25519 pair per transaction,
/// thrown away once the master is derived) — this is what a ROSTER_COMMIT seals a rotated master to,
/// which needs a key that is still good weeks later, long after any one pairing transcript is gone.
public struct V2Identity {
    public let userId: String
    /// Ed25519 signing keypair — what every P2 envelope is signed with.
    public let publicKey: [UInt8]
    public let secretKey: [UInt8]
    /// X25519, long-term, for sealFor/openSealed.
    public let encapsulationPk: [UInt8]
    public let encapsulationSk: [UInt8]

    public init(userId: String, publicKey: [UInt8], secretKey: [UInt8], encapsulationPk: [UInt8], encapsulationSk: [UInt8]) {
        self.userId = userId
        self.publicKey = publicKey
        self.secretKey = secretKey
        self.encapsulationPk = encapsulationPk
        self.encapsulationSk = encapsulationSk
    }
}
