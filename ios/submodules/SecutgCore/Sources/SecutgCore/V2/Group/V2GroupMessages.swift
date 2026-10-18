import Foundation

/// N2 group event shapes (v1.4 section 13's event table): GENESIS / JOIN_REQUEST / PERMIT / WELCOME
/// (G-01-G-05) plus COMMIT (G-06-G-17, admin rekey). Ported from `src/secutg/v2/group/messages.ts`
/// and `org.telegram.secutg.v2.group.GroupMessages`.
public enum V2GroupMessages {
    public static let prefix = "N2"
    public static let domain = "secuTG/v2/N2"

    public struct AdminAclEntry {
        public let deviceId: String
        public let identityPk: String
        public let encapsulationPk: String

        public init(deviceId: String, identityPk: String, encapsulationPk: String) {
            self.deviceId = deviceId
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }
    }

    public struct NewDevice {
        public let deviceId: String
        public let identityPk: String
        public let encapsulationPk: String

        public init(deviceId: String, identityPk: String, encapsulationPk: String) {
            self.deviceId = deviceId
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }
    }

    /// v1.4 section 13's GENESIS row. adminAcl entries carry encapsulationPk too, beyond what the
    /// row names — without it, no OTHER admin who did not personally onboard the founder would ever
    /// learn what key to seal the founder's own device's package to.
    public struct GenesisBody {
        public let genesisId: String
        public let mode: V2GroupState.Mode
        public let adminAcl: [AdminAclEntry]
        public let keyCommitment: String

        public init(genesisId: String, mode: V2GroupState.Mode, adminAcl: [AdminAclEntry], keyCommitment: String) {
            self.genesisId = genesisId
            self.mode = mode
            self.adminAcl = adminAcl
            self.keyCommitment = keyCommitment
        }
    }

    /// v1.4 section 13's COMMIT row. reason is behaviorally meaningful: rotate/rebuild carry the
    /// parent's roster/admin_acl/mode forward UNCHANGED; add_device/remove_device change
    /// deviceRoster by exactly one device; switch_mode changes ONLY mode. master is present ONLY for
    /// an auto-mode group (v1.4 D7).
    public struct CommitBody {
        public let parentHash: String
        public let epoch: String
        public let mode: V2GroupState.Mode
        public let adminAcl: [AdminAclEntry]
        public let deviceRoster: [String]
        public let keyCommitment: String
        public let reason: String // "rotate" | "rebuild" | "add_device" | "remove_device" | "switch_mode"
        public let master: String?
        public let newDevice: NewDevice?

        public init(parentHash: String, epoch: String, mode: V2GroupState.Mode, adminAcl: [AdminAclEntry], deviceRoster: [String], keyCommitment: String, reason: String, master: String?, newDevice: NewDevice?) {
            self.parentHash = parentHash
            self.epoch = epoch
            self.mode = mode
            self.adminAcl = adminAcl
            self.deviceRoster = deviceRoster
            self.keyCommitment = keyCommitment
            self.reason = reason
            self.master = master
            self.newDevice = newDevice
        }
    }

    public struct JoinRequestBody {
        public let stateHash: String
        public let identityPk: String
        public let encapsulationPk: String
        public let requestNonce: String

        public init(stateHash: String, identityPk: String, encapsulationPk: String, requestNonce: String) {
            self.stateHash = stateHash
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
            self.requestNonce = requestNonce
        }
    }

    public struct PermitBody {
        public let stateHash: String
        public let recipientUser: String
        public let deviceId: String
        public let signPk: String
        public let rights: String // always "read_write"
        public let permitId: String

        public init(stateHash: String, recipientUser: String, deviceId: String, signPk: String, rights: String, permitId: String) {
            self.stateHash = stateHash
            self.recipientUser = recipientUser
            self.deviceId = deviceId
            self.signPk = signPk
            self.rights = rights
            self.permitId = permitId
        }
    }

