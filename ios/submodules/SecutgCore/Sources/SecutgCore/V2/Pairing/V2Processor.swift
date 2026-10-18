import Foundation

/// P2 five-step pairing state machine (v1.4 section 4-8 happy path and every MAC/signature failure
/// point: TEST_MATRIX.md P-01-P-11), the concurrency rows (P-12, P-14-P-17), and offline/recovery
/// (P-18-P-32, v1.4 section 16/27-30). Ported from `src/secutg/v2/pairing/processor.ts` and
/// `org.telegram.secutg.v2.pairing.Processor`. One instance per device.
///
/// Still NOT here: v1.4 section 31's literal AUTO_PAIR_OFFER/DEVICE_JOIN/DEVICE_ACCEPT/
/// ROSTER_COMMIT ceremony for both sides having two devices online simultaneously from the start of
/// pairing — needs an account-wide device-registry attestation this codebase has not built.
/// V2RosterTests closes the END-STATE invariant (one binding, one roster with all four devices) by
/// chaining this file's ordinary pairwise five-step exchange with V2Roster's already-built ADD_DEVICE
/// twice — a real, tested path to the same roster shape, not a re-implementation of the real-time
/// ceremony itself.
public enum V2Processor {
    /// CONFLICT is terminal and is NOT a failure of this device (TEST_MATRIX P-17, v1.4 section 6): it
    /// means two mutually exclusive but individually valid selections exist for one transaction, so no
    /// local rule can say which view is the real one. Everything stops rather than picking.
    public enum Phase: Codable {
        case invited, selecting, confirming, done, conflict
    }

    public enum Role: Codable {
        case initiator, responder
    }

    /// v1.4 section 16's pair_txn — a mutable in-flight exchange record, matching the mutation shape
    /// the Web/Android references both use (fields assigned as the exchange advances rather than a
    /// new value replacing the whole record).
    ///
    /// SECUTG-HOOK (fix E1): `Codable` — every stored property above is itself `[UInt8]`/`String`/
    /// `Set<String>`/`Codable`-enum-or-struct, so the compiler synthesizes `encode(to:)`/
    /// `init(from:)` here with no manual coding-keys needed, the same "already JSON-safe" shape
    /// `V2Binding`'s own snapshot doc comment describes. `ownEphemeral` is the one field worth a
    /// user-facing note: it is a raw, mid-handshake X25519 PRIVATE key (unlike `master`/`kc`,
    /// already-derived symmetric keys used for exactly one purpose) — it could in principle still be
    /// combined with another public key to derive something new, though the protocol itself always
    /// discards it once the handshake finishes. Persisting it uses exactly the same encrypted-at-rest
    /// mechanism as every other key this device already stores (`V2Storage`'s Keychain-derived
    /// XChaCha20-Poly1305 seal) — no new protection tier — this is simply the first time an
    /// unfinished handshake's raw private key has entered that same encrypted block.
    public final class PendingTxn: Codable {
        public let role: Role
        public var phase: Phase
        public let chatId: String
        public let txnId: String
        public let ownEphemeral: V2Suite.KeyPair
        /// For an initiator: the INVITE it sent. For a responder: the ACCEPT it sent.
        public let ownWire: String
        /// For an initiator: the ACCEPT it received. For a responder: the INVITE it received.
        public var peerWire: String?
        /// Initiator only: the SELECT wire it built in handleAccept.
        public var ownSelectWire: String?
        /// Responder only: the exact SELECT bytes this device acted on.
        public var actedSelectWire: String?
        /// Hashes of ACCEPTs that ANOTHER device of this same account sent for this transaction.
        public var siblingAcceptHashes: Set<String>?
        /// Responder only: the CONFIRM this device sent.
        public var ownConfirmWire: String?
        /// Initiator only: the READY this device sent.
        public var ownReadyWire: String?
        /// Initiator only: the exact CONFIRM bytes this device acted on.
        public var actedConfirmWire: String?
        /// Responder only: the exact READY bytes this device acted on.
        public var actedReadyWire: String?
        public var peerIdentityPk: [UInt8]?
        public var peerEphemeralPk: [UInt8]?
        /// The peer's LONG-TERM X25519 key, bootstrapped from INVITE/ACCEPT.
        public var peerEncapsulationPk: [UInt8]?
        public var peerUser: String?
        public var transcriptHash: [UInt8]?
        public var keys: V2Transcript.DerivedKeys?
        /// SECUTG-HOOK (fix C0, 2026-09-27): persisted backing for `localChatId`. Optional ONLY so a
        /// snapshot written before this field existed still decodes (synthesized Codable reads a
        /// missing optional as nil); nil then means "same as `chatId`".
        private var persistedLocalChatId: String?

        /// SECUTG-HOOK (fix C0, 2026-09-27): the chat THIS device knows the conversation by. A real 1:1
        /// chat id is ASYMMETRIC — each side names the chat after the OTHER user — so the INVITE's wire
        /// `chatId` above (always the initiator's view) is the right key for the transcript and for every
        /// envelope this transaction builds (MACs must match on both sides), but the wrong key for
        /// anything this device stores per chat (chat slot, binding, "is this chat mid-exchange"). The
        /// responder used to file its txn, slot claim and binding under the initiator's view — i.e.
        /// under its OWN user id, its Saved Messages chat.
        public var localChatId: String {
            get { return persistedLocalChatId ?? chatId }
            set { persistedLocalChatId = newValue }
        }

        init(role: Role, phase: Phase, chatId: String, localChatId: String? = nil, txnId: String, ownEphemeral: V2Suite.KeyPair, ownWire: String) {
            self.role = role
            self.phase = phase
            self.chatId = chatId
            self.persistedLocalChatId = localChatId
            self.txnId = txnId
            self.ownEphemeral = ownEphemeral
            self.ownWire = ownWire
        }
    }

    // MARK: result types

    public struct PairResult {
        public let ok: Bool
        public let kind: String?
        public let wire: String?
        public let master: [UInt8]?
        public let reason: String?

        static func ok(_ kind: String, wire: String?, master: [UInt8]?) -> PairResult {
            return PairResult(ok: true, kind: kind, wire: wire, master: master, reason: nil)
        }

        static func fail(_ reason: String) -> PairResult {
            return PairResult(ok: false, kind: nil, wire: nil, master: nil, reason: reason)
        }
    }

    public struct InviteResult {
        public let ok: Bool
        public let kind: String?
        public let targetUser: String?
        public let fromUser: String?
        public let wire: String?
        public let mainTxnId: String?
        public let reason: String?

        static func invited(targetUser: String, fromUser: String) -> InviteResult {
            return InviteResult(ok: true, kind: nil, targetUser: targetUser, fromUser: fromUser, wire: nil, mainTxnId: nil, reason: nil)
        }

        static func wireSent(_ kind: String, wire: String, mainTxnId: String) -> InviteResult {
            return InviteResult(ok: true, kind: kind, targetUser: nil, fromUser: nil, wire: wire, mainTxnId: mainTxnId, reason: nil)
        }

        static func fail(_ reason: String) -> InviteResult {
            return InviteResult(ok: false, kind: nil, targetUser: nil, fromUser: nil, wire: nil, mainTxnId: nil, reason: reason)
        }
    }

