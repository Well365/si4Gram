import Foundation

/// P2 message shapes (v1.4 section 7's body table): pure build/parse for each of the ten message
/// types, wrapping the generic `V2Envelope` layer. Stateless and side-effect-free — the multi-step
/// exchange lives in `V2Processor`. Ported from `src/secutg/v2/pairing/messages.ts` and
/// `org.telegram.secutg.v2.pairing.Messages`.
public enum V2Messages {
    public static let prefix = "P2"
    public static let domain = "secuTG/v2/P2"

    // MARK: body shapes

    public struct InviteBody {
        public let intent: String // "new" | "replace"
        public let identityPk: String
        public let ephemeralPk: String
        public let encapsulationPk: String
        public let targetUser: String
        public let challenge: String

        public init(intent: String, identityPk: String, ephemeralPk: String, encapsulationPk: String, targetUser: String, challenge: String) {
            self.intent = intent
            self.identityPk = identityPk
            self.ephemeralPk = ephemeralPk
            self.encapsulationPk = encapsulationPk
            self.targetUser = targetUser
            self.challenge = challenge
        }
    }

    public struct AcceptBody {
        public let inviteHash: String
        public let identityPk: String
        public let ephemeralPk: String
        public let encapsulationPk: String
        public let challenge: String

        public init(inviteHash: String, identityPk: String, ephemeralPk: String, encapsulationPk: String, challenge: String) {
            self.inviteHash = inviteHash
            self.identityPk = identityPk
            self.ephemeralPk = ephemeralPk
            self.encapsulationPk = encapsulationPk
            self.challenge = challenge
        }
    }

    public struct SelectBody {
        public let inviteHash: String
        public let acceptHash: String
        public let transcriptHash: String
        public let macA: String

        public init(inviteHash: String, acceptHash: String, transcriptHash: String, macA: String) {
            self.inviteHash = inviteHash
            self.acceptHash = acceptHash
            self.transcriptHash = transcriptHash
            self.macA = macA
        }
    }

    public struct ConfirmBody {
        public let selectHash: String
        public let transcriptHash: String
        public let macB: String

        public init(selectHash: String, transcriptHash: String, macB: String) {
            self.selectHash = selectHash
            self.transcriptHash = transcriptHash
            self.macB = macB
        }
    }

    public struct ReadyBody {
        public let selectHash: String
        public let transcriptHash: String
        public let macReady: String

        public init(selectHash: String, transcriptHash: String, macReady: String) {
            self.selectHash = selectHash
            self.transcriptHash = transcriptHash
            self.macReady = macReady
        }
    }

    public struct MergeBody {
        public let inviteHashA: String
        public let inviteHashB: String
        public let mainTxnId: String

        public init(inviteHashA: String, inviteHashB: String, mainTxnId: String) {
            self.inviteHashA = inviteHashA
            self.inviteHashB = inviteHashB
            self.mainTxnId = mainTxnId
        }
    }

    public struct BusyBody {
        public let mainTxnId: String
        public let reason: String

        public init(mainTxnId: String, reason: String) {
            self.mainTxnId = mainTxnId
            self.reason = reason
        }
    }

    public struct CancelBody {
        public let targetTxnId: String
        public let reason: String

        public init(targetTxnId: String, reason: String) {
            self.targetTxnId = targetTxnId
            self.reason = reason
        }
    }

    public struct UnpairBody {
        public let bindingId: String

        public init(bindingId: String) {
            self.bindingId = bindingId
        }
    }

    public struct DevicePackage {
        public let deviceId: String
        public let pkg: String

