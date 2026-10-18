import Foundation

/// N2 group state machine. Five slices: GENESIS + first-join (v1.4 section 10, TEST_MATRIX G-01-G-05),
/// admin rekey (COMMIT, section 11/13/35, G-06-G-13), member/device revocation (section 34,
/// G-18-G-24), offline catch-up (section 36/38, G-25-G-33/G-35), and mode switching (section 12,
/// G-36/G-37). Ported from `src/secutg/v2/group/processor.ts` and
/// `org.telegram.secutg.v2.group.GroupProcessor`.
///
/// What this class does NOT do, on purpose (same scope boundaries as the Android/Web ports):
/// - Reconcile a THIRD MEMBER's local view of a device it neither admitted nor was welcomed by.
///   handlePermit is therefore not built; only the admin who directly processed the JOIN_REQUEST and
///   the joining device itself update their local roster from a join.
/// - Distinguish auto vs face-to-face delivery as separate code paths — only the TRANSPORT differs,
///   a UI-layer concern.
/// - Change membership WHILE ALSO changing mode — checkReasonConsistency refuses combining them.
/// - Gate confirmModeSwitch behind an actual user decision — it is the bare mechanical acceptance a
///   caller invokes once a UI confirmation step has actually happened.
/// - Let reason=rotate/rebuild behave differently from each other.
/// - Implement REBUILD_REQUEST or KEY_REQUEST.
/// - Let a user DELETE a per-epoch historical master (G-24).
/// - Distinguish "a late historical business message" from a live control event (G-34) — DATA-01's.
/// - Implement section 14's handleCommit sync-gate/high-water-mark requirement — resolveCommits is a
///   SEPARATE, explicitly-called step.
/// - Buffer or resolve a COMMIT whose parent_hash this device has never seen at all — refused as
///   unknown_parent; catch-up in this slice is SEQUENTIAL only.
public final class V2GroupProcessor {
    public static let defaultTtlMs: Int64 = 10 * 60 * 1000 // matches P2's own default window (v1.4 §08); auto-mode JOIN_REQUEST uses this
    /// v1.4 section 10: face-to-face QR "defaults to 5 minutes' validity".
    public static let qrTtlMs: Int64 = 5 * 60 * 1000

    public struct GenesisOutcome {
        public let wire: String
        public let master: [UInt8]
    }

    public struct JoinOutcome {
        public let ok: Bool
        public let kind: String?
        public let permitWire: String?
        public let welcomeWire: String?
        public let reason: String?

        static func installed(permitWire: String, welcomeWire: String) -> JoinOutcome {
            return JoinOutcome(ok: true, kind: "installed", permitWire: permitWire, welcomeWire: welcomeWire, reason: nil)
        }

        static func fail(_ reason: String) -> JoinOutcome {
            return JoinOutcome(ok: false, kind: nil, permitWire: nil, welcomeWire: nil, reason: reason)
        }
    }

    public struct WelcomeOutcome {
        public let ok: Bool
        public let kind: String?
        public let master: [UInt8]?
        public let reason: String?

        static func installed(_ master: [UInt8]) -> WelcomeOutcome {
            return WelcomeOutcome(ok: true, kind: "installed", master: master, reason: nil)
        }

        static func fail(_ reason: String) -> WelcomeOutcome {
            return WelcomeOutcome(ok: false, kind: nil, master: nil, reason: reason)
        }
    }

    public struct CommitOutcome {
        public let commitWire: String
        public let master: [UInt8]
    }

    /// handleCommit's result: ok=false for a structurally-refused wire; "stale_parent" for one whose
    /// parent has ALREADY been superseded locally by a winner that is STILL the correct choice;
    /// "conflict" for one whose parent has ALREADY been superseded by a winner THIS wire would have
    /// beaten (G-09); "buffered" for a genuine candidate against the CURRENT parent.
    public struct HandleCommitOutcome {
        public let ok: Bool
        public let kind: String? // "buffered" | "stale_parent" | "conflict"
        public let reason: String?

        static func ok(_ kind: String) -> HandleCommitOutcome {
            return HandleCommitOutcome(ok: true, kind: kind, reason: nil)
        }

        static func fail(_ reason: String) -> HandleCommitOutcome {
            return HandleCommitOutcome(ok: false, kind: nil, reason: reason)
        }
    }