    public struct AcceptOutcome {
        public let kind: String // "accept" | "busy" | "expired" | "cancelled" | "rejected"
        public let txnId: String?
        public let wire: String?
    }

    public struct SimpleOutcome {
        public let ok: Bool
        public let reason: String?

        static func ok() -> SimpleOutcome {
            return SimpleOutcome(ok: true, reason: nil)
        }

        static func fail(_ reason: String) -> SimpleOutcome {
            return SimpleOutcome(ok: false, reason: reason)
        }
    }

    public struct SafetyCode {
        public let fingerprint: [UInt8]
        public let shortCode: String
    }

    /// v1.4 section 16's pair_txn store, made swappable so a test can simulate "this device
    /// restarted" by constructing two V2PairingProcessors over the SAME store (P-25, P-29).
    public protocol TxnStore: AnyObject {
        func get(_ txnId: String) -> PendingTxn?
        func set(_ txnId: String, _ txn: PendingTxn)
        func delete(_ txnId: String)
        func values() -> [PendingTxn]
    }

    public final class InMemoryTxnStore: TxnStore {
        private var map: [String: PendingTxn] = [:]

        public init() { }

        public func get(_ txnId: String) -> PendingTxn? {
            return map[txnId]
        }

        public func set(_ txnId: String, _ txn: PendingTxn) {
            map[txnId] = txn
        }

        public func delete(_ txnId: String) {
            map.removeValue(forKey: txnId)
        }

        public func values() -> [PendingTxn] {
            return Array(map.values)
        }

        // MARK: persistence (fix E1: pending transactions now survive a reload — see
        // `V2PersistedState`'s own doc comment for why this store was excluded before)

        public struct Snapshot: Codable {
            public var entries: [String: PendingTxn]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(entries: map)
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> InMemoryTxnStore {
            let store = InMemoryTxnStore()
            store.map = snapshot.entries
            return store
        }
    }

    private static let defaultTtlMs: Int64 = 10 * 60 * 1000 // v1.4 section 8: INVITE default 10 minutes
    /// v1.4 section 32: an explicitly-opted-into TTL, never the default.
    private static let offlineAcceptTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// v1.4 section 6: "the smaller of the two decoded txn_id byte sequences is the main transaction".
    static func smallerTxnId(_ one: String, _ other: String) -> String {
        guard let a = Base64Url.decode(one), let b = Base64Url.decode(other) else {
            return one <= other ? one : other
        }
        let len = min(a.count, b.count)
        for i in 0..<len {
            if a[i] != b[i] { return a[i] < b[i] ? one : other }
        }
        return a.count <= b.count ? one : other
    }

    public final class PairingProcessor {
        private let pending: TxnStore
        private let chatSlot: V2SelectionCas<String>
        public let bindingStore: V2Binding.BindingStore
        public let tombstoneStore: V2Binding.TombstoneStore
        public let authorizationStore: V2Authorization.AuthorizationStore
        public let syncGate: V2SyncGate
        public let keyStore: V2KeyStore.BindingKeyStore

        private let identity: V2Identity
        private let now: () -> Int64

        public init(
            identity: V2Identity, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            pendingStore: TxnStore? = nil, chatSlotStore: V2SelectionCas<String>? = nil,
            bindingStore: V2Binding.BindingStore? = nil, tombstoneStore: V2Binding.TombstoneStore? = nil,
            authorizationStore: V2Authorization.AuthorizationStore? = nil, keyStore: V2KeyStore.BindingKeyStore? = nil
        ) {
            self.identity = identity
            self.now = now
            self.pending = pendingStore ?? InMemoryTxnStore()
            self.chatSlot = chatSlotStore ?? V2SelectionCas<String>()
            self.bindingStore = bindingStore ?? V2Binding.BindingStore()
            self.tombstoneStore = tombstoneStore ?? V2Binding.TombstoneStore()
            self.authorizationStore = authorizationStore ?? V2Authorization.AuthorizationStore()
            self.syncGate = V2SyncGate()
            self.keyStore = keyStore ?? V2KeyStore.BindingKeyStore()
        }

        /// v1.4 section 38's own split: holding a key and being allowed to send are separate questions.
        public func canSend(_ chatId: String) -> Bool {
            guard bindingStore.canSend(chatId) else { return false }
            guard let binding = bindingStore.current(chatId) else { return false }
            // A binding whose roster no longer (or never) names this device can READ (it holds the masters) but must
            // not SEND — the peer would refuse every E2 it signed as `unknown_sender`. (PLAN.md 3.39.13: a clone's
            // own device IS in the roster — it is the showing device's.)
            guard !isOwnDeviceOutsideRoster(chatId) else { return false }
            let record = keyStore.get(binding.bindingId, binding.epoch)
            return record?.status == .current
        }

        /// A current binding whose own device (per-binding identity or global) is not in `deviceKeys`. False without a
        /// binding.
        public func isOwnDeviceOutsideRoster(_ chatId: String) -> Bool {
            guard let binding = bindingStore.current(chatId) else { return false }
            return binding.deviceKeys[V2OwnIdentity.ownDeviceId(for: binding, fallback: identity)] == nil
        }

        /// PLAN.md 3.39.7: the chat's safety code — transcript-derived when this device paired (`getSafetyCode` on
        /// the binding's txn), the code the V2Q carried when it was cloned (`V2Binding.safetyCode`, 3.39.13). nil without a
        /// current binding, or for a binding whose transaction is gone and that carries none.
        public func safetyCodeForChat(_ chatId: String) -> String? {
            guard let binding = bindingStore.current(chatId) else { return nil }
            return getSafetyCode(binding.txnId)?.shortCode ?? binding.safetyCode
        }

        /// v1.4 section 28: "the deadline check uses the moment of THIS processing" — every expiry
        /// check reads now(), never a claim in the message.
        private func isExpired(_ expiresMsText: String) -> Bool {
            guard let expiresMs = Int64(expiresMsText) else { return true }
            return now() >= expiresMs
        }

        private func installBindingIfDue(_ txn: PendingTxn, _ txnId: String) {
            guard let transcriptHash = txn.transcriptHash, let peerIdentityPk = txn.peerIdentityPk, let peerEncapsulationPk = txn.peerEncapsulationPk else { return }
            let bindingId = Base64Url.encode(transcriptHash)
            guard tombstoneStore.unpairedFor(bindingId) == nil else { return }
            // SECUTG-HOOK (fix C0, 2026-09-27): filed under this device's OWN name for the chat
            // (`localChatId`), never the INVITE's wire chat id — see `PendingTxn.localChatId`.
            guard !bindingStore.alreadyInstalledFor(chatId: txn.localChatId, txnId: txnId) else { return }
            let ownDeviceId = Base64Url.encode(V2Suite.sha256(identity.publicKey))
            let peerDeviceId = Base64Url.encode(V2Suite.sha256(peerIdentityPk))
            let roster = [ownDeviceId, peerDeviceId].sorted()
            let deviceKeys: [String: V2Binding.DeviceKeys] = [
                ownDeviceId: V2Binding.DeviceKeys(identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk)),
                peerDeviceId: V2Binding.DeviceKeys(identityPk: Base64Url.encode(peerIdentityPk), encapsulationPk: Base64Url.encode(peerEncapsulationPk)),
            ]
            bindingStore.install(V2Binding.freshTemplate(chatId: txn.localChatId, bindingId: bindingId, epoch: 1, deviceRoster: roster, deviceKeys: deviceKeys, revision: 1, txnId: txnId, installedAtMs: now()))
            if let keys = txn.keys { keyStore.installCurrent(bindingId: bindingId, epoch: 1, master: keys.master) }
            authorizationStore.consumeByTxn(txnId)
        }