        public init(deviceId: String, pkg: String) {
            self.deviceId = deviceId
            self.pkg = pkg
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

    public struct RosterCommitBody {
        public let reason: String // "rekey" | "add_device" | "remove_device"
        public let bindingId: String
        public let epoch: String
        public let deviceRoster: [String]
        public let packages: [DevicePackage]
        /// ADD_DEVICE only; nil for rekey/remove_device.
        public let newDevice: NewDevice?

        public init(reason: String, bindingId: String, epoch: String, deviceRoster: [String], packages: [DevicePackage], newDevice: NewDevice?) {
            self.reason = reason
            self.bindingId = bindingId
            self.epoch = epoch
            self.deviceRoster = deviceRoster
            self.packages = packages
            self.newDevice = newDevice
        }
    }

    public struct EnvelopeParams {
        public let eventId: String
        public let txnId: String?
        public let chatId: String
        public let actorUser: String
        public let actorIdentityPk: [UInt8]
        public let actorIdentitySk: [UInt8]
        public let parentBinding: String?
        public let createdMs: String
        public let expiresMs: String

        public init(
            eventId: String, txnId: String?, chatId: String, actorUser: String, actorIdentityPk: [UInt8],
            actorIdentitySk: [UInt8], parentBinding: String?, createdMs: String, expiresMs: String
        ) {
            self.eventId = eventId
            self.txnId = txnId
            self.chatId = chatId
            self.actorUser = actorUser
            self.actorIdentityPk = actorIdentityPk
            self.actorIdentitySk = actorIdentitySk
            self.parentBinding = parentBinding
            self.createdMs = createdMs
            self.expiresMs = expiresMs
        }
    }

    private static func buildTyped(type: String, params: EnvelopeParams, body: V2SJValue) -> String? {
        let envelope = V2Envelope(
            type: type, eventId: params.eventId, txnId: params.txnId, chatId: params.chatId, actorUser: params.actorUser,
            actorDevice: Base64Url.encode(V2Suite.sha256(params.actorIdentityPk)), parentBinding: params.parentBinding,
            createdMs: params.createdMs, expiresMs: params.expiresMs, body: body, sig: nil
        )
        return V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: params.actorIdentitySk)
    }

    // MARK: build

    public static func buildInvite(_ params: EnvelopeParams, _ body: InviteBody) -> String? {
        let m: V2SJValue = .object([
            "intent": .string(body.intent), "identity_pk": .string(body.identityPk), "ephemeral_pk": .string(body.ephemeralPk),
            "encapsulation_pk": .string(body.encapsulationPk), "target_user": .string(body.targetUser), "challenge": .string(body.challenge),
        ])
        return buildTyped(type: "INVITE", params: params, body: m)
    }

    public static func buildAccept(_ params: EnvelopeParams, _ body: AcceptBody) -> String? {
        let m: V2SJValue = .object([
            "invite_hash": .string(body.inviteHash), "identity_pk": .string(body.identityPk), "ephemeral_pk": .string(body.ephemeralPk),
            "encapsulation_pk": .string(body.encapsulationPk), "challenge": .string(body.challenge),
        ])
        return buildTyped(type: "ACCEPT", params: params, body: m)
    }

    public static func buildSelect(_ params: EnvelopeParams, _ body: SelectBody) -> String? {
        let m: V2SJValue = .object([
            "invite_hash": .string(body.inviteHash), "accept_hash": .string(body.acceptHash),
            "transcript_hash": .string(body.transcriptHash), "mac_a": .string(body.macA),
        ])
        return buildTyped(type: "SELECT", params: params, body: m)
    }

    public static func buildConfirm(_ params: EnvelopeParams, _ body: ConfirmBody) -> String? {
        let m: V2SJValue = .object([
            "select_hash": .string(body.selectHash), "transcript_hash": .string(body.transcriptHash), "mac_b": .string(body.macB),
        ])
        return buildTyped(type: "CONFIRM", params: params, body: m)
    }

    public static func buildReady(_ params: EnvelopeParams, _ body: ReadyBody) -> String? {
        let m: V2SJValue = .object([
            "select_hash": .string(body.selectHash), "transcript_hash": .string(body.transcriptHash), "mac_ready": .string(body.macReady),
        ])
        return buildTyped(type: "READY", params: params, body: m)
    }

    public static func buildCancel(_ params: EnvelopeParams, _ body: CancelBody) -> String? {
        let m: V2SJValue = .object(["target_txn_id": .string(body.targetTxnId), "reason": .string(body.reason)])
        return buildTyped(type: "CANCEL", params: params, body: m)
    }

