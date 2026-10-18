import Foundation

/// PLAN.md 3.39.4 step 6: a binding installed from a V2Q carries its OWN device identity
/// (`V2Binding.ownIdentity`, minted by the showing device for this one chat), and every v2 operation on
/// that binding — E2 signing and `sender_device`, REKEY/UNPAIR envelopes, opening packages, the safety
/// code — must use it instead of the device's global identity. Every other binding keeps the global one.
///
/// One helper, used by `V2Roster`, `V2PrivateChatMessaging`, `V2Processor` and `V2PairingDispatch` alike,
/// so the choice cannot be made differently in two places. Ported from `src/secutg/v2/pairing/ownIdentity.ts`.
public enum V2OwnIdentity {
    /// The identity this device acts under for `binding`: its per-binding one when present, else `fallback`
    /// (the global identity). A per-binding record that fails to decode — which only a corrupt persisted blob
    /// could produce — falls back to the global identity rather than crashing a receive path.
    public static func identity(for binding: V2Binding?, fallback: V2Identity) -> V2Identity {
        guard let own = binding?.ownIdentity,
              let publicKey = Base64Url.decode(own.identityPk), publicKey.count == V2Suite.ed25519PkBytes,
              let secretKey = Base64Url.decode(own.identitySk), secretKey.count == V2Suite.ed25519SkBytes,
              let encapsulationPk = Base64Url.decode(own.encapsulationPk), encapsulationPk.count == V2Suite.x25519PkBytes,
              let encapsulationSk = Base64Url.decode(own.encapsulationSk), encapsulationSk.count == V2Suite.x25519SkBytes
        else { return fallback }
        return V2Identity(userId: fallback.userId, publicKey: publicKey, secretKey: secretKey, encapsulationPk: encapsulationPk, encapsulationSk: encapsulationSk)
    }

    /// `base64url(sha256(identity_pk))` of whichever identity `identity(for:fallback:)` picks — the device id the
    /// binding's roster names this device by.
    public static func ownDeviceId(for binding: V2Binding?, fallback: V2Identity) -> String {
        return binding?.ownIdentity?.deviceId ?? Base64Url.encode(V2Suite.sha256(fallback.publicKey))
    }

    /// The JSON-safe record a V2Q's `new_device` becomes on the scanning device.
    public static func fromKeys(identityPk: [UInt8], identitySk: [UInt8], encapsulationPk: [UInt8], encapsulationSk: [UInt8]) -> V2Binding.OwnIdentity {
        return V2Binding.OwnIdentity(
            deviceId: Base64Url.encode(V2Suite.sha256(identityPk)),
            identityPk: Base64Url.encode(identityPk), identitySk: Base64Url.encode(identitySk),
            encapsulationPk: Base64Url.encode(encapsulationPk), encapsulationSk: Base64Url.encode(encapsulationSk)
        )
    }
}