        // MARK: initiator side

        public struct StartPairingResult {
            public let txnId: String
            public let wire: String
        }

        public func startPairing(_ chatId: String, _ targetUser: String, intent: String = "new", allowOfflineAccept: Bool = false) -> StartPairingResult? {
            let txnId = V2Envelope.randomId()
            let ephemeral = V2Suite.generateX25519()
            let createdMs = now()
            let ttlMs = allowOfflineAccept ? V2Processor.offlineAcceptTtlMs : V2Processor.defaultTtlMs
            guard let wire = V2Messages.buildInvite(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(createdMs), expiresMs: String(createdMs + ttlMs)
            ), V2Messages.InviteBody(
                intent: intent, identityPk: Base64Url.encode(identity.publicKey), ephemeralPk: Base64Url.encode(ephemeral.publicKey),
                encapsulationPk: Base64Url.encode(identity.encapsulationPk), targetUser: targetUser, challenge: Base64Url.encode(V2Suite.randomBytes(16))
            )) else { return nil }
            pending.set(txnId, PendingTxn(role: .initiator, phase: .invited, chatId: chatId, localChatId: chatId, txnId: txnId, ownEphemeral: ephemeral, ownWire: wire))
            // v1.4 section 9/33, P-33: intent=replace pauses the CURRENT binding's sending immediately.
            if intent == "replace" { bindingStore.suspend(chatId) }
            return StartPairingResult(txnId: txnId, wire: wire)
        }

        /// A's side of step 2->3: A receives ACCEPT. Every failure below leaves pending untouched.
        public func handleAccept(_ wire: String) -> PairResult {
            guard let parsed = V2Messages.parseAccept(wire) else { return .fail("malformed") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: parsed.body.identityPk) else { return .fail("bad_signature") }
            guard let txnId = parsed.envelope.txnId else { return .fail("malformed") }
            guard tombstoneStore.cancelledFor(txnId) == nil else { return .fail("cancelled") }
            guard let txn = pending.get(txnId), txn.role == .initiator else { return .fail("unknown_txn") }
            if txn.phase != .invited {
                if wire == txn.peerWire, let ownSelectWire = txn.ownSelectWire {
                    return .ok("replay", wire: ownSelectWire, master: nil)
                }
                return .fail("already_selected")
            }
            guard !isExpired(parsed.envelope.expiresMs) else { return .fail("expired") }

            let inviteHash = V2Messages.hashWire(txn.ownWire)
            guard parsed.body.inviteHash == Base64Url.encode(inviteHash) else { return .fail("hash_mismatch") }

            let responderDevice = Base64Url.decode(parsed.envelope.actorDevice) ?? []
            guard let peerEphemeralPk = Base64Url.decode(parsed.body.ephemeralPk) else { return .fail("malformed") }
            let acceptHash = V2Messages.hashWire(wire)
            let input = V2Transcript.Input(
                chatId: txn.chatId, txnId: txnId, parentBinding: nil, initiatorUser: identity.userId,
                initiatorDevice: Base64Url.encode(V2Suite.sha256(identity.publicKey)), responderUser: parsed.envelope.actorUser,
                responderDevice: Base64Url.encode(responderDevice), inviteHash: Base64Url.encode(inviteHash), acceptHash: Base64Url.encode(acceptHash)
            )
            guard let th = V2Transcript.computeTranscriptHash(input) else { return .fail("internal") }
            guard let z = V2Suite.x25519(secretKey: txn.ownEphemeral.secretKey, peerPublicKey: peerEphemeralPk) else { return .fail("weak_key") }
            let keys = V2Transcript.deriveKeys(transcriptHash: th, sharedSecret: z)
            let macA = V2Transcript.computeMacA(kc: keys.kc, transcriptHash: th)

            guard let selectWire = V2Messages.buildSelect(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: txn.chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.SelectBody(
                inviteHash: Base64Url.encode(inviteHash), acceptHash: Base64Url.encode(acceptHash), transcriptHash: Base64Url.encode(th), macA: Base64Url.encode(macA)
            )) else { return .fail("internal") }

            txn.phase = .confirming
            txn.peerWire = wire
            txn.peerIdentityPk = Base64Url.decode(parsed.body.identityPk)
            txn.peerEphemeralPk = peerEphemeralPk
            txn.peerEncapsulationPk = Base64Url.decode(parsed.body.encapsulationPk)
            txn.peerUser = parsed.envelope.actorUser
            txn.transcriptHash = th
            txn.keys = keys
            txn.ownSelectWire = selectWire
            return .ok("select_sent", wire: selectWire, master: nil)
        }

        /// A's side of step 4->5: verify B's mac_B (P-09), install, send READY.
        public func handleConfirm(_ wire: String) -> PairResult {
            guard let parsed = V2Messages.parseConfirm(wire) else { return .fail("malformed") }
            guard let txnId = parsed.envelope.txnId else { return .fail("malformed") }
            guard tombstoneStore.cancelledFor(txnId) == nil else { return .fail("cancelled") }
            guard let txn = pending.get(txnId), txn.role == .initiator, let keys = txn.keys, let transcriptHash = txn.transcriptHash else {
                return .fail("unexpected_phase")
            }
            if txn.phase != .confirming {
                if txn.phase == .done, wire == txn.actedConfirmWire, let ownReadyWire = txn.ownReadyWire {
                    return .ok("replay", wire: ownReadyWire, master: keys.master)
                }
                return .fail("unexpected_phase")
            }
            guard let peerIdentityPk = txn.peerIdentityPk, V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else {
                return .fail("bad_signature")
            }
            guard let ownSelectWire = txn.ownSelectWire, let ownSelect = V2Messages.parseSelect(ownSelectWire), !isExpired(ownSelect.envelope.expiresMs) else {
                return .fail("confirm_window_expired")
            }
            let selectHash = Base64Url.encode(V2Messages.hashWire(ownSelectWire))
            guard parsed.body.selectHash == selectHash else { return .fail("select_hash_mismatch") }
            guard parsed.body.transcriptHash == Base64Url.encode(transcriptHash) else { return .fail("transcript_mismatch") }
            let expectedMacB = V2Transcript.computeMacB(kc: keys.kc, transcriptHash: transcriptHash)
            guard let receivedMacB = Base64Url.decode(parsed.body.macB), V2Suite.constantTimeEqual(expectedMacB, receivedMacB) else { return .fail("bad_mac") }

            let macReady = V2Transcript.computeMacReady(kc: keys.kc, transcriptHash: transcriptHash)
            guard let readyWire = V2Messages.buildReady(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: txn.chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.ReadyBody(selectHash: selectHash, transcriptHash: Base64Url.encode(transcriptHash), macReady: Base64Url.encode(macReady))) else {
                return .fail("internal")
            }
            txn.phase = .done
            txn.actedConfirmWire = wire
            txn.ownReadyWire = readyWire
            installBindingIfDue(txn, txnId)
            return .ok("ready_sent", wire: readyWire, master: keys.master)
        }