    public static func buildRosterCommit(_ params: EnvelopeParams, _ body: RosterCommitBody) -> String? {
        var m: [String: V2SJValue] = [
            "reason": .string(body.reason), "binding_id": .string(body.bindingId), "epoch": .string(body.epoch),
            "device_roster": .array(body.deviceRoster.map { .string($0) }),
            "packages": .array(body.packages.map { .object(["device_id": .string($0.deviceId), "package": .string($0.pkg)]) }),
        ]
        if let newDevice = body.newDevice {
            m["new_device"] = .object([
                "device_id": .string(newDevice.deviceId), "identity_pk": .string(newDevice.identityPk),
                "encapsulation_pk": .string(newDevice.encapsulationPk),
            ])
        }
        return buildTyped(type: "ROSTER_COMMIT", params: params, body: .object(m))
    }

    public static func buildUnpair(_ params: EnvelopeParams, _ body: UnpairBody) -> String? {
        return buildTyped(type: "UNPAIR", params: params, body: .object(["binding_id": .string(body.bindingId)]))
    }

    public static func buildMerge(_ params: EnvelopeParams, _ body: MergeBody) -> String? {
        let m: V2SJValue = .object([
            "invite_hash_a": .string(body.inviteHashA), "invite_hash_b": .string(body.inviteHashB), "main_txn_id": .string(body.mainTxnId),
        ])
        return buildTyped(type: "MERGE", params: params, body: m)
    }

    public static func buildBusy(_ params: EnvelopeParams, _ body: BusyBody) -> String? {
        return buildTyped(type: "BUSY", params: params, body: .object(["main_txn_id": .string(body.mainTxnId), "reason": .string(body.reason)]))
    }

    /// SHA256(UTF8(wire text)) — how invite_hash/accept_hash/select_hash are computed (v1.4 section
    /// 7/8).
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

