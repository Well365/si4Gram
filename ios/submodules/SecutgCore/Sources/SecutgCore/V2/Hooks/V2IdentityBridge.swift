import Foundation

/// v1/v2 coexistence decision (Web integration draft, `hooks/identity.ts`'s iOS analog): v2 reuses
/// the SAME on-device cryptographic identity v1's `KeyRing` already owns, rather than generating a
/// second one. `KeyRing.Identity` (`x25519Pk/Sk`, `ed25519Pk/Sk`) and `V2Identity`
/// (`encapsulationPk/Sk`, `publicKey/secretKey`) are structurally the SAME keypairs under different
/// field names — v1.4 section 31's own "each device keeps an independent Ed25519 identity and X25519
/// encapsulation public key" is exactly what `KeyRing.Identity` already is. A device's cryptographic
/// identity is not a protocol-version concept; giving v2 its own would mean managing two identities,
/// two backup/export stories, and two "which one did I show at this pairing" ambiguities for no
/// protocol benefit — every v2 wire format signs with Ed25519 and seals with X25519 exactly like
/// v1's R1/P1/U1 already do.
///
/// This file only converts the SHAPE; it never generates, stores, or persists anything itself —
/// v1's `KeyRing.identity` (surfaced to the runtime layer through `SecutgAccountRuntime`) remains the
/// one source of truth for these bytes.
public enum V2IdentityBridge {
    /// `nil` when v1's own identity has not been established yet (`KeyRing.identity` is `nil`
    /// pre-bootstrap) — v2 has nothing to build from until v1 does.
    public static func identity(userId: String, from stored: KeyRing.Identity?) -> V2Identity? {
        guard let stored = stored else { return nil }
        return V2Identity(
            userId: userId,
            publicKey: stored.ed25519Pk,
            secretKey: stored.ed25519Sk,
            encapsulationPk: stored.x25519Pk,
            encapsulationSk: stored.x25519Sk
        )
    }

    /// This device's own v2 `device_id` (`base64url(sha256(identity_pk))`, the same shape every v2
    /// family uses) — `nil` under the same condition as `identity(userId:from:)`.
    public static func ownDeviceId(from stored: KeyRing.Identity?) -> String? {
        guard let stored = stored else { return nil }
        return Base64Url.encode(V2Suite.sha256(stored.ed25519Pk))
    }
}
