import Foundation

/// v1.4 section 19's W2 — the cross-device REMOTE WIPE control signal's cryptographic correctness.
/// Deliberately does NOT perform an actual local wipe — that sequencing is real app/platform storage
/// and UI orchestration this module has no access to; see `V2WipeExecute` for that sequencing. What
/// this file owns: building and signing a W2 event, and a TARGET device verifying one against its OWN
/// independently-stored pre-authorization — never against any key the event itself claims. Ported
/// from `src/secutg/v2/wipe/w2.ts` and `org.telegram.secutg.v2.wipe.W2`.
///
/// v1.4: "W2 remote wipe is off by default, the target device must have pre-authorized some control
/// public key and an allowed scope" — `W2AuthorizationStore` is that pre-authorization, established by
/// some OUT-OF-BAND ceremony this file does not build — this file only ever CONSULTS an
/// already-populated store, it never creates trust from a bare wire message. There is no alternate,
/// weaker authentication path here at all; `handleW2Event` has exactly one: signature verification
/// against the locally-stored controlPublicKey.
public enum V2W2 {
    public static let prefix = "W2"
    public static let domain = "secuTG/v2/W2"

    /// v1.4 section 19: "valid for at most 24 hours" / "allows a 2-minute clock skew tolerance".
    public static let maxValidityMs: Int64 = 24 * 60 * 60 * 1000
    public static let clockSkewMs: Int64 = 2 * 60 * 1000

    public struct Event {
        public let account: String
        public let issuerDevice: String
        public let targetDevices: [String]
        public let eventId: String
        public let issuedAtMs: String
        public let expiresAtMs: String
        public let scope: [String]
    }

    public struct Parsed {
        public let event: Event
        public let sig: [UInt8]
    }

    private static func eventToSJObject(_ event: Event) -> V2SJValue {
        return .object([
            "v": "2", "account": .string(event.account), "issuer_device": .string(event.issuerDevice),
            "target_devices": .array(event.targetDevices.map { .string($0) }), "event_id": .string(event.eventId),
            "issued_at_ms": .string(event.issuedAtMs), "expires_at_ms": .string(event.expiresAtMs),
            "scope": .array(event.scope.map { .string($0) }),
        ])
    }

    private static func signingInput(_ event: Event) -> [UInt8]? {
        guard let canonical = V2SJ.serialize(eventToSJObject(event)) else { return nil }
        return V2Suite.concatBytes(V2Suite.utf8(domain + "\0"), V2Suite.utf8(canonical))
    }

    public struct BuildParams {
        public let account: String
        public let issuerIdentityPk: [UInt8]
        public let issuerIdentitySk: [UInt8]
        public let targetDevices: [String]
        public let scope: [String]
        public let issuedAtMs: Int64
        public let expiresAtMs: Int64

        public init(account: String, issuerIdentityPk: [UInt8], issuerIdentitySk: [UInt8], targetDevices: [String], scope: [String], issuedAtMs: Int64, expiresAtMs: Int64) {
            self.account = account
            self.issuerIdentityPk = issuerIdentityPk
            self.issuerIdentitySk = issuerIdentitySk
            self.targetDevices = targetDevices
            self.scope = scope
            self.issuedAtMs = issuedAtMs
            self.expiresAtMs = expiresAtMs
        }
    }

    /// Builds and signs a W2 event as the ISSUER — a device that already holds the private half of
    /// some target's pre-authorized controlPublicKey. expiresAtMs - issuedAtMs must not exceed
    /// maxValidityMs; callers past that limit get nil, not a silently-clamped shorter window.
    public static func buildW2Event(_ params: BuildParams) -> String? {
        guard params.expiresAtMs - params.issuedAtMs <= maxValidityMs else { return nil }
        guard params.expiresAtMs > params.issuedAtMs else { return nil }
        let event = Event(
            account: params.account, issuerDevice: V2E2.deviceIdOf(params.issuerIdentityPk), targetDevices: params.targetDevices,
            eventId: V2Envelope.randomId(), issuedAtMs: String(params.issuedAtMs), expiresAtMs: String(params.expiresAtMs), scope: params.scope
        )
        guard let input = signingInput(event) else { return nil }
        let sig = V2Suite.sign(secretKey: params.issuerIdentitySk, message: input)
        guard case .object(var fullMap) = eventToSJObject(event) else { return nil }
        fullMap["sig"] = .string(Base64Url.encode(sig))
        guard let canonical = V2SJ.serialize(.object(fullMap)) else { return nil }
        return prefix + ":" + Base64Url.encode(V2Suite.utf8(canonical))
    }