    /// v1.4 section 13's WELCOME row: sealed = base64url(crypto_box_seal(recipient's
    /// encapsulation_pk, master)). stateHash/permitHash/recipientDevice all sit inside the SIGNED
    /// outer envelope on purpose — a sealed box has no AAD, so they ride the signed envelope instead,
    /// checked one by one after opening.
    public struct WelcomeBody {
        public let stateHash: String
        public let permitHash: String
        public let recipientDevice: String
        public let sealed: String

        public init(stateHash: String, permitHash: String, recipientDevice: String, sealed: String) {
            self.stateHash = stateHash
            self.permitHash = permitHash
            self.recipientDevice = recipientDevice
            self.sealed = sealed
        }
    }

    public struct EnvelopeParams {
        public let eventId: String
        public let groupId: String
        public let actorUser: String
        public let actorIdentityPk: [UInt8]
        public let actorIdentitySk: [UInt8]
        public let createdMs: String
        public let expiresMs: String

        public init(eventId: String, groupId: String, actorUser: String, actorIdentityPk: [UInt8], actorIdentitySk: [UInt8], createdMs: String, expiresMs: String) {
            self.eventId = eventId
            self.groupId = groupId
            self.actorUser = actorUser
            self.actorIdentityPk = actorIdentityPk
            self.actorIdentitySk = actorIdentitySk
            self.createdMs = createdMs
            self.expiresMs = expiresMs
        }
    }