        // MARK: responder side

        /// Structural parse + bootstrap verification only, for a UI to show "X wants to pair". No
        /// state is recorded here — except in the crossed-invite branch below, where this device lost
        /// the race and accepts the peer's invite on the spot (kind "merged_accept").
        ///
        /// SECUTG-HOOK (fix C0, 2026-09-27): `localChatId` is the chat this device received the INVITE
        /// in — its OWN name for the conversation, which for a real 1:1 chat is never the envelope's
        /// `chat_id` (that is the sender's view). nil keeps the old behaviour (envelope chat id), which is
        /// only right when both sides share one chat id, as the older symmetric-id tests do.
        public func handleInvite(_ wire: String, localChatId: String? = nil) -> InviteResult {
            guard let parsed = V2Messages.parseInvite(wire) else { return .fail("malformed") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: parsed.body.identityPk) else { return .fail("bad_signature") }
            let chatId = parsed.envelope.chatId
            let localChat = localChatId ?? chatId
            let incomingTxn = parsed.envelope.txnId

            // SECUTG-HOOK (fix C0, 2026-09-27): matched on OUR name for the chat. Comparing our own txn's
            // chat id with the incoming envelope's (the peer's view) meant a real crossed invite never
            // matched at all on asymmetric 1:1 ids.
            // SECUTG-HOOK (fix, 2026-09-27): an own INVITE past its expires_ms is not "open" either — nobody
            // can accept it any more (`isOwnInviteExpired`). Counting it made us WIN a crossed race with a
            // dead invite: we answered MERGE, the peer's accept of our invite failed as expired, and both
            // sides waited forever. Treated as absent, the peer's fresh invite is simply offered instead.
            let ownOpen = pending.values().first {
                $0.localChatId == localChat && $0.role == .initiator && $0.phase != .done && $0.phase != .conflict && !isOwnInviteExpired($0.txnId)
            }
            if let ownOpen = ownOpen, let incomingTxn = incomingTxn {
                let ownHash = Base64Url.encode(V2Messages.hashWire(ownOpen.ownWire))
                let theirHash = Base64Url.encode(V2Messages.hashWire(wire))
                if ownOpen.phase != .invited {
                    guard let busy = buildBusyWire(chatId: chatId, mainTxnId: ownOpen.txnId, reason: "already_selected") else { return .fail("build_failed") }
                    return .wireSent("busy_sent", wire: busy, mainTxnId: ownOpen.txnId)
                }
                let mainTxnId = V2Processor.smallerTxnId(ownOpen.txnId, incomingTxn)
                if mainTxnId == ownOpen.txnId {
                    // We WIN: our own INVITE is the main transaction. Unchanged — tell the peer via MERGE
                    // and keep waiting for the ACCEPT the losing side now sends (below).
                    guard let merge = buildMergeWire(chatId: chatId, inviteHashA: ownHash, inviteHashB: theirHash, mainTxnId: mainTxnId) else { return .fail("build_failed") }
                    return .wireSent("merge_sent", wire: merge, mainTxnId: mainTxnId)
                }
                // SECUTG-HOOK (fix, 2026-09-27): we LOSE. v1.4 section 6 / 实施设计 v1.4 line 147: "落选发起方以
                // 接受方角色发送 ACCEPT". This branch used to delete our own txn and answer with a MERGE only —
                // nobody ever ACCEPTed, so the winner sat in INVITED forever ("等待对方同意…") and this side had
                // no cached invite left to tap either. Accept the peer's invite right here instead; our own
                // txn is dropped only once that ACCEPT actually exists, so a refusal leaves it untouched.
                let accepted = acceptInvite(wire, localChatId: localChat)
                guard accepted.kind == "accept", let acceptWire = accepted.wire, !acceptWire.isEmpty else { return .fail("merge_accept_failed") }
                pending.delete(ownOpen.txnId)
                return .wireSent("merged_accept", wire: acceptWire, mainTxnId: incomingTxn)
            }
            return .invited(targetUser: parsed.body.targetUser, fromUser: parsed.envelope.actorUser)
        }

        private func buildBusyWire(chatId: String, mainTxnId: String, reason: String) -> String? {
            return V2Messages.buildBusy(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: nil, chatId: chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.BusyBody(mainTxnId: mainTxnId, reason: reason))
        }

        private func buildMergeWire(chatId: String, inviteHashA: String, inviteHashB: String, mainTxnId: String) -> String? {
            return V2Messages.buildMerge(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: nil, chatId: chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.MergeBody(inviteHashA: inviteHashA, inviteHashB: inviteHashB, mainTxnId: mainTxnId))
        }

        private func slotHolderIsStale(_ txnId: String) -> Bool {
            if tombstoneStore.cancelledFor(txnId) != nil { return true }
            guard let holder = pending.get(txnId) else { return true }
            return holder.phase == .done || holder.phase == .conflict
        }

        /// B's step 2: the explicit "user clicked accept" action. This is where the per-chat slot is
        /// claimed (P-16).
        ///
        /// SECUTG-HOOK (fix C0, 2026-09-27): `localChatId` = the chat this device received the INVITE in
        /// (its own name for the conversation). The chat slot and the eventual binding are filed under
        /// it; the envelope's `chat_id` still goes into the ACCEPT and the transcript unchanged. nil keeps
        /// the old behaviour (envelope chat id) — see `handleInvite`.
        public func acceptInvite(_ inviteWire: String, localChatId: String? = nil) -> AcceptOutcome {
            let rejected = AcceptOutcome(kind: "rejected", txnId: "", wire: "")
            guard let parsed = V2Messages.parseInvite(inviteWire), V2Messages.verifyTyped(parsed.envelope, identityPkB64: parsed.body.identityPk) else { return rejected }
            guard let txnId = parsed.envelope.txnId else { return rejected }
            let localChat = localChatId ?? parsed.envelope.chatId
            if isExpired(parsed.envelope.expiresMs) { return AcceptOutcome(kind: "expired", txnId: txnId, wire: nil) }
            if tombstoneStore.cancelledFor(txnId) != nil { return AcceptOutcome(kind: "cancelled", txnId: txnId, wire: nil) }
            let claim = chatSlot.select(slotKey: localChat, candidateId: txnId)
            if !claim.won, claim.selected != txnId {
                if slotHolderIsStale(claim.selected) {
                    chatSlot.forceReplace(slotKey: localChat, candidateId: txnId)
                } else {
                    guard let busy = buildBusyWire(chatId: parsed.envelope.chatId, mainTxnId: claim.selected, reason: "chat_busy") else { return rejected }
                    return AcceptOutcome(kind: "busy", txnId: claim.selected, wire: busy)
                }
            }
            if let existing = pending.get(txnId) {
                return AcceptOutcome(kind: "accept", txnId: txnId, wire: existing.ownWire)
            }
            let ephemeral = V2Suite.generateX25519()
            guard let wire = V2Messages.buildAccept(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: parsed.envelope.chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.AcceptBody(
                inviteHash: Base64Url.encode(V2Messages.hashWire(inviteWire)), identityPk: Base64Url.encode(identity.publicKey),
                ephemeralPk: Base64Url.encode(ephemeral.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk),
                challenge: Base64Url.encode(V2Suite.randomBytes(16))
            )) else { return rejected }
            let txn = PendingTxn(role: .responder, phase: .selecting, chatId: parsed.envelope.chatId, localChatId: localChat, txnId: txnId, ownEphemeral: ephemeral, ownWire: wire)
            txn.peerWire = inviteWire
            txn.peerIdentityPk = Base64Url.decode(parsed.body.identityPk)
            txn.peerEphemeralPk = Base64Url.decode(parsed.body.ephemeralPk)
            txn.peerUser = parsed.envelope.actorUser
            txn.peerEncapsulationPk = Base64Url.decode(parsed.body.encapsulationPk)
            pending.set(txnId, txn)
            return AcceptOutcome(kind: "accept", txnId: txnId, wire: wire)
        }