    public static func parseW2(_ wire: String) -> Parsed? {
        guard wire.hasPrefix(prefix + ":") else { return nil }
        guard let bytes = Base64Url.decode(String(wire.dropFirst(prefix.count + 1))) else { return nil }
        guard let json = V2Suite.fromUtf8(bytes) else { return nil }
        guard let value = V2SJ.parse(json), case .object(let obj) = value else { return nil }

        guard case .string("2")? = obj["v"] else { return nil }
        guard case .string(let account)? = obj["account"], !account.isEmpty else { return nil }
        guard case .string(let issuerDevice)? = obj["issuer_device"], isDigestB64(issuerDevice) else { return nil }
        guard case .array(let targetDevicesRaw)? = obj["target_devices"] else { return nil }
        var targetDevices: [String] = []
        for d in targetDevicesRaw {
            guard case .string(let deviceId) = d, isDigestB64(deviceId) else { return nil }
            targetDevices.append(deviceId)
        }
        guard case .string(let eventId)? = obj["event_id"] else { return nil }
        guard case .string(let issuedAtMs)? = obj["issued_at_ms"], issuedAtMs.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        guard case .string(let expiresAtMs)? = obj["expires_at_ms"], expiresAtMs.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        guard case .array(let scopeRaw)? = obj["scope"] else { return nil }
        var scope: [String] = []
        for s in scopeRaw {
            guard case .string(let scopeValue) = s else { return nil }
            scope.append(scopeValue)
        }
        guard case .string(let sigB64)? = obj["sig"] else { return nil }
        guard let sig = Base64Url.decode(sigB64), sig.count == V2Suite.signatureBytes else { return nil }

        return Parsed(event: Event(account: account, issuerDevice: issuerDevice, targetDevices: targetDevices, eventId: eventId, issuedAtMs: issuedAtMs, expiresAtMs: expiresAtMs, scope: scope), sig: sig)
    }

    public static func verifyW2Signature(_ parsed: Parsed, issuerIdentityPk: [UInt8]) -> Bool {
        guard issuerIdentityPk.count == V2Suite.ed25519PkBytes else { return false }
        guard V2E2.deviceIdOf(issuerIdentityPk) == parsed.event.issuerDevice else { return false }
        guard let input = signingInput(parsed.event) else { return false }
        return V2Suite.verify(publicKey: issuerIdentityPk, message: input, signature: parsed.sig)
    }