    private static func buildTyped(type: String, params: EnvelopeParams, body: V2SJValue) -> String? {
        let envelope = V2Envelope(
            type: type, eventId: params.eventId, txnId: nil, chatId: params.groupId, actorUser: params.actorUser,
            actorDevice: Base64Url.encode(V2Suite.sha256(params.actorIdentityPk)), parentBinding: nil,
            createdMs: params.createdMs, expiresMs: params.expiresMs, body: body, sig: nil
        )
        return V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: params.actorIdentitySk)
    }

    private static func buildAdminAcl(_ adminAcl: [AdminAclEntry]) -> V2SJValue {
        return .array(adminAcl.map { .object(["device_id": .string($0.deviceId), "identity_pk": .string($0.identityPk), "encapsulation_pk": .string($0.encapsulationPk)]) })
    }

    private static func modeText(_ mode: V2GroupState.Mode) -> String {
        return mode == .auto ? "auto" : "manual"
    }

    private static func parseMode(_ raw: V2SJValue?) -> V2GroupState.Mode? {
        if case .string("auto")? = raw { return .auto }
        if case .string("manual")? = raw { return .manual }
        return nil
    }

    // MARK: build

    public static func buildGenesis(_ params: EnvelopeParams, _ body: GenesisBody) -> String? {
        let m: V2SJValue = .object([
            "genesis_id": .string(body.genesisId), "mode": .string(modeText(body.mode)), "admin_acl": buildAdminAcl(body.adminAcl),
            "key_commitment": .string(body.keyCommitment),
        ])
        return buildTyped(type: "GENESIS", params: params, body: m)
    }

    public static func buildCommit(_ params: EnvelopeParams, _ body: CommitBody) -> String? {
        var m: [String: V2SJValue] = [
            "parent_hash": .string(body.parentHash), "epoch": .string(body.epoch), "mode": .string(modeText(body.mode)),
            "admin_acl": buildAdminAcl(body.adminAcl), "device_roster": .array(body.deviceRoster.map { .string($0) }),
            "key_commitment": .string(body.keyCommitment), "reason": .string(body.reason),
        ]
        if let master = body.master { m["master"] = .string(master) }
        if let newDevice = body.newDevice {
            m["new_device"] = .object(["device_id": .string(newDevice.deviceId), "identity_pk": .string(newDevice.identityPk), "encapsulation_pk": .string(newDevice.encapsulationPk)])
        }
        return buildTyped(type: "COMMIT", params: params, body: .object(m))
    }

    public static func buildJoinRequest(_ params: EnvelopeParams, _ body: JoinRequestBody) -> String? {
        let m: V2SJValue = .object([
            "state_hash": .string(body.stateHash), "identity_pk": .string(body.identityPk),
            "encapsulation_pk": .string(body.encapsulationPk), "request_nonce": .string(body.requestNonce),
        ])
        return buildTyped(type: "JOIN_REQUEST", params: params, body: m)
    }

    public static func buildPermit(_ params: EnvelopeParams, _ body: PermitBody) -> String? {
        let m: V2SJValue = .object([
            "state_hash": .string(body.stateHash), "recipient_user": .string(body.recipientUser), "device_id": .string(body.deviceId),
            "sign_pk": .string(body.signPk), "rights": .string(body.rights), "permit_id": .string(body.permitId),
        ])
        return buildTyped(type: "PERMIT", params: params, body: m)
    }

    public static func buildWelcome(_ params: EnvelopeParams, _ body: WelcomeBody) -> String? {
        let m: V2SJValue = .object([
            "state_hash": .string(body.stateHash), "permit_hash": .string(body.permitHash),
            "recipient_device": .string(body.recipientDevice), "sealed": .string(body.sealed),
        ])
        return buildTyped(type: "WELCOME", params: params, body: m)
    }

    /// SHA256(UTF8(wire text)) — v1.4 section 13's state_hash/permit_hash.
    public static func hashWire(_ wire: String) -> [UInt8] {
        return V2Suite.sha256(V2Suite.utf8(wire))
    }

    // MARK: parse

    public struct Parsed<TBody> {
        public let envelope: V2Envelope
        public let body: TBody
    }

    private static func bodyOf(_ envelope: V2Envelope?, expectedType: String) -> [String: V2SJValue]? {
        guard let envelope = envelope, envelope.type == expectedType else { return nil }
        guard case .object(let obj) = envelope.body else { return nil }
        return obj
    }

    private static func parseAdminAcl(_ raw: V2SJValue?) -> [AdminAclEntry]? {
        guard case .array(let list)? = raw, !list.isEmpty else { return nil }
        var out: [AdminAclEntry] = []
        for entry in list {
            guard case .object(let entryObj) = entry,
                  case .string(let deviceId)? = entryObj["device_id"], isDigestB64(deviceId),
                  case .string(let identityPk)? = entryObj["identity_pk"], isEd25519PkB64(identityPk),
                  case .string(let encapsulationPk)? = entryObj["encapsulation_pk"], isX25519PkB64(encapsulationPk)
            else { return nil }
            out.append(AdminAclEntry(deviceId: deviceId, identityPk: identityPk, encapsulationPk: encapsulationPk))
        }
        return out
    }

    private static func parseDeviceRoster(_ raw: V2SJValue?) -> [String]? {
        guard case .array(let list)? = raw else { return nil }
        var out: [String] = []
        for d in list {
            guard case .string(let deviceId) = d, isDigestB64(deviceId) else { return nil }
            out.append(deviceId)
        }
        return out
    }

    public static func parseGenesis(_ wire: String) -> Parsed<GenesisBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "GENESIS") else { return nil }
        guard case .string(let genesisId)? = b["genesis_id"], isDigestB64(genesisId),
              let mode = parseMode(b["mode"]),
              case .string(let keyCommitment)? = b["key_commitment"], isDigestB64(keyCommitment),
              let adminAcl = parseAdminAcl(b["admin_acl"])
        else { return nil }
        return Parsed(envelope: envelope!, body: GenesisBody(genesisId: genesisId, mode: mode, adminAcl: adminAcl, keyCommitment: keyCommitment))
    }

    private static func isEpochOneOrMore(_ text: String) -> Bool {
        return text.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil // COMMIT's epoch is always parent+1, never 0
    }

    public static func parseCommit(_ wire: String) -> Parsed<CommitBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "COMMIT") else { return nil }
        guard case .string(let parentHash)? = b["parent_hash"], isDigestB64(parentHash),
              case .string(let epoch)? = b["epoch"], isEpochOneOrMore(epoch),
              let mode = parseMode(b["mode"]),
              case .string(let keyCommitment)? = b["key_commitment"], isDigestB64(keyCommitment),
              case .string(let reason)? = b["reason"],
              reason == "rotate" || reason == "rebuild" || reason == "add_device" || reason == "remove_device" || reason == "switch_mode"
        else { return nil }
        guard let adminAcl = parseAdminAcl(b["admin_acl"]), let deviceRoster = parseDeviceRoster(b["device_roster"]) else { return nil }

        var master: String? = nil
        if let masterValue = b["master"] {
            guard case .string(let m) = masterValue, isDigestB64(m) else { return nil }
            master = m
        }

        var newDevice: NewDevice? = nil
        let newDeviceRaw = b["new_device"]
        if reason == "add_device" {
            guard case .object(let nd)? = newDeviceRaw,
                  case .string(let deviceId)? = nd["device_id"], isDigestB64(deviceId),
                  case .string(let identityPk)? = nd["identity_pk"], isEd25519PkB64(identityPk),
                  case .string(let encapsulationPk)? = nd["encapsulation_pk"], isX25519PkB64(encapsulationPk)
            else { return nil }
            newDevice = NewDevice(deviceId: deviceId, identityPk: identityPk, encapsulationPk: encapsulationPk)
        } else if newDeviceRaw != nil {
            return nil // any OTHER reason introduces no new device — a stray new_device is malformed, not ignored
        }

        return Parsed(envelope: envelope!, body: CommitBody(parentHash: parentHash, epoch: epoch, mode: mode, adminAcl: adminAcl, deviceRoster: deviceRoster, keyCommitment: keyCommitment, reason: reason, master: master, newDevice: newDevice))
    }

    public static func parseJoinRequest(_ wire: String) -> Parsed<JoinRequestBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "JOIN_REQUEST") else { return nil }
        guard case .string(let stateHash)? = b["state_hash"], isDigestB64(stateHash),
              case .string(let identityPk)? = b["identity_pk"], isEd25519PkB64(identityPk),
              case .string(let encapsulationPk)? = b["encapsulation_pk"], isX25519PkB64(encapsulationPk),
              case .string(let requestNonce)? = b["request_nonce"], isDigestB64(requestNonce)
        else { return nil }
        return Parsed(envelope: envelope!, body: JoinRequestBody(stateHash: stateHash, identityPk: identityPk, encapsulationPk: encapsulationPk, requestNonce: requestNonce))
    }

    public static func parsePermit(_ wire: String) -> Parsed<PermitBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "PERMIT") else { return nil }
        guard case .string(let stateHash)? = b["state_hash"], isDigestB64(stateHash),
              case .string(let recipientUser)? = b["recipient_user"], !recipientUser.isEmpty,
              case .string(let deviceId)? = b["device_id"], isDigestB64(deviceId),
              case .string(let signPk)? = b["sign_pk"], isEd25519PkB64(signPk),
              case .string(let rights)? = b["rights"], rights == "read_write",
              case .string(let permitId)? = b["permit_id"], isDigestB64(permitId)
        else { return nil }
        return Parsed(envelope: envelope!, body: PermitBody(stateHash: stateHash, recipientUser: recipientUser, deviceId: deviceId, signPk: signPk, rights: rights, permitId: permitId))
    }

    public static func parseWelcome(_ wire: String) -> Parsed<WelcomeBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "WELCOME") else { return nil }
        guard case .string(let stateHash)? = b["state_hash"], isDigestB64(stateHash),
              case .string(let permitHash)? = b["permit_hash"], isDigestB64(permitHash),
              case .string(let recipientDevice)? = b["recipient_device"], isDigestB64(recipientDevice),
              case .string(let sealed)? = b["sealed"], !sealed.isEmpty
        else { return nil }
        return Parsed(envelope: envelope!, body: WelcomeBody(stateHash: stateHash, permitHash: permitHash, recipientDevice: recipientDevice, sealed: sealed))
    }

    public static func verifyTyped(_ envelope: V2Envelope, identityPkB64: String) -> Bool {
        guard let pk = Base64Url.decode(identityPkB64), pk.count == V2Suite.ed25519PkBytes else { return false }
        return V2Envelope.verify(domain: domain, envelope: envelope, actorPublicKey: pk)
    }

    private static func isDigestB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == 32
    }

    private static func isEd25519PkB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Suite.ed25519PkBytes
    }

    private static func isX25519PkB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Suite.x25519PkBytes
    }
}