    /// v1.4 section 11's "once every client syncs to the same high-water mark, pick the valid COMMIT
    /// with the earlier server date, ties broken by smaller state_hash byte order".
    public struct ResolveOutcome {
        public let ok: Bool
        public let state: V2GroupState?
        /// Only for an auto-mode winner (D7). Manual mode: nil; the winner must separately call
        /// issueRekeyWelcomes.
        public let master: [UInt8]?
        public let staleWires: [String]?
        public let reason: String?

        static func installed(state: V2GroupState, master: [UInt8]?, staleWires: [String]) -> ResolveOutcome {
            return ResolveOutcome(ok: true, state: state, master: master, staleWires: staleWires, reason: nil)
        }

        static func fail(_ reason: String) -> ResolveOutcome {
            return ResolveOutcome(ok: false, state: nil, master: nil, staleWires: nil, reason: reason)
        }
    }

    private struct PendingCommitCandidate {
        let wire: String
        let transportDate: Int64
        let body: V2GroupMessages.CommitBody
    }

    private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let len = min(a.count, b.count)
        for i in 0..<len {
            if a[i] != b[i] { return Int(a[i]) - Int(b[i]) }
        }
        return a.count - b.count
    }

    private struct ResolvedParentDecision {
        let transportDate: Int64
        let hashBytes: [UInt8]
    }

    /// groupId -> parentHash -> candidates seen so far for that parent, not yet resolved.
    private var pendingCommits: [String: [String: [PendingCommitCandidate]]] = [:]
    /// groupId -> parentHash -> the (transportDate, hash) of whichever candidate resolveCommits
    /// picked for it — kept even after the parent's bucket is cleared, so a late arrival can be
    /// checked for G-09's CONFLICT case.
    private var resolvedParents: [String: [String: ResolvedParentDecision]] = [:]

    public let stateStore: V2GroupState.GroupStateStore
    public let keyStore: V2GroupKeyStore

    private let identity: V2Identity
    private let now: () -> Int64

    public init(identity: V2Identity, stateStore: V2GroupState.GroupStateStore? = nil, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }, keyStore: V2GroupKeyStore? = nil) {
        self.identity = identity
        self.now = now
        self.stateStore = stateStore ?? V2GroupState.GroupStateStore()
        self.keyStore = keyStore ?? V2GroupKeyStore()
    }

    /// v1.4 section 38: exactly one state may be CURRENT for a group at a time. Whatever WAS current
    /// downgrades to HISTORICAL the moment a NEWER state becomes canonical.
    private func demoteCurrentToHistorical(_ groupId: String) {
        for record in keyStore.all(groupId) where record.status == .current {
            keyStore.set(V2GroupKeyStore.KeyRecord(groupId: record.groupId, stateHash: record.stateHash, epoch: record.epoch, status: .historical, master: record.master))
        }
    }

    /// demoteCurrentToHistorical plus installing the new one.
    private func installCurrentKeyRecord(groupId: String, stateHash: String, epoch: Int, master: [UInt8]) {
        demoteCurrentToHistorical(groupId)
        keyStore.set(V2GroupKeyStore.KeyRecord(groupId: groupId, stateHash: stateHash, epoch: epoch, status: .current, master: master))
    }

    /// v1.4 section 38 (chapter 15's own figure caption): may this device send RIGHT NOW. Requires
    /// holding the CURRENT state's master, still being in deviceRoster, AND modeConfirmed.
    public func canSend(_ groupId: String) -> Bool {
        guard let current = stateStore.current(groupId) else { return false }
        guard current.modeConfirmed else { return false }
        guard current.deviceRoster.contains(ownDeviceId()) else { return false }
        return keyStore.get(groupId, current.stateHash)?.status == .current
    }

    private func ownDeviceId() -> String {
        return Base64Url.encode(V2Suite.sha256(identity.publicKey))
    }

    private func envelopeParams(groupId: String, ttlMs: Int64 = defaultTtlMs) -> V2GroupMessages.EnvelopeParams {
        let createdMs = now()
        return V2GroupMessages.EnvelopeParams(
            eventId: V2Envelope.randomId(), groupId: groupId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
            actorIdentitySk: identity.secretKey, createdMs: String(createdMs), expiresMs: String(createdMs + ttlMs)
        )
    }

    private func isExpired(_ expiresMsText: String) -> Bool {
        guard let expiresMs = Int64(expiresMsText) else { return true }
        return now() >= expiresMs
    }

    /// v1.4 section 13's GENESIS (G-01): creates a brand-new group at epoch=0, installs it locally,
    /// records this device's own master as CURRENT in keyStore, and returns it. coAdmins lets the
    /// founder name OTHER devices as admins from the start.
    public func genesis(_ groupId: String, mode: V2GroupState.Mode, coAdmins: [V2Identity] = []) -> GenesisOutcome? {
        let genesisId = Base64Url.encode(V2Suite.randomBytes(32))
        let master = V2Suite.randomBytes(32)
        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: genesisId, epoch: 0, master: master) else { return nil }

        var admins: [V2GroupMessages.AdminAclEntry] = [
            V2GroupMessages.AdminAclEntry(deviceId: ownDeviceId(), identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk)),
        ]
        for id in coAdmins {
            admins.append(V2GroupMessages.AdminAclEntry(deviceId: Base64Url.encode(V2Suite.sha256(id.publicKey)), identityPk: Base64Url.encode(id.publicKey), encapsulationPk: Base64Url.encode(id.encapsulationPk)))
        }
        guard let wire = V2GroupMessages.buildGenesis(envelopeParams(groupId: groupId), V2GroupMessages.GenesisBody(genesisId: genesisId, mode: mode, adminAcl: admins, keyCommitment: Base64Url.encode(keyCommitment))) else { return nil }

        var adminAclOut: [V2GroupState.AdminAclEntry] = []
        var deviceRoster: [String] = []
        var deviceKeys: [String: V2GroupState.DeviceKeys] = [:]
        for a in admins {
            adminAclOut.append(V2GroupState.AdminAclEntry(deviceId: a.deviceId, identityPk: a.identityPk))
            deviceRoster.append(a.deviceId)
            deviceKeys[a.deviceId] = V2GroupState.DeviceKeys(identityPk: a.identityPk, encapsulationPk: a.encapsulationPk)
        }
        let state = V2GroupState(
            groupId: groupId, genesisId: genesisId, stateHash: Base64Url.encode(V2GroupMessages.hashWire(wire)), epoch: 0, mode: mode,
            adminAcl: adminAclOut, deviceRoster: deviceRoster, deviceKeys: deviceKeys, keyCommitment: Base64Url.encode(keyCommitment), modeConfirmed: true
        )
        guard stateStore.installGenesis(state) else { return nil }
        installCurrentKeyRecord(groupId: groupId, stateHash: state.stateHash, epoch: 0, master: master)
        return GenesisOutcome(wire: wire, master: master)
    }

    /// A device bootstraps its local view of a group it did not create by trusting a GENESIS it
    /// obtained through an already-trusted channel. Signature is checked against the event's OWN
    /// admin_acl.
    @discardableResult
    public func handleGenesis(_ wire: String) -> Bool {
        guard let parsed = V2GroupMessages.parseGenesis(wire) else { return false }
        guard let signer = parsed.body.adminAcl.first(where: { $0.deviceId == parsed.envelope.actorDevice }) else { return false }
        guard V2GroupMessages.verifyTyped(parsed.envelope, identityPkB64: signer.identityPk) else { return false }

        var adminAcl: [V2GroupState.AdminAclEntry] = []
        var deviceRoster: [String] = []
        var deviceKeys: [String: V2GroupState.DeviceKeys] = [:]
        for a in parsed.body.adminAcl {
            adminAcl.append(V2GroupState.AdminAclEntry(deviceId: a.deviceId, identityPk: a.identityPk))
            deviceRoster.append(a.deviceId)
            deviceKeys[a.deviceId] = V2GroupState.DeviceKeys(identityPk: a.identityPk, encapsulationPk: a.encapsulationPk)
        }
        let state = V2GroupState(
            groupId: parsed.envelope.chatId, genesisId: parsed.body.genesisId, stateHash: Base64Url.encode(V2GroupMessages.hashWire(wire)), epoch: 0,
            mode: parsed.body.mode, adminAcl: adminAcl, deviceRoster: deviceRoster, deviceKeys: deviceKeys, keyCommitment: parsed.body.keyCommitment, modeConfirmed: true
        )
        return stateStore.installGenesis(state)
    }

    /// v1.4 section 10 (G-02/G-04): a prospective member's own first message.
    public func joinRequest(_ groupId: String, ttlMs: Int64 = defaultTtlMs) -> String? {
        guard let state = stateStore.current(groupId) else { return nil }
        return V2GroupMessages.buildJoinRequest(envelopeParams(groupId: groupId, ttlMs: ttlMs), V2GroupMessages.JoinRequestBody(
            stateHash: state.stateHash, identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk),
            requestNonce: Base64Url.encode(V2Suite.randomBytes(32))
        ))
    }

    /// v1.4 section 10/34 (G-02/G-03): an ADMIN receives a JOIN_REQUEST, issues PERMIT + WELCOME.
    public func handleJoinRequest(_ wire: String, master: [UInt8]) -> JoinOutcome {
        guard let parsed = V2GroupMessages.parseJoinRequest(wire) else { return .fail("malformed") }
        guard !isExpired(parsed.envelope.expiresMs) else { return .fail("expired") }
        guard V2GroupMessages.verifyTyped(parsed.envelope, identityPkB64: parsed.body.identityPk) else { return .fail("bad_signature") }

        let groupId = parsed.envelope.chatId
        guard let state = stateStore.current(groupId) else { return .fail("unknown_group") }
        guard parsed.body.stateHash == state.stateHash else { return .fail("stale_snapshot") }
        let ownDeviceId = ownDeviceId()
        guard state.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return .fail("not_an_admin") }

        guard let requesterPk = Base64Url.decode(parsed.body.identityPk) else { return .fail("malformed") }
        let requesterDeviceId = Base64Url.encode(V2Suite.sha256(requesterPk))
        guard state.deviceKeys[requesterDeviceId] == nil else { return .fail("already_registered") }

        let permitId = Base64Url.encode(V2Suite.randomBytes(32))
        guard let permitWire = V2GroupMessages.buildPermit(envelopeParams(groupId: groupId), V2GroupMessages.PermitBody(
            stateHash: state.stateHash, recipientUser: parsed.envelope.actorUser, deviceId: requesterDeviceId, signPk: parsed.body.identityPk, rights: "read_write", permitId: permitId
        )) else { return .fail("build_failed") }

        guard let recipientEncapsulationPk = Base64Url.decode(parsed.body.encapsulationPk) else { return .fail("malformed") }
        guard let welcomeWire = V2GroupMessages.buildWelcome(envelopeParams(groupId: groupId), V2GroupMessages.WelcomeBody(
            stateHash: state.stateHash, permitHash: Base64Url.encode(V2GroupMessages.hashWire(permitWire)), recipientDevice: requesterDeviceId,
            sealed: Base64Url.encode(V2Suite.sealFor(recipientX25519Pk: recipientEncapsulationPk, bytes: master))
        )) else { return .fail("build_failed") }

        stateStore.addDevice(groupId: groupId, deviceId: requesterDeviceId, keys: V2GroupState.DeviceKeys(identityPk: parsed.body.identityPk, encapsulationPk: parsed.body.encapsulationPk))
        return .installed(permitWire: permitWire, welcomeWire: welcomeWire)
    }

    /// Installs the master an admin sealed to this device. Verifies EVERY field the sealed box
    /// itself cannot protect — stateHash against a state this device actually knows (current OR
    /// historical), recipientDevice against its own device id, and keyCommitment after opening.
    public func handleWelcome(_ wire: String) -> WelcomeOutcome {
        guard let parsed = V2GroupMessages.parseWelcome(wire) else { return .fail("malformed") }
        let groupId = parsed.envelope.chatId
        guard let current = stateStore.current(groupId) else { return .fail("unknown_group") }
        guard let target = stateStore.findByStateHash(groupId: groupId, stateHash: parsed.body.stateHash) else { return .fail("wrong_state") }

        let issuerDeviceId = parsed.envelope.actorDevice
        guard let issuerKeys = current.deviceKeys[issuerDeviceId], current.adminAcl.contains(where: { $0.deviceId == issuerDeviceId }) else {
            return .fail("unauthorized")
        }
        guard V2GroupMessages.verifyTyped(parsed.envelope, identityPkB64: issuerKeys.identityPk) else { return .fail("bad_signature") }

        let ownDeviceId = ownDeviceId()
        guard parsed.body.recipientDevice == ownDeviceId else { return .fail("not_for_me") }

        guard let sealed = Base64Url.decode(parsed.body.sealed) else { return .fail("malformed") }
        guard let master = V2Suite.openSealed(recipientPk: identity.encapsulationPk, recipientSk: identity.encapsulationSk, sealed: sealed), master.count == 32 else {
            return .fail("bad_package")
        }

        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: target.genesisId, epoch: target.epoch, master: master), Base64Url.encode(keyCommitment) == target.keyCommitment else {
            return .fail("key_commitment_mismatch")
        }

        if target.stateHash == current.stateHash {
            installCurrentKeyRecord(groupId: groupId, stateHash: target.stateHash, epoch: target.epoch, master: master)
            stateStore.addDevice(groupId: groupId, deviceId: ownDeviceId, keys: V2GroupState.DeviceKeys(identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk)))
        } else {
            // A re-issued PAST generation's key never touches what's CURRENT — only ever adds
            // readable history (v1.4 section 37).
            keyStore.set(V2GroupKeyStore.KeyRecord(groupId: groupId, stateHash: target.stateHash, epoch: target.epoch, status: .historical, master: master))
        }
        return .installed(master)
    }

    /// v1.4 section 36 (G-28): re-issues a MISSING generation's WELCOME to a device that held a
    /// valid permit for it but never received the package.
    public func reissueWelcome(groupId: String, targetDeviceId: String, targetStateHash: String) -> String? {
        guard let current = stateStore.current(groupId) else { return nil }
        let ownDeviceId = ownDeviceId()
        guard current.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return nil }
        guard let target = stateStore.findByStateHash(groupId: groupId, stateHash: targetStateHash), target.deviceRoster.contains(targetDeviceId) else { return nil }
        guard let record = keyStore.get(groupId, targetStateHash), let master = record.master else { return nil }
        guard let recipientKeys = target.deviceKeys[targetDeviceId] else { return nil }
        guard let recipientPk = Base64Url.decode(recipientKeys.encapsulationPk) else { return nil }

        return V2GroupMessages.buildWelcome(envelopeParams(groupId: groupId), V2GroupMessages.WelcomeBody(
            stateHash: targetStateHash, permitHash: targetStateHash, recipientDevice: targetDeviceId, sealed: Base64Url.encode(V2Suite.sealFor(recipientX25519Pk: recipientPk, bytes: master))
        ))
    }

    private func pendingBucket(groupId: String, parentHash: String) -> [PendingCommitCandidate] {
        return pendingCommits[groupId]?[parentHash] ?? []
    }

    private func appendPendingBucket(groupId: String, parentHash: String, candidate: PendingCommitCandidate) {
        pendingCommits[groupId, default: [:]][parentHash, default: []].append(candidate)
    }

    /// admin_acl, but with each admin's encapsulation_pk looked up from deviceKeys.
    private func currentAdminAclWithKeys(_ state: V2GroupState) -> [V2GroupMessages.AdminAclEntry]? {
        var adminAcl: [V2GroupMessages.AdminAclEntry] = []
        for admin in state.adminAcl {
            guard let encapsulationPk = state.deviceKeys[admin.deviceId]?.encapsulationPk else { return nil }
            adminAcl.append(V2GroupMessages.AdminAclEntry(deviceId: admin.deviceId, identityPk: admin.identityPk, encapsulationPk: encapsulationPk))
        }
        return adminAcl
    }

    /// v1.4 section 11/35 (G-06/G-07): ANY current, still-valid admin may rekey. Does NOT install
    /// anything locally — even the issuer must feed its own wire back through handleCommit/
    /// resolveCommits like anyone else.
    public func commit(_ groupId: String, reason: String) -> CommitOutcome? {
        guard let state = stateStore.current(groupId) else { return nil }
        let ownDeviceId = ownDeviceId()
        guard state.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return nil }

        let master = V2Suite.randomBytes(32)
        let epoch = state.epoch + 1
        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: state.genesisId, epoch: epoch, master: master) else { return nil }
        guard let adminAcl = currentAdminAclWithKeys(state) else { return nil }

        guard let wire = V2GroupMessages.buildCommit(envelopeParams(groupId: groupId), V2GroupMessages.CommitBody(
            parentHash: state.stateHash, epoch: String(epoch), mode: state.mode, adminAcl: adminAcl, deviceRoster: state.deviceRoster,
            keyCommitment: Base64Url.encode(keyCommitment), reason: reason,
            // v1.4 D7: plaintext master ONLY in auto mode.
            master: state.mode == .auto ? Base64Url.encode(master) : nil, newDevice: nil
        )) else { return nil }
        return CommitOutcome(commitWire: wire, master: master)
    }

    /// v1.4 section 34 (G-19/G-22): adds a device NOT currently in the roster, ALWAYS bumping epoch.
    public func commitAddDevice(groupId: String, newDeviceId: String, newDeviceIdentityPkBytes: [UInt8], newDeviceEncapsulationPkBytes: [UInt8], asAdmin: Bool) -> CommitOutcome? {
        guard let state = stateStore.current(groupId) else { return nil }
        let ownDeviceId = ownDeviceId()
        guard state.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return nil }
        guard !state.deviceRoster.contains(newDeviceId) else { return nil }

        let master = V2Suite.randomBytes(32)
        let epoch = state.epoch + 1
        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: state.genesisId, epoch: epoch, master: master) else { return nil }
        guard let existingAdminAcl = currentAdminAclWithKeys(state) else { return nil }

        let newDeviceIdentityPk = Base64Url.encode(newDeviceIdentityPkBytes)
        let newDeviceEncapsulationPk = Base64Url.encode(newDeviceEncapsulationPkBytes)
        var adminAcl = existingAdminAcl
        if asAdmin {
            adminAcl.append(V2GroupMessages.AdminAclEntry(deviceId: newDeviceId, identityPk: newDeviceIdentityPk, encapsulationPk: newDeviceEncapsulationPk))
        }

        var deviceRoster = state.deviceRoster
        deviceRoster.append(newDeviceId)
        deviceRoster.sort()

        guard let wire = V2GroupMessages.buildCommit(envelopeParams(groupId: groupId), V2GroupMessages.CommitBody(
            parentHash: state.stateHash, epoch: String(epoch), mode: state.mode, adminAcl: adminAcl, deviceRoster: deviceRoster,
            keyCommitment: Base64Url.encode(keyCommitment), reason: "add_device",
            master: state.mode == .auto ? Base64Url.encode(master) : nil,
            newDevice: V2GroupMessages.NewDevice(deviceId: newDeviceId, identityPk: newDeviceIdentityPk, encapsulationPk: newDeviceEncapsulationPk)
        )) else { return nil }
        return CommitOutcome(commitWire: wire, master: master)
    }

    /// v1.4 section 34 (G-21/G-22): excludes exactly one device from the NEXT epoch's roster.
    /// deviceKeys is deliberately NOT shrunk.
    public func commitRemoveDevice(groupId: String, targetDeviceId: String) -> CommitOutcome? {
        guard let state = stateStore.current(groupId) else { return nil }
        let ownDeviceId = ownDeviceId()
        guard state.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return nil }
        guard state.deviceRoster.contains(targetDeviceId) else { return nil }

        let master = V2Suite.randomBytes(32)
        let epoch = state.epoch + 1
        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: state.genesisId, epoch: epoch, master: master) else { return nil }
        guard let existingAdminAcl = currentAdminAclWithKeys(state) else { return nil }

        let adminAcl = existingAdminAcl.filter { $0.deviceId != targetDeviceId }
        let deviceRoster = state.deviceRoster.filter { $0 != targetDeviceId }

        guard let wire = V2GroupMessages.buildCommit(envelopeParams(groupId: groupId), V2GroupMessages.CommitBody(
            parentHash: state.stateHash, epoch: String(epoch), mode: state.mode, adminAcl: adminAcl, deviceRoster: deviceRoster,
            keyCommitment: Base64Url.encode(keyCommitment), reason: "remove_device", master: state.mode == .auto ? Base64Url.encode(master) : nil, newDevice: nil
        )) else { return nil }
        return CommitOutcome(commitWire: wire, master: master)
    }

    /// v1.4 section 12 (G-36/G-37): switches mode — roster/admin_acl stay fixed, only mode changes.
    public func commitSwitchMode(_ groupId: String, newMode: V2GroupState.Mode) -> CommitOutcome? {
        guard let state = stateStore.current(groupId) else { return nil }
        guard newMode != state.mode else { return nil } // not actually a switch
        let ownDeviceId = ownDeviceId()
        guard state.adminAcl.contains(where: { $0.deviceId == ownDeviceId }) else { return nil }

        let master = V2Suite.randomBytes(32)
        let epoch = state.epoch + 1
        guard let keyCommitment = V2GroupState.computeKeyCommitment(genesisIdB64: state.genesisId, epoch: epoch, master: master) else { return nil }
        guard let adminAcl = currentAdminAclWithKeys(state) else { return nil }

        guard let wire = V2GroupMessages.buildCommit(envelopeParams(groupId: groupId), V2GroupMessages.CommitBody(
            parentHash: state.stateHash, epoch: String(epoch), mode: newMode, adminAcl: adminAcl, deviceRoster: state.deviceRoster,
            keyCommitment: Base64Url.encode(keyCommitment), reason: "switch_mode",
            // The NEW mode decides plaintext inclusion (D7).
            master: newMode == .auto ? Base64Url.encode(master) : nil, newDevice: nil
        )) else { return nil }
        return CommitOutcome(commitWire: wire, master: master)
    }

    /// v1.4 section 12 (G-36/G-37): the user has explicitly accepted the pending mode switch.
    public func confirmModeSwitch(_ groupId: String) {
        stateStore.confirmModeSwitch(groupId)
    }

    /// reason-specific shape checks beyond what parseCommit alone can validate context-free.
    private func checkReasonConsistency(parent: V2GroupState, body: V2GroupMessages.CommitBody) -> String? {
        if body.reason == "switch_mode" {
            if body.mode == parent.mode { return "not_a_mode_switch" } // claims to switch but doesn't
            if body.deviceRoster.count != parent.deviceRoster.count { return "roster_mismatch" }
            return nil
        }
        // Every OTHER reason must leave mode exactly as the parent's — only switch_mode may touch it.
        if body.mode != parent.mode { return "unexpected_mode_change" }
        if (body.reason == "rotate" || body.reason == "rebuild"), body.deviceRoster.count != parent.deviceRoster.count {
            return "roster_mismatch"
        }
        if body.reason == "add_device" {
            guard let newDevice = body.newDevice else { return "malformed" }
            if parent.deviceRoster.contains(newDevice.deviceId) { return "already_member" }
            guard let claimedPk = Base64Url.decode(newDevice.identityPk), Base64Url.encode(V2Suite.sha256(claimedPk)) == newDevice.deviceId else {
                return "bad_device_id"
            }
            if body.deviceRoster.count != parent.deviceRoster.count + 1 { return "roster_mismatch" }
        }
        if body.reason == "remove_device", body.deviceRoster.count != parent.deviceRoster.count - 1 {
            return "roster_mismatch"
        }
        return nil
    }

    /// v1.4 section 14's handleCommit: verifies against the PARENT state's admin_acl (G-12), then
    /// either refuses outright, refuses as definitively stale_parent, or buffers it as a live
    /// candidate for resolveCommits to pick among later. transportDate is the caller's own transport
    /// layer's server timestamp for this message (v1.4 section 13: NOT part of the signed COMMIT
    /// itself), supplied separately for exactly that reason.
    public func handleCommit(_ wire: String, transportDate: Int64) -> HandleCommitOutcome {
        guard let parsed = V2GroupMessages.parseCommit(wire) else { return .fail("malformed") }
        let groupId = parsed.envelope.chatId
        guard let parent = stateStore.findByStateHash(groupId: groupId, stateHash: parsed.body.parentHash) else { return .fail("unknown_parent") }
        guard let epoch = Int(parsed.body.epoch) else { return .fail("bad_epoch") }
        guard epoch == parent.epoch + 1 else { return .fail("bad_epoch") }
        guard let signer = parent.adminAcl.first(where: { $0.deviceId == parsed.envelope.actorDevice }) else { return .fail("bad_signature") }
        guard V2GroupMessages.verifyTyped(parsed.envelope, identityPkB64: signer.identityPk) else { return .fail("bad_signature") }
        if let consistency = checkReasonConsistency(parent: parent, body: parsed.body) { return .fail(consistency) }

        guard let current = stateStore.current(groupId) else { return .fail("unknown_group") }
        if parent.stateHash != current.stateHash {
            // The parent this COMMIT references is no longer current — some other COMMIT already won
            // at that parent. G-09: if THIS one would have beaten that winner, CONFLICT, not a quiet
            // loss.
            if let decision = resolvedParents[groupId]?[parent.stateHash] {
                let candidateHash = V2GroupMessages.hashWire(wire)
                let wouldHaveWon = transportDate < decision.transportDate
                    || (transportDate == decision.transportDate && V2GroupProcessor.compareBytes(candidateHash, decision.hashBytes) < 0)
                if wouldHaveWon { return .ok("conflict") }
            }
            return .ok("stale_parent")
        }

        appendPendingBucket(groupId: groupId, parentHash: parent.stateHash, candidate: PendingCommitCandidate(wire: wire, transportDate: transportDate, body: parsed.body))
        return .ok("buffered")
    }

    /// Picks the winner among every candidate handleCommit has buffered for the group's CURRENT
    /// parent (transportDate ascending, ties broken by state_hash byte order ascending), installs
    /// it, and reports every other candidate as staleWires.
    public func resolveCommits(_ groupId: String) -> ResolveOutcome {
        guard let current = stateStore.current(groupId) else { return .fail("unknown_group") }
        let bucket = pendingBucket(groupId: groupId, parentHash: current.stateHash)
        guard !bucket.isEmpty else { return .fail("nothing_pending") }

        let sorted = bucket.sorted { a, b in
            if a.transportDate != b.transportDate { return a.transportDate < b.transportDate }
            return V2GroupProcessor.compareBytes(V2GroupMessages.hashWire(a.wire), V2GroupMessages.hashWire(b.wire)) < 0
        }
        let winner = sorted[0]
        let winnerStateHash = Base64Url.encode(V2GroupMessages.hashWire(winner.wire))

        var deviceKeys = current.deviceKeys
        if let newDevice = winner.body.newDevice {
            deviceKeys[newDevice.deviceId] = V2GroupState.DeviceKeys(identityPk: newDevice.identityPk, encapsulationPk: newDevice.encapsulationPk)
        }
        let adminAcl = winner.body.adminAcl.map { V2GroupState.AdminAclEntry(deviceId: $0.deviceId, identityPk: $0.identityPk) }

        let newState = V2GroupState(
            groupId: groupId, genesisId: current.genesisId, stateHash: winnerStateHash, epoch: Int(winner.body.epoch) ?? current.epoch, mode: winner.body.mode,
            adminAcl: adminAcl, deviceRoster: winner.body.deviceRoster, deviceKeys: deviceKeys, keyCommitment: winner.body.keyCommitment,
            modeConfirmed: winner.body.reason == "switch_mode" ? false : current.modeConfirmed
        )
        stateStore.applyCommit(groupId: groupId, newState: newState)
        pendingCommits[groupId]?.removeValue(forKey: current.stateHash)
        resolvedParents[groupId, default: [:]][current.stateHash] = ResolvedParentDecision(transportDate: winner.transportDate, hashBytes: V2GroupMessages.hashWire(winner.wire))

        var master: [UInt8]? = nil
        if let masterB64 = winner.body.master, let decoded = Base64Url.decode(masterB64),
           let check = V2GroupState.computeKeyCommitment(genesisIdB64: newState.genesisId, epoch: newState.epoch, master: decoded),
           Base64Url.encode(check) == newState.keyCommitment {
            master = decoded
        }
        // v1.4 section 38 (G-25+): auto mode's plaintext master, when present, is extractable by ANY
        // device that can read the wire at all; manual mode has no plaintext master, so this state
        // starts MISSING until a WELCOME installs it.
        if let master = master {
            installCurrentKeyRecord(groupId: groupId, stateHash: newState.stateHash, epoch: newState.epoch, master: master)
        } else {
            demoteCurrentToHistorical(groupId)
            keyStore.set(V2GroupKeyStore.KeyRecord(groupId: groupId, stateHash: newState.stateHash, epoch: newState.epoch, status: .missing, master: nil))
        }
        let staleWires = sorted.dropFirst().map { $0.wire }
        return .installed(state: newState, master: master, staleWires: Array(staleWires))
    }

    /// For a manual-mode winner (no plaintext master in COMMIT): the winning issuer builds one
    /// WELCOME per current roster device — itself included.
    public func issueRekeyWelcomes(groupId: String, master: [UInt8]) -> [String]? {
        guard let state = stateStore.current(groupId) else { return nil }
        var wires: [String] = []
        for deviceId in state.deviceRoster {
            guard let keys = state.deviceKeys[deviceId] else { return nil }
            guard let pk = Base64Url.decode(keys.encapsulationPk) else { return nil }
            guard let wire = V2GroupMessages.buildWelcome(envelopeParams(groupId: groupId), V2GroupMessages.WelcomeBody(
                stateHash: state.stateHash,
                // No accompanying PERMIT for a rekey — the COMMIT itself authorizes this WELCOME, so
                // permitHash reuses it.
                permitHash: state.stateHash, recipientDevice: deviceId, sealed: Base64Url.encode(V2Suite.sealFor(recipientX25519Pk: pk, bytes: master))
            )) else { return nil }
            wires.append(wire)
        }
        return wires
    }
}
