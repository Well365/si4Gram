import Foundation

/// PLAN.md 3.39.13's V2Q plaintext — the JSON inside the AEAD — and the ONE place its exact wire shape lives: fixed
/// field order, no extra fields, no whitespace, plain JSON (not SJ: a payload for one scanner, not a signed envelope).
/// Same compaction rules as 3.39.12 (derivable fields never travel). Mirrors Web A `src/secutg/v2/join/payload.ts`.
///
///   { "v":2, "kind":"v2clone", "peer_user_id", "binding_id", "epoch", "safety_code",
///     "roster":[[identity_pk, encapsulation_pk]…],     // ascending device_id = base64url(sha256(identity_pk)), derived
///     "masters":[m_e, m_(e-1), …],                     // positional: masters[i] is generation e - i
///     "own":{"identity_seed","encapsulation_sk"},       // the showing device's OWN keys for this binding; pks derived
///     "expires_ms" }
///
/// "Clone" mode (3.39.13, replacing 3.39.1–3.39.12's add_device): the scanning device becomes the showing device in
/// this one chat — same device identity, same keys, same safety code. No commit, no epoch change, nothing for the
/// peer to see. `own` = the identity the showing device actually acts under for the binding (its per-binding one
/// when it has one, its global one otherwise); its derived device id MUST be one of `roster`, or the code is
/// `malformed`.
public enum V2JoinPayload {
    public static let version: Int64 = 2
    public static let kind = "v2clone"
    /// 3.39.12's format — a code from a device that has not been updated (`old_version`).
    public static let legacyVersion: Int64 = 1
    public static let legacyKind = "v2join"

    public struct RosterEntry: Equatable {
        /// derived: `base64url(sha256(identityPk))` — never carried, so it can never lie about its key
        public let deviceId: String
        public let identityPk: String
        public let encapsulationPk: String

        public init(identityPk: String, encapsulationPk: String) {
            self.deviceId = RosterEntry.deviceId(identityPkB64: identityPk)
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }

        static func deviceId(identityPkB64: String) -> String {
            return Base64Url.encode(V2Suite.sha256(Base64Url.decode(identityPkB64) ?? []))
        }
    }

    /// The device identity the code hands over: two 32-byte secrets. Everything else about it (both public keys, the
    /// device id, libsodium's 64-byte signing key) is derived — `keys()`.
    public struct Own: Equatable {
        /// base64url, 32 bytes — the Ed25519 seed (`V2Suite.ed25519KeyPair(seed:)` gives the pair back)
        public let identitySeed: String
        /// base64url, 32 bytes — the X25519 secret (`V2Suite.x25519PublicKey(secretKey:)` gives its public key)
        public let encapsulationSk: String

        public init(identitySeed: String, encapsulationSk: String) {
            self.identitySeed = identitySeed
            self.encapsulationSk = encapsulationSk
        }

        public struct Keys: Equatable {
            public let deviceId: String
            public let identityPk: [UInt8]
            public let identitySk: [UInt8]
            public let encapsulationPk: [UInt8]
            public let encapsulationSk: [UInt8]
        }

        /// nil only for a seed/secret that is not 32 bytes — which `parse` already refuses.
        public func keys() -> Keys? {
            guard let seed = Base64Url.decode(identitySeed), let signing = V2Suite.ed25519KeyPair(seed: seed),
                  let sk = Base64Url.decode(encapsulationSk), let pk = V2Suite.x25519PublicKey(secretKey: sk) else { return nil }
            return Keys(deviceId: Base64Url.encode(V2Suite.sha256(signing.publicKey)), identityPk: signing.publicKey, identitySk: signing.secretKey, encapsulationPk: pk, encapsulationSk: sk)
        }
    }

    public struct Payload: Equatable {
        public let peerUserId: String
        public let bindingId: String
        public let epoch: Int
        public let safetyCode: String
        public let roster: [RosterEntry]
        /// `masters[0]` is generation `epoch`'s master, `masters[i]` generation `epoch - i`'s — base64url, 32 bytes each
        public let masters: [String]
        public let own: Own
        public let expiresMs: Int64

        public init(peerUserId: String, bindingId: String, epoch: Int, safetyCode: String, roster: [RosterEntry], masters: [String], own: Own, expiresMs: Int64) {
            self.peerUserId = peerUserId
            self.bindingId = bindingId
            self.epoch = epoch
            self.safetyCode = safetyCode
            self.roster = roster
            self.masters = masters
            self.own = own
            self.expiresMs = expiresMs
        }

        /// The generation `masters[index]` belongs to.
        public func epochOfMaster(at index: Int) -> Int {
            return epoch - index
        }
    }

    private static let topKeys = ["v", "kind", "peer_user_id", "binding_id", "epoch", "safety_code", "roster", "masters", "own", "expires_ms"]
    private static let ownKeys = ["identity_seed", "encapsulation_sk"]

    // MARK: serialize