    public static func parseInvite(_ wire: String) -> Parsed<InviteBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "INVITE") else { return nil }
        guard case .string(let intent)? = b["intent"], intent == "new" || intent == "replace",
              case .string(let identityPk)? = b["identity_pk"], isEd25519PkB64(identityPk),
              case .string(let ephemeralPk)? = b["ephemeral_pk"], isX25519PkB64(ephemeralPk),
              case .string(let encapsulationPk)? = b["encapsulation_pk"], isX25519PkB64(encapsulationPk),
              case .string(let targetUser)? = b["target_user"],
              case .string(let challenge)? = b["challenge"]
        else { return nil }
        return Parsed(envelope: envelope!, body: InviteBody(intent: intent, identityPk: identityPk, ephemeralPk: ephemeralPk, encapsulationPk: encapsulationPk, targetUser: targetUser, challenge: challenge))
    }

    public static func parseAccept(_ wire: String) -> Parsed<AcceptBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "ACCEPT") else { return nil }
        guard case .string(let inviteHash)? = b["invite_hash"], isDigestB64(inviteHash),
              case .string(let identityPk)? = b["identity_pk"], isEd25519PkB64(identityPk),
              case .string(let ephemeralPk)? = b["ephemeral_pk"], isX25519PkB64(ephemeralPk),
              case .string(let encapsulationPk)? = b["encapsulation_pk"], isX25519PkB64(encapsulationPk),
              case .string(let challenge)? = b["challenge"]
        else { return nil }
        return Parsed(envelope: envelope!, body: AcceptBody(inviteHash: inviteHash, identityPk: identityPk, ephemeralPk: ephemeralPk, encapsulationPk: encapsulationPk, challenge: challenge))
    }

    public static func parseSelect(_ wire: String) -> Parsed<SelectBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "SELECT") else { return nil }
        guard case .string(let inviteHash)? = b["invite_hash"], isDigestB64(inviteHash),
              case .string(let acceptHash)? = b["accept_hash"], isDigestB64(acceptHash),
              case .string(let transcriptHash)? = b["transcript_hash"], isDigestB64(transcriptHash),
              case .string(let macA)? = b["mac_a"], isDigestB64(macA)
        else { return nil }
        return Parsed(envelope: envelope!, body: SelectBody(inviteHash: inviteHash, acceptHash: acceptHash, transcriptHash: transcriptHash, macA: macA))
    }

    public static func parseConfirm(_ wire: String) -> Parsed<ConfirmBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "CONFIRM") else { return nil }
        guard case .string(let selectHash)? = b["select_hash"], isDigestB64(selectHash),
              case .string(let transcriptHash)? = b["transcript_hash"], isDigestB64(transcriptHash),
              case .string(let macB)? = b["mac_b"], isDigestB64(macB)
        else { return nil }
        return Parsed(envelope: envelope!, body: ConfirmBody(selectHash: selectHash, transcriptHash: transcriptHash, macB: macB))
    }

    public static func parseReady(_ wire: String) -> Parsed<ReadyBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "READY") else { return nil }
        guard case .string(let selectHash)? = b["select_hash"], isDigestB64(selectHash),
              case .string(let transcriptHash)? = b["transcript_hash"], isDigestB64(transcriptHash),
              case .string(let macReady)? = b["mac_ready"], isDigestB64(macReady)
        else { return nil }
        return Parsed(envelope: envelope!, body: ReadyBody(selectHash: selectHash, transcriptHash: transcriptHash, macReady: macReady))
    }

    public static func parseCancel(_ wire: String) -> Parsed<CancelBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "CANCEL") else { return nil }
        guard case .string(let targetTxnId)? = b["target_txn_id"],
              case .string(let reason)? = b["reason"], !reason.isEmpty
        else { return nil }
        return Parsed(envelope: envelope!, body: CancelBody(targetTxnId: targetTxnId, reason: reason))
    }

    private static func isEpochText(_ text: String) -> Bool {
        return text == "0" || (text.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil)
    }

    public static func parseRosterCommit(_ wire: String) -> Parsed<RosterCommitBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "ROSTER_COMMIT") else { return nil }
        guard case .string(let reason)? = b["reason"], reason == "rekey" || reason == "add_device" || reason == "remove_device",
              case .string(let bindingId)? = b["binding_id"], isDigestB64(bindingId),
              case .string(let epoch)? = b["epoch"], isEpochText(epoch),
              case .array(let deviceRosterRaw)? = b["device_roster"],
              case .array(let packagesRaw)? = b["packages"]
        else { return nil }

        var deviceRoster: [String] = []
        for d in deviceRosterRaw {
            guard case .string(let deviceId) = d, isDigestB64(deviceId) else { return nil }
            deviceRoster.append(deviceId)
        }

        var packages: [DevicePackage] = []
        var seenDeviceIds: Set<String> = []
        for entry in packagesRaw {
            guard case .object(let entryObj) = entry,
                  case .string(let deviceId)? = entryObj["device_id"], isDigestB64(deviceId), deviceRoster.contains(deviceId),
                  case .string(let pkg)? = entryObj["package"], !pkg.isEmpty,
                  !seenDeviceIds.contains(deviceId)
            else { return nil }
            seenDeviceIds.insert(deviceId)
            packages.append(DevicePackage(deviceId: deviceId, pkg: pkg))
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
            return nil // rekey/remove_device introduce no device — a stray new_device is malformed, not ignored
        }

        return Parsed(envelope: envelope!, body: RosterCommitBody(reason: reason, bindingId: bindingId, epoch: epoch, deviceRoster: deviceRoster, packages: packages, newDevice: newDevice))
    }

    public static func parseUnpair(_ wire: String) -> Parsed<UnpairBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "UNPAIR") else { return nil }
        guard case .string(let bindingId)? = b["binding_id"], isDigestB64(bindingId) else { return nil }
        return Parsed(envelope: envelope!, body: UnpairBody(bindingId: bindingId))
    }

    public static func parseMerge(_ wire: String) -> Parsed<MergeBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "MERGE") else { return nil }
        guard case .string(let inviteHashA)? = b["invite_hash_a"],
              case .string(let inviteHashB)? = b["invite_hash_b"],
              case .string(let mainTxnId)? = b["main_txn_id"],
              inviteHashA != inviteHashB
        else { return nil }
        return Parsed(envelope: envelope!, body: MergeBody(inviteHashA: inviteHashA, inviteHashB: inviteHashB, mainTxnId: mainTxnId))
    }

    public static func parseBusy(_ wire: String) -> Parsed<BusyBody>? {
        let envelope = V2Envelope.parse(prefix: prefix, text: wire)
        guard let b = bodyOf(envelope, expectedType: "BUSY") else { return nil }
        guard case .string(let mainTxnId)? = b["main_txn_id"],
              case .string(let reason)? = b["reason"], !reason.isEmpty
        else { return nil }
        return Parsed(envelope: envelope!, body: BusyBody(mainTxnId: mainTxnId, reason: reason))
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