    private static func isDigestB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Suite.digestBytes
    }

    /// v1.4 section 19: "the target device must have pre-authorized some control public key and an
    /// allowed scope" — established by an out-of-band ceremony this file does not build.
    public struct Authorization: Codable {
        public let account: String
        public let controlPublicKey: String
        public let allowedScope: [String]

        public init(account: String, controlPublicKey: String, allowedScope: [String]) {
            self.account = account
            self.controlPublicKey = controlPublicKey
            self.allowedScope = allowedScope
        }
    }

    public final class W2AuthorizationStore {
        private var byAccount: [String: Authorization] = [:]

        public init() { }

        public func authorize(_ authorization: Authorization) {
            byAccount[authorization.account] = authorization
        }

        /// v1.4: "reinstalling or restoring never automatically rebuilds an old remote-control
        /// authorization" — this is the one and only way an authorization disappears.
        public func revoke(_ account: String) {
            byAccount.removeValue(forKey: account)
        }

        public func get(_ account: String) -> Authorization? {
            return byAccount[account]
        }

        // MARK: persistence (Web integration draft 1/4)

        /// v1.4: "reinstalling or restoring never automatically rebuilds an old remote-control
        /// authorization" — an ordinary reload keeps this (persisted like every other store), but a
        /// genuine reinstall wipes the Keychain/file origin outright and a K2 disaster backup never
        /// carries it, both consistent with that rule — `w2.ts`'s own comment on its identical
        /// `toSnapshot`.
        public struct Snapshot: Codable {
            public var authorizations: [Authorization]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(authorizations: Array(byAccount.values))
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> W2AuthorizationStore {
            let store = W2AuthorizationStore()
            for authorization in snapshot.authorizations { store.authorize(authorization) }
            return store
        }
    }

    /// v1.4 section 16's wipe_tombstone ("issuer + event_id; processed").
    public final class W2DedupStore {
        private var processedIds: Set<String> = []

        public init() { }

        public func alreadyProcessed(_ eventId: String) -> Bool {
            return processedIds.contains(eventId)
        }

        public func markProcessed(_ eventId: String) {
            processedIds.insert(eventId)
        }

        // MARK: persistence (Web integration draft 1/4)

        public struct Snapshot: Codable {
            public var processedIds: [String]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(processedIds: Array(processedIds))
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> W2DedupStore {
            let store = W2DedupStore()
            for id in snapshot.processedIds { store.markProcessed(id) }
            return store
        }
    }

    public struct HandleOutcome {
        public let ok: Bool
        /// "auto_execute": every requested scope was already pre-authorized. "needs_confirmation":
        /// the issuer and signature are genuinely valid, but at least one requested scope exceeds
        /// what was pre-authorized. "already_processed": v1.4 section 16's wipe_tombstone dedup.
        public let kind: String?
        public let scope: [String]?
        public let reason: String?

        static func ok(_ kind: String, scope: [String]) -> HandleOutcome {
            return HandleOutcome(ok: true, kind: kind, scope: scope, reason: nil)
        }

        static func fail(_ reason: String) -> HandleOutcome {
            return HandleOutcome(ok: false, kind: nil, scope: nil, reason: reason)
        }
    }

    /// v1.4 section 19: "the target device verifies against its own independently-stored
    /// authorization public key, checks the target and event validity window, then persists dedup
    /// and executes". Every check happens in that exact order — authorization existence, signature
    /// (against the STORED key, never one the wire itself claims), target membership, validity
    /// window, THEN dedup — so a wire that fails an earlier check is refused before dedup ever marks
    /// it seen.
    public static func handleW2Event(_ wire: String, store: W2AuthorizationStore, dedup: W2DedupStore, thisDeviceId: String, nowMs: Int64) -> HandleOutcome {
        guard let parsed = parseW2(wire) else { return .fail("malformed") }

        guard let authorized = store.get(parsed.event.account) else { return .fail("no_local_authorization") }
        guard let controlPk = Base64Url.decode(authorized.controlPublicKey) else { return .fail("malformed_local_authorization") }
        guard verifyW2Signature(parsed, issuerIdentityPk: controlPk) else { return .fail("bad_signature") }

        guard parsed.event.targetDevices.contains(thisDeviceId) else { return .fail("not_a_target") }

        guard let issuedAtMs = Int64(parsed.event.issuedAtMs), let expiresAtMs = Int64(parsed.event.expiresAtMs) else { return .fail("malformed") }
        guard expiresAtMs - issuedAtMs <= maxValidityMs else { return .fail("validity_too_long") }
        guard nowMs >= issuedAtMs - clockSkewMs else { return .fail("not_yet_valid") }
        guard nowMs <= expiresAtMs + clockSkewMs else { return .fail("expired") }

        if dedup.alreadyProcessed(parsed.event.eventId) {
            return .ok("already_processed", scope: parsed.event.scope)
        }
        dedup.markProcessed(parsed.event.eventId)

        let scopeAuthorized = parsed.event.scope.allSatisfy { authorized.allowedScope.contains($0) }
        return .ok(scopeAuthorized ? "auto_execute" : "needs_confirmation", scope: parsed.event.scope)
    }
}