    /// The exact bytes that go into the AEAD: the object in the fixed order, no whitespace (`JSON.stringify` of an
    /// object literal on Web).
    public static func serialize(_ p: Payload) -> String {
        let value: V2JoinJSON = .object([
            .init("v", .int(version)),
            .init("kind", .string(kind)),
            .init("peer_user_id", .string(p.peerUserId)),
            .init("binding_id", .string(p.bindingId)),
            .init("epoch", .int(Int64(p.epoch))),
            .init("safety_code", .string(p.safetyCode)),
            .init("roster", .array(p.roster.map { .array([.string($0.identityPk), .string($0.encapsulationPk)]) })),
            .init("masters", .array(p.masters.map { .string($0) })),
            .init("own", .object([
                .init("identity_seed", .string(p.own.identitySeed)),
                .init("encapsulation_sk", .string(p.own.encapsulationSk)),
            ])),
            .init("expires_ms", .int(p.expiresMs)),
        ])
        return V2JoinJSON.serialize(value)
    }

    // MARK: parse

    public enum ParseResult: Equatable {
        case ok(Payload)
        /// a 3.39.12 `v2join` payload (`v:1`) — the showing device must be updated
        case oldVersion
        case malformed
    }

    private static func b64(_ value: V2JoinJSON?, bytes: Int) -> String? {
        guard let text = value?.stringValue, let decoded = Base64Url.decode(text), decoded.count == bytes else { return nil }
        return text
    }

    private static func positiveInt(_ value: V2JoinJSON?) -> Int? {
        guard let n = value?.intValue, n >= 1, n <= Int64(Int.max) else { return nil }
        return Int(n)
    }

    /// At least two devices (the showing one and the peer), each `[identity_pk, encapsulation_pk]`, their derived ids
    /// strictly ascending — the canonical order, and what makes them unique.
    private static func parseRoster(_ raw: V2JoinJSON?) -> [RosterEntry]? {
        guard let items = raw?.arrayValue, items.count >= 2 else { return nil }
        var out: [RosterEntry] = []
        for entry in items {
            guard let pair = entry.arrayValue, pair.count == 2,
                  let identityPk = b64(pair[0], bytes: V2Suite.ed25519PkBytes),
                  let encapsulationPk = b64(pair[1], bytes: V2Suite.x25519PkBytes) else { return nil }
            let next = RosterEntry(identityPk: identityPk, encapsulationPk: encapsulationPk)
            if let last = out.last, next.deviceId <= last.deviceId { return nil }
            out.append(next)
        }
        return out
    }

    /// `masters[0]` is the current generation; there can be no more entries than generations (`epoch` of them).
    private static func parseMasters(_ raw: V2JoinJSON?, currentEpoch: Int) -> [String]? {
        guard let items = raw?.arrayValue, !items.isEmpty, items.count <= currentEpoch else { return nil }
        var out: [String] = []
        for entry in items {
            guard let master = b64(entry, bytes: 32) else { return nil }
            out.append(master)
        }
        return out
    }

    private static func parseOwn(_ raw: V2JoinJSON?) -> Own? {
        guard let raw = raw, raw.hasKeysInOrder(ownKeys),
              let identitySeed = b64(raw["identity_seed"], bytes: V2Suite.ed25519SeedBytes),
              let encapsulationSk = b64(raw["encapsulation_sk"], bytes: V2Suite.x25519SkBytes) else { return nil }
        return Own(identitySeed: identitySeed, encapsulationSk: encapsulationSk)
    }

    /// Whether a decrypted plaintext is a 3.39.12 code: any JSON object that says `v:1` or `kind:"v2join"`.
    static func isLegacy(_ value: V2JoinJSON) -> Bool {
        return value["v"]?.intValue == legacyVersion || value["kind"]?.stringValue == legacyKind
    }

    /// Structural parse of the decrypted plaintext: shape, field order, types, lengths, and the one internal
    /// consistency rule — `own`'s derived device, with BOTH its keys, is a member of `roster`.
    public static func parse(_ text: String) -> ParseResult {
        guard let value = V2JoinJSON.parse(text), value.members != nil else { return .malformed }
        if isLegacy(value) { return .oldVersion }
        guard value.hasKeysInOrder(topKeys) else { return .malformed }
        guard value["v"]?.intValue == version, value["kind"]?.stringValue == kind else { return .malformed }
        guard let peerUserId = value["peer_user_id"]?.stringValue, !peerUserId.isEmpty else { return .malformed }
        guard let bindingId = b64(value["binding_id"], bytes: V2Suite.digestBytes), let epoch = positiveInt(value["epoch"]),
              let safetyCode = value["safety_code"]?.stringValue else { return .malformed }
        guard let expiresMs = value["expires_ms"]?.intValue, expiresMs >= 0 else { return .malformed }
        guard let roster = parseRoster(value["roster"]) else { return .malformed }
        guard let masters = parseMasters(value["masters"], currentEpoch: epoch) else { return .malformed }
        guard let own = parseOwn(value["own"]), let ownKeys = own.keys() else { return .malformed }
        guard let entry = roster.first(where: { $0.deviceId == ownKeys.deviceId }),
              entry.encapsulationPk == Base64Url.encode(ownKeys.encapsulationPk) else { return .malformed }
        return .ok(Payload(peerUserId: peerUserId, bindingId: bindingId, epoch: epoch, safetyCode: safetyCode, roster: roster, masters: masters, own: own, expiresMs: expiresMs))
    }
}