        /// Records an ACCEPT seen in the chat that another device of THIS account sent for a
        /// transaction this device is also a candidate in (P-12).
        @discardableResult
        public func observeAccept(_ wire: String) -> Bool {
            guard let parsed = V2Messages.parseAccept(wire) else { return false }
            guard let txnId = parsed.envelope.txnId else { return false }
            guard let txn = pending.get(txnId), txn.role == .responder else { return false }
            guard parsed.envelope.actorUser == identity.userId else { return false }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(identity.publicKey)) else { return false }
            let hash = Base64Url.encode(V2Messages.hashWire(wire))
            guard hash != Base64Url.encode(V2Messages.hashWire(txn.ownWire)) else { return false }
            if txn.siblingAcceptHashes == nil { txn.siblingAcceptHashes = [] }
            txn.siblingAcceptHashes?.insert(hash)
            return true
        }

        /// B's step 3->4: verify SELECT (recomputing th independently — P-07/P-08), install, send
        /// CONFIRM.
        public func handleSelect(_ wire: String) -> PairResult {
            guard let parsed = V2Messages.parseSelect(wire) else { return .fail("malformed") }
            guard let txnId = parsed.envelope.txnId else { return .fail("malformed") }
            guard tombstoneStore.cancelledFor(txnId) == nil else { return .fail("cancelled") }
            guard let txn = pending.get(txnId), txn.role == .responder, let peerWire = txn.peerWire, let peerIdentityPk = txn.peerIdentityPk, let peerEphemeralPk = txn.peerEphemeralPk else {
                return .fail("unexpected_phase")
            }
            if txn.phase == .conflict { return .fail("conflict") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else { return .fail("bad_signature") }

            let inviteHash = V2Messages.hashWire(peerWire)
            let acceptHash = V2Messages.hashWire(txn.ownWire)
            if txn.phase != .selecting {
                if wire == txn.actedSelectWire { return .ok("replay", wire: txn.ownConfirmWire, master: nil) }
                txn.phase = .conflict
                return .fail("conflict")
            }
            guard !isExpired(parsed.envelope.expiresMs) else { return .fail("expired") }
            guard parsed.body.inviteHash == Base64Url.encode(inviteHash) else { return .fail("hash_mismatch") }
            if parsed.body.acceptHash != Base64Url.encode(acceptHash) {
                if let siblingHashes = txn.siblingAcceptHashes, siblingHashes.contains(parsed.body.acceptHash) {
                    pending.delete(txnId)
                    return PairResult(ok: true, kind: "superseded", wire: nil, master: nil, reason: nil)
                }
                return .fail("hash_mismatch")
            }
            let input = V2Transcript.Input(
                chatId: txn.chatId, txnId: txnId, parentBinding: nil, initiatorUser: parsed.envelope.actorUser, initiatorDevice: parsed.envelope.actorDevice,
                responderUser: identity.userId, responderDevice: Base64Url.encode(V2Suite.sha256(identity.publicKey)),
                inviteHash: Base64Url.encode(inviteHash), acceptHash: Base64Url.encode(acceptHash)
            )
            guard let th = V2Transcript.computeTranscriptHash(input), parsed.body.transcriptHash == Base64Url.encode(th) else { return .fail("transcript_mismatch") }
            guard let z = V2Suite.x25519(secretKey: txn.ownEphemeral.secretKey, peerPublicKey: peerEphemeralPk) else { return .fail("weak_key") }
            let keys = V2Transcript.deriveKeys(transcriptHash: th, sharedSecret: z)
            let expectedMacA = V2Transcript.computeMacA(kc: keys.kc, transcriptHash: th)
            guard let receivedMacA = Base64Url.decode(parsed.body.macA), V2Suite.constantTimeEqual(expectedMacA, receivedMacA) else { return .fail("bad_mac") }

            let macB = V2Transcript.computeMacB(kc: keys.kc, transcriptHash: th)
            guard let confirmWire = V2Messages.buildConfirm(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: txn.chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.ConfirmBody(selectHash: Base64Url.encode(V2Messages.hashWire(wire)), transcriptHash: Base64Url.encode(th), macB: Base64Url.encode(macB))) else {
                return .fail("internal")
            }

            txn.phase = .confirming
            txn.transcriptHash = th
            txn.keys = keys
            txn.actedSelectWire = wire
            txn.ownConfirmWire = confirmWire
            return .ok("confirm_sent", wire: confirmWire, master: keys.master)
        }

        /// B's step 5: verify mac_ready (P-10), submit complete.
        public func handleReady(_ wire: String) -> PairResult {
            guard let parsed = V2Messages.parseReady(wire) else { return .fail("malformed") }
            guard let txnId = parsed.envelope.txnId else { return .fail("malformed") }
            guard tombstoneStore.cancelledFor(txnId) == nil else { return .fail("cancelled") }
            guard let txn = pending.get(txnId), txn.role == .responder, let keys = txn.keys, let transcriptHash = txn.transcriptHash, let peerIdentityPk = txn.peerIdentityPk else {
                return .fail("unexpected_phase")
            }
            if txn.phase != .confirming {
                if txn.phase == .done, wire == txn.actedReadyWire {
                    return PairResult(ok: true, kind: "already_complete", wire: nil, master: keys.master, reason: nil)
                }
                return .fail("unexpected_phase")
            }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else { return .fail("bad_signature") }
            guard let ownConfirmWire = txn.ownConfirmWire, let ownConfirm = V2Messages.parseConfirm(ownConfirmWire), !isExpired(ownConfirm.envelope.expiresMs) else {
                return .fail("confirm_window_expired")
            }
            guard parsed.body.transcriptHash == Base64Url.encode(transcriptHash) else { return .fail("transcript_mismatch") }
            let expectedReady = V2Transcript.computeMacReady(kc: keys.kc, transcriptHash: transcriptHash)
            guard let receivedReady = Base64Url.decode(parsed.body.macReady), V2Suite.constantTimeEqual(expectedReady, receivedReady) else { return .fail("bad_mac") }

            txn.phase = .done
            txn.actedReadyWire = wire
            installBindingIfDue(txn, txnId)
            return PairResult(ok: true, kind: "complete", wire: nil, master: keys.master, reason: nil)
        }

        // MARK: termination: CANCEL (in-flight txn) and UNPAIR (installed binding)

        public func handleCancel(_ wire: String) -> SimpleOutcome {
            guard let parsed = V2Messages.parseCancel(wire) else { return .fail("malformed") }
            guard let txnId = parsed.envelope.txnId, txnId == parsed.body.targetTxnId else { return .fail("malformed") }
            guard let txn = pending.get(txnId), let peerIdentityPk = txn.peerIdentityPk else { return .fail("unknown_txn") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else { return .fail("bad_signature") }
            tombstoneStore.recordCancelled(txnId: txnId, eventId: parsed.envelope.eventId, atMs: now())
            authorizationStore.consumeByTxn(txnId)
            // SECUTG-HOOK (fix): see `cancelPairing`'s own note -- without this, the PEER's copy of the
            // same transaction stayed in `pending` forever too, so cancelling only ever unstuck the
            // side that tapped cancel, never the other one.
            pending.delete(txnId)
            return .ok()
        }

        /// SECUTG-HOOK (fix, 2026-09-27): the peer cancelled (or reset) an INVITE this device only ever
        /// CACHED — never accepted, so no pending txn exists and `handleCancel` answers `unknown_txn`. The
        /// dead invite then stayed on offer, and accepting it stalled forever (the peer refuses an ACCEPT
        /// for a txn it cancelled). Authenticated against the cached INVITE itself: same txnId on both
        /// sides of the CANCEL and on the invite, and the CANCEL signed by the invite's own identity key.
        /// Records the cancelled tombstone, so `acceptInvite` of that invite answers "cancelled" from now on.
        public func handleCancelOfCachedInvite(cancelWire: String, cachedInviteWire: String) -> SimpleOutcome {
            guard let cancel = V2Messages.parseCancel(cancelWire), let invite = V2Messages.parseInvite(cachedInviteWire) else { return .fail("malformed") }
            guard let txnId = cancel.envelope.txnId, txnId == cancel.body.targetTxnId, txnId == invite.envelope.txnId else { return .fail("unknown_txn") }
            guard V2Messages.verifyTyped(cancel.envelope, identityPkB64: invite.body.identityPk) else { return .fail("bad_signature") }
            tombstoneStore.recordCancelled(txnId: txnId, eventId: cancel.envelope.eventId, atMs: now())
            authorizationStore.consumeByTxn(txnId)
            return .ok()
        }

        /// `localChatId` (SECUTG-HOOK, fix 2026-09-29 真机, PLAN.md 3.39): the chat this device received the UNPAIR in. Only
        /// the "superseded" rule below needs it — nil keeps the old behaviour exactly.
        public func handleUnpair(_ wire: String, localChatId: String? = nil) -> SimpleOutcome {
            guard let parsed = V2Messages.parseUnpair(wire) else { return .fail("malformed") }
            let txn = parsed.envelope.txnId.flatMap { pending.get($0) }
            guard let txnId = parsed.envelope.txnId, let txn = txn, let peerIdentityPk = txn.peerIdentityPk else {
                // PLAN.md 3.39.7's binding-based fallback: an UNPAIR from a device that joined by V2Q names no
                // pairing transaction (it never ran one), and an UNPAIR for a binding whose transaction this device
                // has since lost still names a binding it holds. Either way the signer must be a CURRENT roster
                // member of the binding the wire names, verified against the key on file for it — never a key the
                // wire itself declares. A binding this device does not hold at all stays `unknown_txn`: nothing to
                // check a signature against, so nothing is torn down on someone's say-so.
                guard let chatId = bindingStore.allChatIdsWithCurrentBinding().first(where: { bindingStore.current($0)?.bindingId == parsed.body.bindingId }),
                      let binding = bindingStore.current(chatId) else { return unpairSupersededBinding(parsed, localChatId: localChatId) }
                let actor = parsed.envelope.actorDevice
                guard let actorKeys = binding.deviceKeys[actor], binding.deviceRoster.contains(actor) else { return .fail("unauthorized") }
                guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: actorKeys.identityPk) else { return .fail("bad_signature") }
                tombstoneStore.recordUnpaired(bindingId: parsed.body.bindingId, eventId: parsed.envelope.eventId, atMs: now())
                bindingStore.deactivate(chatId)
                return .ok()
            }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else { return .fail("bad_signature") }
            tombstoneStore.recordUnpaired(bindingId: parsed.body.bindingId, eventId: parsed.envelope.eventId, atMs: now())
            // SECUTG-HOOK (fix C0, 2026-09-27): the binding lives under this device's own chat name.
            bindingStore.deactivate(txn.localChatId)
            authorizationStore.consumeByTxn(txnId)
            return .ok()
        }

        /// SECUTG-HOOK (fix, 2026-09-29 真机, PLAN.md 3.39): an authenticated UNPAIR for a binding of this chat that is NOT
        /// the one this device holds. Its signer is a current roster member of this device's binding (verified against
        /// the key on file for it) and it was made after this device installed that binding — so that member, who can
        /// only ever hold one current binding for the chat, had already moved to another one: this device's binding is
        /// no longer the chat's live one on the other side. It is set aside exactly like an unpair (tombstoned,
        /// deactivated, history keys kept). The real case: a device that joined by V2Q is left on the old binding when
        /// O and the peer pair again, and O's 「一键恢复」 names O's binding, not that one — the joined device kept sending
        /// E2 nobody could read and refused every new code (`already_paired`). An UNPAIR made before this device's binding
        /// was installed (a history replay) changes nothing, and a signer this binding does not know is refused as before.
        private func unpairSupersededBinding(_ parsed: V2Messages.Parsed<V2Messages.UnpairBody>, localChatId: String?) -> SimpleOutcome {
            guard let chatId = localChatId, let binding = bindingStore.current(chatId), binding.bindingId != parsed.body.bindingId else { return .fail("unknown_txn") }
            let actor = parsed.envelope.actorDevice
            guard let actorKeys = binding.deviceKeys[actor], binding.deviceRoster.contains(actor) else { return .fail("unknown_txn") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: actorKeys.identityPk) else { return .fail("bad_signature") }
            guard let createdMs = Int64(parsed.envelope.createdMs), createdMs > binding.installedAtMs else { return .fail("stale") }
            tombstoneStore.recordUnpaired(bindingId: binding.bindingId, eventId: parsed.envelope.eventId, atMs: now())
            bindingStore.deactivate(chatId)
            authorizationStore.consumeByTxn(binding.txnId)
            return .ok()
        }

        /// The explicit "cancel this in-flight exchange" action. Local effect applies whether or not
        /// the wire ever reaches the peer.
        public func cancelPairing(txnId: String, reason: String) -> String? {
            guard let txn = pending.get(txnId) else { return nil }
            guard let wire = V2Messages.buildCancel(V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: txnId, chatId: txn.chatId, actorUser: identity.userId, actorIdentityPk: identity.publicKey,
                actorIdentitySk: identity.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
            ), V2Messages.CancelBody(targetTxnId: txnId, reason: reason)) else { return nil }
            tombstoneStore.recordCancelled(txnId: txnId, eventId: V2Envelope.randomId(), atMs: now())
            authorizationStore.consumeByTxn(txnId)
            // SECUTG-HOOK (fix): without this, `pending` kept the entry forever (no phase here means
            // "cancelled" the way `.done` means complete), so `currentTransactionForChat` kept
            // reporting this chat as still mid-exchange and a fresh INVITE stayed refused -- cancelling
            // achieved nothing but a tombstone record. `tombstoneStore` already keeps the permanent
            // "this txnId was cancelled" history for anti-replay purposes; deleting from `pending` only
            // stops it counting as a still-open, blocking transaction.
            pending.delete(txnId)
            return wire
        }

        /// The explicit "unpair" action, targeting the chat's CURRENT binding. nil when there is none.
        ///
        /// PLAN.md 3.39.7 / 3.39.13: a binding installed from a V2Q is signed for by its per-binding identity (a clone's
        /// is the showing device's) and names no pairing transaction (`txnId` is `clone:<bindingId>`, or 3.39.12's
        /// `join:<bindingId>`, not a wire id — receivers use the binding-based fallback in `handleUnpair`). A binding
        /// whose roster does not name this device is torn down locally only and yields an EMPTY wire: the peer would
        /// only ever refuse a wire from it. The local effect (tombstone + deactivate) holds in every case, so a caller
        /// must not read "" as "nothing happened".
        public func unpair(_ chatId: String) -> String? {
            guard let binding = bindingStore.current(chatId) else { return nil }
            let signer = V2OwnIdentity.identity(for: binding, fallback: identity)
            let isRosterMember = binding.deviceKeys[V2OwnIdentity.ownDeviceId(for: binding, fallback: identity)] != nil
            let txnId: String? = Base64Url.decode(binding.txnId)?.count == V2Envelope.idBytes ? binding.txnId : nil
            var wire = ""
            if isRosterMember {
                guard let built = V2Messages.buildUnpair(V2Messages.EnvelopeParams(
                    eventId: V2Envelope.randomId(), txnId: txnId, chatId: chatId, actorUser: signer.userId, actorIdentityPk: signer.publicKey,
                    actorIdentitySk: signer.secretKey, parentBinding: nil, createdMs: String(now()), expiresMs: String(now() + V2Processor.defaultTtlMs)
                ), V2Messages.UnpairBody(bindingId: binding.bindingId)) else { return nil }
                wire = built
            }
            tombstoneStore.recordUnpaired(bindingId: binding.bindingId, eventId: V2Envelope.randomId(), atMs: now())
            bindingStore.deactivate(chatId)
            authorizationStore.consumeByTxn(binding.txnId)
            return wire
        }

        /// SECUTG-HOOK (feature, 2026-09-27, "一键恢复" reset button): every not-yet-terminal transaction
        /// this device holds for `chatId`, in EITHER role, explicitly cancelled via the existing,
        /// already-correct `cancelPairing` — the direct answer to a transaction stuck mid-handshake
        /// (peer vanished, app backgrounded, an abandoned test attempt) that nothing else ever explicitly
        /// cancels. Returns every CANCEL wire built, for the caller to relay to the peer as a courtesy;
        /// the local effect (this chat's slot can accept a fresh invite into again, and `pending` no
        /// longer reports it as mid-exchange — see `cancelPairing`'s own doc) already holds regardless of
        /// whether any of them ever reach the peer.
        public func cancelAllForChat(_ chatId: String) -> [String] {
            // SECUTG-HOOK (fix C0, 2026-09-27): `chatId` is this device's own chat name → `localChatId`.
            let txnIds = pending.values().filter { $0.localChatId == chatId && $0.phase != .done && $0.phase != .conflict }.map { $0.txnId }
            return txnIds.compactMap { cancelPairing(txnId: $0, reason: "user_reset") }
        }

        /// SECUTG-HOOK (fix, 2026-09-27 真机): self-healing for a device whose identity key pair was replaced
        /// (v1's regenerate-and-repair, since removed from every menu). v2's identity IS the keyring identity
        /// (`V2IdentityBridge`), so after a restart every binding installed under the old keys names a device that no
        /// longer exists: the peer still holds the old public key and every E2 fails with bad_signature. A current
        /// binding whose `deviceKeys` does not contain THIS device's own device id — `base64url(sha256(identity
        /// public key))`, the id `installBindingIfDue` writes — is deactivated, exactly as an unpair would; its
        /// history keys stay. The chat then reads as unpaired and can pair afresh. Returns the dropped chat ids.
        ///
        /// PLAN.md 3.39.4 step 7: "this device's identity" is the per-binding one when the binding has it. 3.39.13: a
        /// 3.39.12 add_device join still waiting for its commit is no longer exempt (that flow is gone) — it is
        /// dropped like any other stale binding: deactivated, masters kept, i.e. demoted to read-only history.
        @discardableResult
        public func dropBindingsWithoutOwnIdentity() -> [String] {
            var dropped: [String] = []
            for chatId in bindingStore.allChatIdsWithCurrentBinding().sorted() {
                guard let binding = bindingStore.current(chatId), binding.deviceKeys[V2OwnIdentity.ownDeviceId(for: binding, fallback: identity)] == nil else { continue }
                bindingStore.deactivate(chatId)
                dropped.append(chatId)
            }
            return dropped
        }

        /// SECUTG-HOOK (fix, 2026-09-27 真机): 〔在本机重新配对〕 on a chat whose v2 exchange ended in CONFLICT
        /// ("other_device"). CONFLICT is terminal but is not a binding, and `currentTransactionForChat` still
        /// reports it — so without this a fresh INVITE stays refused forever (`cancelAllForChat` above skips
        /// CONFLICT on purpose). Local only: every CANCEL wire built here is discarded, the peer's copy of that
        /// exchange is already terminal too. Returns how many were dropped.
        @discardableResult
        public func dropConflictsForChat(_ chatId: String) -> Int {
            let txnIds = pending.values().filter { $0.localChatId == chatId && $0.phase == .conflict }.map { $0.txnId }
            return txnIds.compactMap { cancelPairing(txnId: $0, reason: "conflict_repair") }.count
        }

        // MARK: auto-accept (v1.4 section 29)

        /// v1.4 section 29's auto-accept: produces a FIRST ACCEPT with no user action, only when sync
        /// has completed, a standing unexpired grant exists, and the invite is not expired. intent=
        /// replace always needs a human tap regardless of any standing grant.
        /// SECUTG-HOOK (fix C0, 2026-09-27): `localChatId` is passed straight through to `acceptInvite`
        /// (see there). The standing-grant lookup below is left on the envelope chat id — no real caller
        /// reaches this function yet, and grant scoping is its own question.
        public func tryAutoAccept(_ inviteWire: String, localChatId: String? = nil) -> AcceptOutcome? {
            guard syncGate.isSynced else { return nil }
            guard let parsed = V2Messages.parseInvite(inviteWire), V2Messages.verifyTyped(parsed.envelope, identityPkB64: parsed.body.identityPk) else { return nil }
            guard parsed.body.intent != "replace" else { return nil }
            guard let txnId = parsed.envelope.txnId else { return nil }
            guard !isExpired(parsed.envelope.expiresMs) else { return nil }
            guard let policy = authorizationStore.findEligible(chatId: parsed.envelope.chatId, peerUser: parsed.envelope.actorUser, peerSignPk: parsed.body.identityPk, nowMs: now(), txnId: txnId) else {
                return nil
            }
            let outcome = acceptInvite(inviteWire, localChatId: localChatId)
            if outcome.kind == "accept", let acceptedTxnId = outcome.txnId {
                authorizationStore.lockToTxn(policyId: policy.policyId, txnId: acceptedTxnId)
            }
            return outcome
        }

        // MARK: safety code (P-06)

        public func getSafetyCode(_ txnId: String) -> SafetyCode? {
            guard let txn = pending.get(txnId), let peerUser = txn.peerUser, let peerIdentityPk = txn.peerIdentityPk, let peerWire = txn.peerWire else { return nil }
            let isInitiator = txn.role == .initiator
            let input = V2Transcript.Input(
                chatId: txn.chatId, txnId: txnId, parentBinding: nil,
                initiatorUser: isInitiator ? identity.userId : peerUser,
                initiatorDevice: isInitiator ? Base64Url.encode(V2Suite.sha256(identity.publicKey)) : Base64Url.encode(V2Suite.sha256(peerIdentityPk)),
                responderUser: isInitiator ? peerUser : identity.userId,
                responderDevice: isInitiator ? Base64Url.encode(V2Suite.sha256(peerIdentityPk)) : Base64Url.encode(V2Suite.sha256(identity.publicKey)),
                inviteHash: Base64Url.encode(V2Messages.hashWire(isInitiator ? txn.ownWire : peerWire)),
                acceptHash: Base64Url.encode(V2Messages.hashWire(isInitiator ? peerWire : txn.ownWire))
            )
            guard let fingerprint = V2Transcript.computeFullFingerprint(input) else { return nil }
            return SafetyCode(fingerprint: fingerprint, shortCode: V2Transcript.computeShortCode(fingerprint))
        }

        /// SECUTG-HOOK (fix, 2026-09-27): whether an INVITE is past its own `expires_ms`, read against this
        /// processor's injected clock — the same rule `acceptInvite` already refuses expired invites by.
        /// An unparseable wire counts as expired: it can never be accepted either.
        public func isInviteExpired(_ inviteWire: String) -> Bool {
            guard let parsed = V2Messages.parseInvite(inviteWire) else { return true }
            return isExpired(parsed.envelope.expiresMs)
        }

        /// SECUTG-HOOK (fix, 2026-09-27): this device's OWN invite for `txnId` is still waiting for an
        /// ACCEPT (initiator, phase INVITED) but has expired — nobody can accept it any more, so it must
        /// stop reading as "等待对方同意…". False for anything past INVITED or any responder txn.
        public func isOwnInviteExpired(_ txnId: String) -> Bool {
            guard let txn = pending.get(txnId), txn.role == .initiator, txn.phase == .invited else { return false }
            return isInviteExpired(txn.ownWire)
        }

        /// Exposed for tests that need to inspect phase without a full round of message exchange.
        public func phaseOf(_ txnId: String) -> Phase? {
            return pending.get(txnId)?.phase
        }

        /// The by-`chatId` query the UI-facing status/safety-code surface needs (Web reference's own
        /// `currentTransactionForChat`, PLAN.md UI-01): the in-progress exchange this device is a
        /// party to for `chatId`, in EITHER role, or nil once none exists. "In progress" here means
        /// not yet DONE — `V2Binding.BindingStore.current(chatId)` is the by-chatId query for a
        /// completed pairing (a real, installed binding), so this one deliberately stops short of it.
        /// `conflict` is included on purpose: it is a terminal phase but not a binding, and the caller
        /// still needs the txnId to map it to `other_device`.
        ///
        /// Pure read of `pending`, which `startPairing`/`acceptInvite`/`handleInvite`/etc. already
        /// populate — no new bookkeeping, no behavior change for any existing caller.
        public func currentTransactionForChat(_ chatId: String) -> String? {
            // SECUTG-HOOK (fix C0, 2026-09-27): `chatId` is this device's own chat name → `localChatId`.
            return pending.values().first { $0.localChatId == chatId && $0.phase != .done }?.txnId
        }

        /// SECUTG-HOOK (fix C0, 2026-09-27): one-time repair of state written before `localChatId`
        /// existed. The responder used to file its txn, chat-slot claim and binding under the INVITE's
        /// wire chat id — on a real 1:1 chat that is the initiator's view, i.e. THIS device's own user id
        /// (its Saved Messages chat): status for the real chat showed nothing, outgoing text went out in
        /// the clear, and the misplaced binding would E2-wrap everything sent to Saved Messages (the wipe
        /// phrase included). A 1:1 pairing can never legitimately belong to our own Saved Messages, so a
        /// responder txn filed under our own user id whose peer is someone else is re-filed under the
        /// peer's user id — on iOS/macOS exactly the local private chat id (`SecutgAccountRuntime.chatKey`
        /// of a user peer is its bare id, the same string as that user's `ownUserId`). The binding and the
        /// chat-slot claim it produced move with it. Returns whether anything changed (caller persists).
        /// The stale slot claim left under our own user id is harmless (`V2SelectionCas` has no delete by
        /// design; nothing ever pairs in Saved Messages), and older HISTORICAL bindings under our own id
        /// are left where they are.
        @discardableResult
        public func repairResponderTxnsFiledUnderOwnUserId() -> Bool {
            let ownUserId = identity.userId
            var changed = false
            for txn in pending.values() where txn.role == .responder && txn.localChatId == ownUserId {
                guard let peerUser = txn.peerUser, !peerUser.isEmpty, peerUser != ownUserId else { continue }
                txn.localChatId = peerUser
                pending.set(txn.txnId, txn)
                changed = true
                if let misplaced = bindingStore.current(ownUserId), misplaced.txnId == txn.txnId {
                    // A binding already correctly filed under the real chat wins only if it is newer.
                    let newerAlreadyThere = bindingStore.current(peerUser).map { $0.installedAtMs > misplaced.installedAtMs } ?? false
                    if !newerAlreadyThere {
                        bindingStore.install(V2Binding(
                            chatId: peerUser, bindingId: misplaced.bindingId, epoch: misplaced.epoch, deviceRoster: misplaced.deviceRoster,
                            deviceKeys: misplaced.deviceKeys, revision: misplaced.revision, txnId: misplaced.txnId, installedAtMs: misplaced.installedAtMs,
                            verified: false, suspended: false, mismatch: false, mismatchOverride: false
                        ))
                    }
                    bindingStore.deactivate(ownUserId)
                }
                if chatSlot.get(ownUserId) == txn.txnId {
                    if let holder = chatSlot.get(peerUser) {
                        if holder != txn.txnId, slotHolderIsStale(holder) { chatSlot.forceReplace(slotKey: peerUser, candidateId: txn.txnId) }
                    } else {
                        chatSlot.forceReplace(slotKey: peerUser, candidateId: txn.txnId)
                    }
                }
            }
            return changed
        }
    }
}
