import Foundation

/// Applies R1 / P1 / U1 control messages to the keyring, mirroring Web A / Android: signatures are checked against
/// the chat's offline-registered admin key; a rotate whose previous master is unknown is parked and retried
/// after later successes; the persisted epoch label blocks rollback; known masters are idempotent.
public final class RekeyProcessor {
    /// What a P1 in a private chat meant (PLAN.md 3.7):
    /// - peer's P1: `incoming` (invite, nothing derived), `paired` (completed our invite), `alreadyPaired` (same key
    ///   again), `keyChanged` (different key after pairing, the user must confirm), `duplicate` (a second device of
    ///   the peer lost the race, or a history replay; ignored)
    /// - own account's P1: `selfInvited` / `selfPaired` (this device's echo), `otherDevice` (another device of ours
    ///   paired, this one did not take part), `pairingLost` (this device also accepted but lost the race),
    ///   `pairingMoved` (this device was paired, another device re-paired later)
    public enum PairingOutcome: String {
        case incoming, paired, alreadyPaired = "already_paired", keyChanged = "key_changed", duplicate
        case selfInvited = "self_invited", selfPaired = "self_paired", otherDevice = "other_device"
        case pairingLost = "pairing_lost", pairingMoved = "pairing_moved"
    }
    /// Why `startPairing` would not send a `P1` for this chat (PLAN.md 3.25.6 rules 2 and 7)
    public enum PairingRefusal: String { case needsTakeover = "needs_takeover", tooSoon = "too_soon" }

    /// This side announced its key: paired at once, waiting for the peer's P1, or refused
    public enum PairingStart: Equatable { case invited, paired, refused(PairingRefusal) }

    /// Two P1s of the same peer this close together are one "accept" from several devices: the first one wins
    public static let pairingRaceWindowSeconds: Int64 = 120

    public struct Result: Equatable {
        public let isRekey: Bool
        /// PLAN.md 3.31.3: this result came from a `U1` from this chat's paired peer. `ok` says whether it was
        /// acted on; `reason` says why not, or `own_echo` for this device's own notice coming back after it had
        /// already unpaired. Every refusal leaves the keyring exactly as it was.
        public let isUnpair: Bool
        /// PLAN.md 3.34.3: this result came from an `N1` retiring the group's key. `ok` says whether it was acted
        /// on; `reason` says why not, or `own_echo` for this device's own notice coming back. Every refusal leaves
        /// the keyring exactly as it was, and `pending` means "ask again once the admin list has loaded".
        public let isRetire: Bool
        public let ok: Bool
        public let type: Rekey.R1Type?
        public let newKeyId: String?
        public let userId: String?
        public let reason: String?
        public let pairing: PairingOutcome?
        /// PLAN.md 3.25.6 rule 5: set on a `selfPaired` (or `selfInvited`, harmlessly nil in practice) outcome
        /// only when this device's own pairing had already reached `paired` / `keyChanged` before, with the
        /// winning device_id now different from what was stored then — i.e. this completion is a takeover of an
        /// existing pairing, not a first-time one. Always this account's own device_id. An echo arriving while
        /// the chat is already `otherDevice` reports `duplicate` and never a takeover (see `applyOwnEcho`).
        public let takeoverDeviceId: String?
        /// `retire` only (PLAN.md 3.34.1): the mode this generation of the key travels under, so the UI knows
        /// whether to say "getting it" or "go and scan it"
        public let mode: Rekey.KeyMode?
        /// PLAN.md 3.34.6, groups in auto mode only: this device holds the group's signing key and its current
        /// master, and the announcement just registered belongs to somebody who has neither — so an `R1 welcome`
        /// is owed to them. The processor decides it; the glue layer does the sending, because sending is not
        /// something a pure state machine may do on its own. It is also the self-healing half of the auto flow: a
        /// welcome that was lost is re-requested by the member announcing again, and answered here.
        public let owesWelcome: String?
        /// PLAN.md 3.34.6 guardrail: a **group** announcement that REPLACES a key already on file for this user.
        /// Nothing was adopted — the key on file is untouched — and the line asks a person to decide.
        ///
        /// `P1` proves the message is self-consistent and that the server said who sent it. That is enough for a
        /// member arriving, and not enough for a member's key being swapped: adopting swaps automatically would
        /// make control of a user id enough to take over that person's seat in the group. Private chats have
        /// their own road for this (3.25.3, the `keyChanged` pairing outcome) and never come through here.
        public let keyChanged: Bool
        /// PLAN.md 3.35: this result came from a `G2` — the broadcast carrying the group's key in the clear
        /// (auto mode only) — and never from an R1, P1, U1 or N1.
        public let isGroupKey: Bool
        /// `G2` only: which of the six answers it got. The UI renders a line for EVERY one of them — that is
        /// 3.35.4's red line, and the reason this is carried through rather than collapsed into `ok`. The road
        /// this replaced failed by doing nothing visible, so "nothing happened" is the outcome that must not exist.
        public let verdict: G2.Verdict?
        /// PLAN.md 3.38.1: `G2` only — the broadcast carried a password-locked key (`pw=1`). Set for every
        /// verdict, so a stale or own copy still reads as the locked kind it is.
        public let lockedPayload: Bool
        /// PLAN.md 3.38.1 member rule 2: this `apply` stored the FIRST locked record this device has for the group,
        /// so the glue layer drops the group's local message cache and reloads it from the server.
        public let firstLockedAdoption: Bool
        /// PLAN.md 3.38.1 member rule 6: this plain `apply` replaced an active locked key (the admin turned the
        /// group password off). The locked record stays, inactive.
        public let groupPasswordDisabled: Bool
        /// PLAN.md 3.38.2: this result came from a `GP1` group-password policy. `verdict` is its gate answer (the
        /// same six as `G2`), `policyOn` what the policy says (nil when it could not be read).
        public let isGroupPasswordPolicy: Bool
        public let policyOn: Bool?
        /// PLAN.md 3.38.2: this `apply` turned the password ON for this device (none / off before), so the glue
        /// layer drops the group's local message cache and reloads it from the server.
        public let policyTurnedOn: Bool

        /// PLAN.md 3.17 rule 3 + 3.34.7 item 4: whether this verdict changed what the device holds for the chat.
        ///
        /// Fresh applications only. A `rekey` whose master was already in the ring, a notice already obeyed, an
        /// echo of our own — these report, they do not move anything, and every one of them recurs on every
        /// load of the chat's history. Read by the receive hook, which tells the UI layer to sweep the chat's
        /// waiting rows: the control message is itself a road a key arrives by, and it is the fifth such moment,
        /// missing from the four 3.17 listed because no welcome existed when that was written.
        ///
        /// A whitelist, deliberately, and the same one for all three kinds: an `ok` verdict that carries a
        /// reason is REPORTING something that already happened (`already_known`, `already_applied`,
        /// `own_echo`). Written as exclusions — "not `already_known`", "not `own_echo`" — a reason added later
        /// would silently read as a key having moved, and the chat would be swept on every load of its history.
        /// `peer-key` is none of the three: a `P1` has its own road to the screen (the pairing events).
        public var movedKeys: Bool {
            guard ok, reason == nil else { return false }
            return isRekey || isRetire || isUnpair || isGroupKey
        }

        public init(isRekey: Bool, ok: Bool, type: Rekey.R1Type?, newKeyId: String?, userId: String?, reason: String?, pairing: PairingOutcome? = nil, takeoverDeviceId: String? = nil, isUnpair: Bool = false, isRetire: Bool = false, mode: Rekey.KeyMode? = nil, owesWelcome: String? = nil, keyChanged: Bool = false, isGroupKey: Bool = false, verdict: G2.Verdict? = nil, lockedPayload: Bool = false, firstLockedAdoption: Bool = false, groupPasswordDisabled: Bool = false, isGroupPasswordPolicy: Bool = false, policyOn: Bool? = nil, policyTurnedOn: Bool = false) {
            self.isGroupPasswordPolicy = isGroupPasswordPolicy; self.policyOn = policyOn; self.policyTurnedOn = policyTurnedOn
            self.isGroupKey = isGroupKey; self.verdict = verdict
            self.lockedPayload = lockedPayload; self.firstLockedAdoption = firstLockedAdoption
            self.groupPasswordDisabled = groupPasswordDisabled
            self.isRekey = isRekey; self.isUnpair = isUnpair; self.isRetire = isRetire; self.ok = ok; self.type = type; self.newKeyId = newKeyId
            self.userId = userId; self.reason = reason; self.pairing = pairing; self.takeoverDeviceId = takeoverDeviceId
            self.mode = mode; self.owesWelcome = owesWelcome; self.keyChanged = keyChanged
        }
    }

    private static let maxPendingPerChat = 32

    /// Sibling `P1`s parked per chat while this device waits for its own echo. A genuine race is bounded by
    /// delivery latency, so the real number is one, occasionally two; the cap only keeps a chat that never sees
    /// its echo from growing without bound.
    private static let maxHeldClaimsPerChat = 8

    /// An `R1` this device could not judge yet, kept the way the notices are: the raw wire and the sender the
    /// server named, never a parsed-and-half-trusted object. The retry re-runs the whole road from the text.
    private struct ParkedRekey {
        let text: String
        let senderId: String?
    }

    private let ring: KeyRing
    private let clock: KeyRing.Clock
    private let lock = NSLock()
    private var pending: [String: [Rekey.ParsedR1]] = [:]

    /// PLAN.md 3.34.3 rule 1: the wire of every `N1` this chat is still holding because the admin list had not
    /// loaded when it arrived.
    ///
    /// Unlike Web this client does not retry a notice out of the processor — a control row keeps its wire in the
    /// message store and the glue layer re-runs the receive hook once the list arrives
    /// (`secutgRetryParkedControlRows`). What the processor still needs is the *fact* that a notice is waiting
    /// here, because that is what parts "this signature is wrong" from "this signature cannot be checked yet"
    /// for an `R1` that overtook it (3.34.7 item 4). Kept as the texts rather than a flag so that two notices
    /// cannot clear each other's mark.
    private var parkedNotices: [String: [String]] = [:]

    /// PLAN.md 3.34.7 item 4: `R1`s that could not be verified because this device does not yet trust the key
    /// that signed them.
    ///
    /// A rebuild sends the notice and the welcomes in the same second. On a device whose admin list has not
    /// loaded the notice parks (correctly) — and the welcome, arriving a moment later, used to be refused with
    /// `no_admin_key` and rendered as refused, which is where it ended: nothing ever asked about it again. The
    /// notice would then apply, and the key it had announced was already gone. The admin's own ledger refuses to
    /// send a second copy for the same master, so the member stayed keyless for good. That is the exact failure
    /// two phones showed on 2026-09-19.
    ///
    /// Kept as raw wire with the sender, like the notices and for the same reason: the retry has to run the
    /// WHOLE judgement again, signature included, against the key trusted by then — never `apply` on a
    /// `ParsedR1` that was parked before it could be verified, or a forged `R1` would be parked unverified and
    /// applied verified.
    private var parkedRekeys: [String: [ParkedRekey]] = [:]

    /// Sibling `P1`s that arrived while this chat's own `P1` still had no server date, keyed by chat and kept in
    /// arrival order. Deliberately memory-only: both messages are ordinary chat messages, so a process that dies
    /// in here is handed them again — each with its own server date — the next time the history is rebuilt.
    /// Persisting them would mean a new keyring-snapshot field, i.e. a five-client format change, to shorten a
    /// window that is already bounded by the send round-trip.
    private var heldOwnClaims: [String: [OwnP1Race.Claim]] = [:]

    public init(ring: KeyRing, clock: @escaping KeyRing.Clock) {
        self.ring = ring
        self.clock = clock
    }

    /// nil for ordinary text. Never throws for hostile input. `messageDate` (unix seconds, nil = now) orders P1s
    /// of the same user and tells history replays from live messages.
    ///
    /// `isSenderGroupAdmin` answers PLAN.md 3.34.3 rule 1 for an `N1`, and **nil is not false**: it means the
    /// group's member list has not loaded yet, which is a question this layer cannot answer rather than an answer
    /// of no. See `handleN1`.
    public func handle(text: String, chatId: String, senderId: String?, ownUserId: String?, messageDate: Int64? = nil, isSenderGroupAdmin: Bool? = nil) -> Result? {
        lock.lock(); defer { lock.unlock() }
        if let r1 = Rekey.parseR1(text) {
            return handleR1(r1, text: text, chatId: chatId, senderId: senderId, ownUserId: ownUserId)
        }
        if text.hasPrefix("R1:") { return Result(isRekey: true, ok: false, type: .rotate, newKeyId: nil, userId: nil, reason: "malformed") }
        if let p1 = Rekey.parseP1(text) { return handleP1(p1, chatId: chatId, senderId: senderId, ownUserId: ownUserId, messageDate: messageDate) }
        if text.hasPrefix("P1:") { return Result(isRekey: false, ok: false, type: nil, newKeyId: nil, userId: nil, reason: "malformed") }
        if let u1 = Rekey.parseU1(text) { return handleU1(u1, chatId: chatId, senderId: senderId, ownUserId: ownUserId) }
        if text.hasPrefix("U1:") { return unpairResult(ok: false, reason: "malformed") }
        if let n1 = Rekey.parseN1(text) {
            let result = handleN1(n1, chatId: chatId, senderId: senderId, ownUserId: ownUserId, isSenderGroupAdmin: isSenderGroupAdmin)
            // Remembered — or forgotten again — outside `handleN1` so that every road out of it is covered by one
            // line: a notice is waiting here exactly while its own verdict is `pending` (3.34.7 item 4).
            noteNotice(chatId: chatId, text: text, parked: !result.ok && result.reason == "pending")
            return result
        }
        // `Rekey.isN1` is deliberately looser than `parseN1` — a notice whose `at` will not round-trip is admitted
        // by the gate and refused here, so it renders as "ignored: malformed" instead of leaking wire text into
        // the chat as if a person had typed it.
        if text.hasPrefix("N1:") { return retireResult(ok: false, reason: "malformed") }
        if G2.isG2(text) {
            let result = handleG2(text, chatId: chatId, senderId: senderId, ownUserId: ownUserId,
                                  isSenderGroupAdmin: isSenderGroupAdmin)
            // Same one line as `N1`: a broadcast is waiting here exactly while its verdict is `pending`.
            noteNotice(chatId: chatId, text: text, parked: !result.ok && result.reason == "pending")
            return result
        }
        if text.hasPrefix("G2:") { return groupKeyResult(ok: false, verdict: nil, reason: "malformed") }
        // PLAN.md 3.38.2: the group-password policy. Not a notice: it parks through the stored row's verdict
        // (`pending`) like `G2`, but never joins `parkedNotices`, which gates `R1` parking.
        if GP1.isGP1(text) {
            return handleGP1(text, chatId: chatId, senderId: senderId, ownUserId: ownUserId, isSenderGroupAdmin: isSenderGroupAdmin)
        }
        if text.hasPrefix("GP1:") { return policyResult(ok: false, verdict: nil, reason: "malformed") }
        return nil
    }

    /// PLAN.md 3.34.3 / 3.34.4: this group's key has been retired; stop using it and start trusting the key this
    /// notice names.
    ///
    /// Three checks, in this order, then the action. The order is not cosmetic: the cheap structural ones come
    /// first so a notice that is simply not about us never reaches the signature check, and the admin-list
    /// question comes before the signature because an unanswerable question has to park the message rather than
    /// judge it.
    /// PLAN.md 3.35: a `G2` broadcast. Compare the length of this with `handleN1` below — that is the change,
    /// not a detail of it.
    ///
    /// There is no signature to verify, no `P1` to have registered first, no recipient list to be on, and no
    /// round trip. 3.35.1 lists the seven gates the `R1 welcome` road put between "a member reads a message"
    /// and "a member holds the key"; five of them answered "not yet" by doing nothing visible, and four batches
    /// of fixes each removed one only to uncover the next.
    ///
    /// What is left: is this for this chat, did the person the wire names actually send it, is that person an
    /// admin, and is it newer than what we hold. The third question has THREE answers, and the difference
    /// between "no" and "cannot tell yet" is the whole of 3.35.4 rule 2.
    private func handleG2(_ text: String, chatId: String, senderId: String?, ownUserId: String?,
                          isSenderGroupAdmin: Bool?) -> Result {
        // Includes "this build cannot unwrap it" (3.35.8): a broadcast from another fork is not ours to act on,
        // and saying so more precisely would only tell the reader something they cannot use.
        guard let g2 = G2.parse(text) else { return groupKeyResult(ok: false, verdict: nil, reason: "malformed") }
        // The broadcast names its own group, so one copied out of group A cannot be replayed into group B.
        guard g2.chatId == chatId else {
            return groupKeyResult(ok: false, verdict: nil, reason: "wrong_chat", userId: g2.publisherId)
        }
        guard !RekeyProcessor.isPrivateChat(chatId) else {
            return groupKeyResult(ok: false, verdict: nil, reason: "not_group", userId: g2.publisherId)
        }
        guard let senderId = senderId else { return groupKeyResult(ok: false, verdict: nil, reason: "no_sender") }
        // Who the wire claims against who Telegram says delivered it. Without this, anyone could forward a
        // genuine broadcast and have the admin check pass on the original publisher's name.
        guard senderId == g2.publisherId else {
            return groupKeyResult(ok: false, verdict: nil, reason: "sender_mismatch", userId: g2.publisherId)
        }
        // PLAN.md 3.38.1: the opt-in parser. A password-locked key takes its own road; a plain one goes on below
        // exactly as before.
        guard let anyPayload = KeyPayload.parse(g2.keyPayload, allowLocked: true) else {
            return groupKeyResult(ok: false, verdict: nil, reason: "malformed", userId: g2.publisherId)
        }
        let payload: KeyPayload
        switch anyPayload {
        case let .locked(locked):
            return handleLockedG2(g2, locked, chatId: chatId, ownUserId: ownUserId, isSenderGroupAdmin: isSenderGroupAdmin)
        case let .plain(plain):
            payload = plain
        }

        // PLAN.md 3.35.9 (2026-09-20): **ask the keyring, not the address book.**
        //
        // This used to be `publisherId == ownUserId` alone, which cannot tell "this device sent it" from
        // "another device of my account sent it". Keyrings are per-device and never sync by themselves, so the
        // second device held nothing -- and skipped the key on the grounds that it had published it. Its screen
        // said the key was published while it had no key at all: the worst shape a failure can take, because
        // every word on screen says it worked.
        //
        // The publishing device bound the master BEFORE sending (recreateGroupKey does it in one call), and no
        // other device of the account did. So "do I already hold exactly this master" is what separates them,
        // and it needs nothing new on the wire.
        let isOwn = ownUserId != nil && g2.publisherId == ownUserId
            && ring.chatMasterId(chatId) == (try? KeyDerivation.computeMasterId(payload.masterKey))
        let verdict = G2.judge(at: g2.at, boundAt: ring.chatNoticeAt(chatId),
                               publisherIsAdmin: isSenderGroupAdmin, payloadMode: payload.mode, isOwn: isOwn)

        if verdict == .park {
            // `pending` is the same word `N1` parks under, so the glue's "keep the wire on a parked row" rule
            // needs no new case: without the wire the row could never be judged again.
            return groupKeyResult(ok: false, verdict: verdict, reason: "pending", userId: g2.publisherId)
        }
        guard verdict == .apply else {
            // `refuseNotAdmin` deliberately records NOTHING. The admin list can be stale and the anchor is
            // monotonic, so writing it here would let one wrong answer lock the chat out of every later
            // broadcast — the failure mode this whole rewrite exists to remove.
            return groupKeyResult(ok: verdict == .own, verdict: verdict, userId: g2.publisherId)
        }

        // **Everything that can refuse has refused by now.** 3.34.5's red line, untouched by 3.35: the previous
        // master is UNBOUND, never destroyed, or the group's own history stops opening for anyone who kept
        // local ciphertext.
        guard let masterId = try? ring.addMaster(payload.masterKey) else {
            return groupKeyResult(ok: false, verdict: nil, reason: "error", userId: g2.publisherId)
        }
        try? ring.setChatMaster(chatId: chatId, masterId: masterId, label: nil)
        ring.clearChatPairing(chatId)
        ring.clearChatRatchet(chatId)
        if let adminPk = payload.adminPk { try? ring.setChatAdminPk(chatId: chatId, adminPk) }
        // Strictly after the master is bound: a chat switched on with no key to send with is the one state that
        // cannot send at all.
        ring.setChatEncryption(chatId: chatId, enabled: true)
        ring.setChatKeyMode(chatId: chatId, payload.mode)
        // 3.35.5.1: the anchor is what stops the next scroll through history from undoing this.
        ring.setChatNoticeAt(chatId: chatId, g2.at)
        // PLAN.md 3.38.1 member rule 6: a plain key after a locked one means the admin turned the password off.
        // The locked record stays for the old history; it just stops being the group's current key.
        let disabled = ring.supersedeGroupPassword(chatId)
        return Result(isRekey: false, ok: true, type: nil, newKeyId: nil, userId: g2.publisherId, reason: nil,
                      isGroupKey: true, verdict: verdict, groupPasswordDisabled: disabled)
    }

    /// PLAN.md 3.38.1 member rule 1: a `G2` whose key is password-locked. Same gate and same `at` ordering as a
    /// plain one (3.35.4); what differs is what gets stored — the locked record, never a master — and that this
    /// group's masters held in the clear are deleted (the admin wrapped them into `hist`).
    private func handleLockedG2(_ g2: G2.ParsedG2, _ locked: LockedKeyPayload, chatId: String, ownUserId: String?,
                                isSenderGroupAdmin: Bool?) -> Result {
        let result = { (ok: Bool, verdict: G2.Verdict?, reason: String?, first: Bool) -> Result in
            Result(isRekey: false, ok: ok, type: nil, newKeyId: nil, userId: g2.publisherId, reason: reason,
                   isGroupKey: true, verdict: verdict, lockedPayload: true, firstLockedAdoption: first)
        }
        let record = GroupPasswordRecord(fields: locked.fields, at: g2.at, active: true)
        // Refused BEFORE anything is judged or deleted: a record this device could never open would lock the group
        // for good (an unknown KDF, parameters outside what any client accepts, the wrong sizes).
        guard record.isValid else {
            let reason = locked.fields.kdf != GroupPassword.kdfArgon2id13 || locked.fields.version != GroupPassword.version
                ? GroupPasswordUnwrapFailure.unsupportedKdf.rawValue
                : (GroupPassword.paramsInRange(ops: locked.fields.ops, mem: locked.fields.mem)
                    ? GroupPasswordUnwrapFailure.malformed.rawValue : GroupPasswordUnwrapFailure.paramsOutOfRange.rawValue)
            return result(false, nil, reason, false)
        }
        // 3.35.9 for the locked kind: the publishing device stored exactly these fields before sending.
        let isOwn = ownUserId != nil && g2.publisherId == ownUserId && ring.groupPasswordRecord(chatId)?.fields == locked.fields
        let verdict = G2.judge(at: g2.at, boundAt: ring.chatNoticeAt(chatId),
                               publisherIsAdmin: isSenderGroupAdmin, payloadMode: locked.mode, isOwn: isOwn)
        if verdict == .park { return result(false, verdict, "pending", false) }
        guard verdict == .apply else { return result(verdict == .own, verdict, nil, false) }

        let first = ring.adoptLockedGroupKey(chatId: chatId, record: record)
        ring.clearChatPairing(chatId)
        ring.clearChatRatchet(chatId)
        if let adminPk = locked.adminPk { try? ring.setChatAdminPk(chatId: chatId, adminPk) }
        ring.setChatEncryption(chatId: chatId, enabled: true)
        ring.setChatKeyMode(chatId: chatId, locked.mode)
        ring.setChatNoticeAt(chatId: chatId, g2.at)
        return result(true, verdict, nil, first)
    }

    private func handleN1(_ n1: Rekey.ParsedN1, chatId: String, senderId: String?, ownUserId: String?,
                          isSenderGroupAdmin: Bool?) -> Result {
        // The notice names its own group. Without this, one copied out of group A could be replayed into group B,
        // where the sender may well be an admin and the signature is still perfectly valid.
        guard n1.chatId == chatId else { return retireResult(ok: false, reason: "wrong_chat", userId: n1.userId) }
        // Group-only by construction: a private chat has no admin list to check rule 1 against.
        guard !RekeyProcessor.isPrivateChat(chatId) else {
            return retireResult(ok: false, reason: "not_group", mode: n1.mode, userId: n1.userId)
        }
        guard let senderId = senderId else { return retireResult(ok: false, reason: "no_sender") }
        guard senderId == n1.userId else { return retireResult(ok: false, reason: "sender_mismatch") }
        // Our own notice coming back. This device already did everything when it sent it, and there is nothing to
        // complain about either — which is why this is `ok`.
        if let ownUserId = ownUserId, n1.userId == ownUserId {
            return retireResult(ok: true, reason: "own_echo", mode: n1.mode, userId: n1.userId)
        }
        // Rule 1. nil is "the member list has not loaded", a question we cannot answer yet rather than an answer
        // of no. Dropping it here is how a notice gets lost after a long offline stretch, when the history always
        // arrives before the list does.
        guard let isAdmin = isSenderGroupAdmin else {
            return retireResult(ok: false, reason: "pending", mode: n1.mode, userId: n1.userId)
        }
        guard isAdmin else { return retireResult(ok: false, reason: "not_admin", mode: n1.mode, userId: n1.userId) }
        // PLAN.md 3.35.5.2: **in auto mode the notice stops here.** It unbinds the current master and renders a
        // line, and does nothing else — no signature check, no change to the admin key this device trusts, and
        // above all NO ANCHOR.
        //
        // The anchor is the load-bearing one. The admin's button sends `N1` and then `G2` with the same `at`; a
        // notice that recorded the anchor would make the broadcast behind it `stale` by its own announcement and
        // the key would never arrive (3.35.5.1). The other two follow from 3.35.1: rule 2 needs the sender's `P1`
        // to have arrived already — the fourth of the seven silent gates — and the admin key it protects now
        // travels inside the `G2` payload instead.
        //
        // Unbinding still happens, and that part is not optional: a member excluded by this rebuild still holds
        // the old key, so anybody who kept sending under it until the broadcast landed would be writing to them
        // (3.34.4's 「拿到新钥前不能发」). What stops a forgery is rule 1 above: the sender must be a Telegram
        // admin of this group AND be the person the wire names.
        if n1.mode == .auto {
            // PLAN.md 3.35.5.3 (2026-09-20): **only unbind a generation this device has not already passed.**
            //
            // A history page is read newest-first, so somebody who joins afterwards meets the `G2` BEFORE the
            // `N1` that announced it. Unbinding unconditionally took the key away again one message later —
            // the member ended up with nothing, having held the right key for a moment. Exactly the shape of
            // the anchor bug 3.34.7 rule 2 fixed for the other road.
            //
            // The anchor is the right yardstick: `G2` writes it on every broadcast it binds, so "strictly
            // newer than the anchor" means "announces a generation this device has not reached".
            if let anchor = ring.chatNoticeAt(chatId), n1.at <= anchor {
                return retireResult(ok: true, reason: "already_applied", mode: n1.mode, userId: n1.userId)
            }
            ring.clearChatMaster(chatId)
            // PLAN.md 3.38.1: a locked current key is retired the same way — nothing may be sent under it until
            // the broadcast behind this notice lands. The record itself stays for the history.
            ring.deactivateGroupPassword(chatId)
            // PLAN.md 3.35.5.2: `ok` with NO reason, deliberately. A reason here broke two things at once
            // (found on real devices 2026-09-20): this client renders an `ok` retire through an ALLOWLIST of
            // reasons, so anything else read as 「换钥消息已忽略」; and `controlMovedKeys` is `ok && reason
            // == nil` on all five, so a reason meant this verdict did not count as having moved a key — and
            // it just UNBOUND the master, which is exactly when the rows have to be refreshed.
            return retireResult(ok: true, reason: nil, mode: n1.mode, userId: n1.userId)
        }
        // Rule 2: signed by the sender's IDENTITY key, the one their `P1` announced. Not by the new admin key — a
        // member reading this has no reason to trust that key yet, which is the point.
        //
        // No key on file is "not yet", not "no" (2026-09-19). The admin's device posts its own `P1` immediately
        // before the notice (3.34.4), but a history page is read newest-first, so the notice is met before the
        // `P1` that vouches for it. Parked like an unanswered rule 1 — the row keeps its wire and the glue
        // re-judges it when a `P1` registers in this group — never refused for good on the strength of an
        // order. Refusing it was why members who had not collected the admin's key by hand never paired at all.
        guard let senderEdPk = ring.memberEdPk(chatId: chatId, userId: n1.userId) else {
            return retireResult(ok: false, reason: "pending", mode: n1.mode, userId: n1.userId)
        }
        guard Rekey.verifyN1Signature(n1, ed25519Pk: senderEdPk) else {
            return retireResult(ok: false, reason: "bad_signature", mode: n1.mode, userId: n1.userId)
        }
        // Rule 3, the replay guard (PLAN.md 3.34.3, as amended 2026-09-19: 「自动匹配环节不应该受到原来的密钥
        // 的影响」). A rebuild is a NEW request, whatever this device held before — a member who never had a key,
        // one who missed a generation, an admin who started over must all be able to obey it. What is refused
        // is only a notice OLDER than the last one this device obeyed: that is the replay, a history page
        // scrolled back over, and obeying it would unbind the key the member holds right now.
        let trusted = ring.chatAdminPk(chatId)
        // The notice this device already obeyed, read a second time — a history page scrolled back over, a cold
        // start re-deriving its lines. It names the key we trust *right now*, which no other notice can, so it
        // is distinguishable from a replay of an older one and must not be reported as one: "ignored: stale"
        // would be the wrong last word on a notice that was in fact carried out. This client re-derives every
        // control line at draw time, so that wrong word is what the member keeps seeing.
        //
        // Reported, never re-applied. Everything it asks for has already happened, and doing it again would
        // unbind a master the member may have imported since.
        if let trusted = trusted, trusted == n1.newAdminPk {
            // The one write an `already_applied` verdict does make, and 3.34.7 rule 2 still holds: what stays
            // untouched is the key material, and this moves none. Without it a device that reached this
            // generation by SCANNING has no anchor at all — it never obeyed a notice — so the next OLDER notice
            // it meets in history, announcing a key two generations back, passes the freshness test by default
            // and unbinds the key the member just went and fetched. This notice is proof that this device is
            // already on the generation it announces, which is exactly what an anchor records. Monotonic, so a
            // notice older than the anchor cannot lower it either.
            ring.setChatNoticeAt(chatId: chatId, n1.at)
            return retireResult(ok: true, reason: "already_applied", mode: n1.mode, userId: n1.userId)
        }
        // A notice that retires exactly the key this device trusts continues the chain and needs no clock: two
        // co-holders with skewed clocks must not be able to make each other's continuation look "earlier" than
        // an unrelated anchor. Any other notice — a fresh device, a missed generation, an admin who started
        // over with no old key to name — is accepted when it is newer than the last one obeyed, and only then.
        // With nothing obeyed yet, the first notice read is the newest this device knows of, so it applies.
        //
        // `trusted != nil` is part of that test and not decoration. Without it a device that trusts NOTHING
        // takes the chain branch for any notice naming no old key — a group's FIRST notice, which is exactly
        // the one anybody can scroll back to and replay — and skips the freshness check altogether. A device
        // with nothing to continue from has no chain to continue. Found by the macOS port, which read the
        // branch as written rather than as intended.
        let anchor = ring.chatNoticeAt(chatId)
        let isChainStep = trusted != nil && RekeyProcessor.sameKey(trusted, n1.oldAdminPk)
        if !isChainStep, let anchor = anchor, n1.at <= anchor {
            return retireResult(ok: false, reason: "stale", mode: n1.mode, userId: n1.userId)
        }

        // The action (3.34.4). `clearChatMaster` UNBINDS: it drops this chat's pointer to its master and leaves
        // the master itself in the ring, so every message already on this device still opens — `lookupSessionKey`
        // resolves `master_id` globally and never asks which chat it belonged to.
        //
        // 3.34.5 is a red line: DO NOT call `removeMaster` here. Local plaintext is not a fallback (3.19 is off by
        // default, and the people who turn it on hold ciphertext only), so destroying the master destroys the
        // group's history — and an `N1` can be replayed, which would turn one sentence into a way to erase it.
        // The private-chat unpair (`unpairLocked`, 3.31) destroys on purpose; this is the opposite case and the
        // two must not be made to look alike.
        ring.clearChatMaster(chatId)
        try? ring.setChatAdminPk(chatId: chatId, n1.newAdminPk)
        // Strictly after `clearChatMaster`, which wipes this chat's provenance and the old mode with it. The
        // notice carries the mode so the member's device knows, without asking anyone, whether the replacement is
        // coming to it (auto) or whether it has to go and get it (manual) — 3.34.1.
        ring.setChatKeyMode(chatId: chatId, n1.mode)
        // Encryption stays ON. With no master bound that means this chat cannot send — which is exactly right:
        // the member neither keeps sending under the retired key nor silently falls back to plain text while
        // waiting for the replacement.
        ring.setChatEncryption(chatId: chatId, enabled: true)
        // Rule 3's anchor from now on: nothing older than this notice is ever obeyed again. Never lowered, so a
        // continuation of the chain dated before an unrelated anchor applies without moving it backwards.
        ring.setChatNoticeAt(chatId: chatId, n1.at)
        // PLAN.md 3.34.7 item 4. The key this notice announced is trusted now, so anything signed with it that
        // arrived early can be judged at last. Strictly after every write above: the retry verifies against
        // `chatAdminPk`, which the line before this one has just moved.
        _ = retryParkedRekeys(chatId: chatId, ownUserId: ownUserId)
        return retireResult(ok: true, reason: nil, mode: n1.mode, userId: n1.userId)
    }

    /// Records — or clears — the fact that a notice is waiting in this chat. Called with the lock held.
    private func noteNotice(chatId: String, text: String, parked: Bool) {
        var queue = parkedNotices[chatId] ?? []
        queue.removeAll(where: { $0 == text })
        if parked {
            queue.append(text)
            if queue.count > RekeyProcessor.maxPendingPerChat { queue.removeFirst(queue.count - RekeyProcessor.maxPendingPerChat) }
        }
        if queue.isEmpty { parkedNotices.removeValue(forKey: chatId) } else { parkedNotices[chatId] = queue }
    }

    /// How many `N1`s this chat is holding for want of an admin list (PLAN.md 3.34.3 rule 1).
    public func parkedNoticeCount(chatId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return parkedNotices[chatId]?.count ?? 0
    }

    /// How many `R1`s this chat is holding for want of a trusted signing key (PLAN.md 3.34.7 item 4).
    public func parkedRekeyCount(chatId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return parkedRekeys[chatId]?.count ?? 0
    }

    /// PLAN.md 3.38.2: a `GP1` group-password policy. The same gate as `G2` (3.35.4) — the wire names its group and
    /// its publisher, Telegram's sender must be that publisher, and the admin question has three answers (yes /
    /// not known yet → park and retry / no → dropped, shown) — and the same "only the newest `at` counts" rule,
    /// against the policy's OWN anchor: a `GP1` never moves the key anchor and a `G2` never moves this one.
    /// Adopting touches no master.
    private func handleGP1(_ text: String, chatId: String, senderId: String?, ownUserId: String?,
                           isSenderGroupAdmin: Bool?) -> Result {
        guard let gp = GP1.parse(text) else { return policyResult(ok: false, verdict: nil, reason: "malformed") }
        let on = gp.payload.isOn
        guard gp.chatId == chatId else {
            return policyResult(ok: false, verdict: nil, reason: "wrong_chat", userId: gp.publisherId, on: on)
        }
        guard !RekeyProcessor.isPrivateChat(chatId) else {
            return policyResult(ok: false, verdict: nil, reason: "not_group", userId: gp.publisherId, on: on)
        }
        guard let senderId = senderId else { return policyResult(ok: false, verdict: nil, reason: "no_sender", on: on) }
        guard senderId == gp.publisherId else {
            return policyResult(ok: false, verdict: nil, reason: "sender_mismatch", userId: gp.publisherId, on: on)
        }
        // Refused before it is judged: a policy no password could open would shut the group for good.
        if let params = gp.payload.params, !params.isUsable {
            let reason = params.kdf != GroupPassword.kdfArgon2id13 ? GroupPasswordUnwrapFailure.unsupportedKdf
                : (GroupPassword.paramsInRange(ops: params.ops, mem: params.mem) ? .malformed : .paramsOutOfRange)
            return policyResult(ok: false, verdict: nil, reason: reason.rawValue, userId: gp.publisherId, on: on)
        }
        let policy = GroupPasswordPolicy(payload: gp.payload, at: gp.at)
        let current = ring.groupPasswordPolicy(chatId)
        // 3.35.9 for the policy: the publishing device adopted exactly this before sending.
        let isOwn = ownUserId != nil && gp.publisherId == ownUserId && current == policy
        let verdict = G2.judge(at: gp.at, boundAt: current?.at, publisherIsAdmin: isSenderGroupAdmin,
                               payloadMode: .auto, isOwn: isOwn)
        if verdict == .park { return policyResult(ok: false, verdict: verdict, reason: "pending", userId: gp.publisherId, on: on) }
        guard verdict == .apply else {
            return policyResult(ok: verdict == .own, verdict: verdict, userId: gp.publisherId, on: on)
        }
        let turnedOn = ring.adoptGroupPasswordPolicy(chatId: chatId, policy: policy)
        return policyResult(ok: true, verdict: verdict, userId: gp.publisherId, on: on, turnedOn: turnedOn)
    }

    private func policyResult(ok: Bool, verdict: G2.Verdict?, reason: String? = nil, userId: String? = nil,
                              on: Bool? = nil, turnedOn: Bool = false) -> Result {
        return Result(isRekey: false, ok: ok, type: nil, newKeyId: nil, userId: userId, reason: reason, verdict: verdict,
                      isGroupPasswordPolicy: true, policyOn: on, policyTurnedOn: turnedOn)
    }

    private func groupKeyResult(ok: Bool, verdict: G2.Verdict?, reason: String? = nil, userId: String? = nil) -> Result {
        return Result(isRekey: false, ok: ok, type: nil, newKeyId: nil, userId: userId, reason: reason,
                      isGroupKey: true, verdict: verdict)
    }

    private func retireResult(ok: Bool, reason: String?, mode: Rekey.KeyMode? = nil, userId: String? = nil) -> Result {
        return Result(isRekey: false, ok: ok, type: nil, newKeyId: nil, userId: userId, reason: reason,
                      isRetire: true, mode: mode)
    }

    /// Byte equality that treats "no key" as a value, so a group's first notice matches "nothing trusted yet".
    private static func sameKey(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return a == b
    }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): the `handleU1` refusals that only mean "this side had nothing to
    /// unpair" — no pairing with that peer (`not_paired_peer`), or a pairing record that never learned the
    /// peer's signing key (`no_peer_key`, e.g. a leftover v1 "invited"). A real device showed
    /// "🔑 换钥消息已忽略：no_peer_key" for exactly this, a raw reason code for a notice that changed nothing
    /// and threatened nothing. Genuine refusals — a bad signature, a sender mismatch, a stale replay — are not
    /// in this set and keep their own line.
    public static func isNothingToUnpair(_ reason: String) -> Bool {
        return reason == "no_peer_key" || reason == "not_paired_peer"
    }

    /// PLAN.md 3.31.3. Every check below has to pass, in this order, and any one of them failing means the
    /// keyring is left untouched — this is a message that destroys keys, so "probably fine" is not a state it
    /// may act on.
    private func handleU1(_ u1: Rekey.ParsedU1, chatId: String, senderId: String?, ownUserId: String?) -> Result {
        // Rule 2: the notice names who is revoking, and that has to be who actually sent it. Without this one
        // check, a copy of somebody's valid notice could be replayed into the chat by anyone at all.
        guard let senderId = senderId else { return unpairResult(ok: false, reason: "no_sender") }
        guard senderId == u1.userId else { return unpairResult(ok: false, reason: "sender_mismatch") }
        // Our own notice coming back. This device unpaired before it sent it, so there is nothing left to do —
        // and nothing to complain about either, which is why this is `ok`.
        if let ownUserId = ownUserId, u1.userId == ownUserId { return unpairResult(ok: true, reason: "own_echo") }
        // Unpairing is a one-to-one idea; a `U1` in a group means nothing.
        guard RekeyProcessor.isPrivateChat(chatId) else { return unpairResult(ok: false, reason: "not_private") }
        // Rule 3: a stranger saying this about a chat they are not the peer of means nothing.
        guard let pairing = ring.chatPairing(chatId), pairing.peerId == u1.userId else {
            return unpairResult(ok: false, reason: "not_paired_peer")
        }
        // Rule 4, the one that keeps this from being a remote destruct button: not "a valid signature" but
        // "a signature by the key THIS chat registered for THIS peer".
        guard let peerEdPk = ring.memberEdPk(chatId: chatId, userId: u1.userId) else {
            return unpairResult(ok: false, reason: "no_peer_key")
        }
        guard Rekey.verifyU1Signature(u1, ed25519Pk: peerEdPk) else {
            return unpairResult(ok: false, reason: "bad_signature")
        }
        // Rule 5: a notice written about a pairing that has since been replaced must not take down its
        // replacement. An `invited` pairing has no `pairedAt` to compare against — that is the peer withdrawing
        // an invitation, and there is no earlier round for it to be stale against.
        if let pairedAt = pairing.pairedAt, u1.at < pairedAt { return unpairResult(ok: false, reason: "stale") }
        // The same body the local menu entry runs, reached without retaking the lock this call already holds.
        // A second implementation of "what unpairing does" is how the two halves drift until one of them stops
        // destroying something.
        unpairLocked(chatId: chatId)
        return unpairResult(ok: true, reason: nil)
    }

    private func unpairResult(ok: Bool, reason: String?) -> Result {
        return Result(isRekey: false, ok: ok, type: nil, newKeyId: nil, userId: nil, reason: reason, isUnpair: true)
    }

    public func pendingCount(chatId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending[chatId]?.count ?? 0
    }

    private func handleP1(_ p1: Rekey.ParsedP1, chatId: String, senderId: String?, ownUserId: String?, messageDate: Int64?) -> Result {
        guard let senderId = senderId else { return peerFailure("no_sender") }
        guard Rekey.verifyP1(p1, senderId: senderId) else {
            return peerFailure(senderId == p1.userId ? "bad_signature" : "sender_mismatch")
        }
        let isPrivate = RekeyProcessor.isPrivateChat(chatId)
        if isPrivate, let ownUserId = ownUserId, p1.userId == ownUserId {
            return handleOwnP1(p1, chatId: chatId, messageDate: messageDate)
        }
        let peerInPrivateChat = isPrivate && p1.userId == chatId
        if peerInPrivateChat, let pairing = ring.chatPairing(chatId) {
            if let settled = settlePeerP1(p1, chatId: chatId, pairing: pairing, messageDate: messageDate) { return settled }
        }
        // Read before the write: whether this key is NEW or REPLACES one is the difference between a member
        // joining and a member's device changing, and the second is never automated (PLAN.md 3.34.6).
        let knownBefore = isPrivate ? nil : registeredMemberKeys(chatId: chatId, userId: p1.userId)
        if let known = knownBefore, known.x25519Pk != p1.x25519Pk || known.ed25519Pk != p1.ed25519Pk {
            // Deliberately NOT adopted, and deliberately not refused either: the announcement is real, it is just
            // not something this device may act on by itself. Storing the key while merely declining to welcome
            // would only move the hole one step back — every later reset / welcome / member list would read it.
            // The key on file stays as it is until a person confirms the change (`adoptMemberKey`).
            return Result(isRekey: false, ok: true, type: nil, newKeyId: nil, userId: p1.userId, reason: nil,
                          keyChanged: true)
        }
        do {
            try ring.setMemberPk(chatId: chatId, userId: p1.userId, p1.x25519Pk)
            try ring.setMemberEdPk(chatId: chatId, userId: p1.userId, p1.ed25519Pk)
        } catch { return peerFailure("malformed") }
        guard peerInPrivateChat else {
            let owed = owesAutoWelcome(chatId: chatId, userId: p1.userId, ownUserId: ownUserId, knownBefore: knownBefore,
                                       x25519Pk: p1.x25519Pk, ed25519Pk: p1.ed25519Pk)
            return Result(isRekey: false, ok: true, type: nil, newKeyId: nil, userId: p1.userId, reason: nil,
                          owesWelcome: owed ? p1.userId : nil)
        }
        let at = messageTime(messageDate)
        if ring.chatPairing(chatId)?.state == .invited, completePairing(chatId: chatId, peerId: p1.userId, pairedAt: at) {
            return peerResult(p1.userId, .paired)
        }
        return peerResult(p1.userId, .incoming)
    }

    /// Both halves of what this chat has on file for a member — a device is its pair of keys, so a half-written
    /// registration counts as none at all.
    private func registeredMemberKeys(chatId: String, userId: String) -> (x25519Pk: [UInt8], ed25519Pk: [UInt8])? {
        guard let x = ring.memberPk(chatId: chatId, userId: userId),
              let ed = ring.memberEdPk(chatId: chatId, userId: userId) else { return nil }
        return (x, ed)
    }

    /// PLAN.md 3.34.6: whether an announcement just registered in a group obliges this device to send that member
    /// an `R1 welcome` without being asked.
    ///
    /// Every condition is a reason the answer would otherwise be wrong rather than merely unnecessary: manual
    /// mode distributes face to face and nothing may send a key for it; a device without the chat's signing key
    /// cannot produce an `R1` at all; a device without a master has nothing to hand out; and our own
    /// announcement coming back is not somebody asking for a key.
    ///
    /// The same key announced again still owes a welcome — that is the self-healing half: a member whose copy
    /// never arrived announces again and gets answered.
    private func owesAutoWelcome(chatId: String, userId: String, ownUserId: String?,
                                 knownBefore: (x25519Pk: [UInt8], ed25519Pk: [UInt8])?,
                                 x25519Pk: [UInt8], ed25519Pk: [UInt8]) -> Bool {
        guard !RekeyProcessor.isPrivateChat(chatId) else { return false }
        if let ownUserId = ownUserId, userId == ownUserId { return false }
        guard ring.chatKeyMode(chatId) == .auto else { return false }
        guard ring.chatAdminSk(chatId) != nil, ring.chatMasterId(chatId) != nil else { return false }
        // Unreachable through `handleP1`, which returns before adopting a changed key — kept because this
        // predicate has to remain true on its own terms, not because of where it happens to be called from.
        if let known = knownBefore, known.x25519Pk != x25519Pk || known.ed25519Pk != ed25519Pk { return false }
        return true
    }

    /// The peer's P1 while this chat already has a pairing record; nil means "carry on as a fresh registration".
    private func settlePeerP1(_ p1: Rekey.ParsedP1, chatId: String, pairing: KeyRing.Pairing, messageDate: Int64?) -> Result? {
        let knownX = ring.memberPk(chatId: chatId, userId: p1.userId)
        let knownEd = ring.memberEdPk(chatId: chatId, userId: p1.userId)
        let same = knownX == p1.x25519Pk && knownEd == p1.ed25519Pk
        if pairing.state == .otherDevice {
            // This device is out of the pairing; remember the key but never offer "accept" here
            if !same {
                try? ring.setMemberPk(chatId: chatId, userId: p1.userId, p1.x25519Pk)
                try? ring.setMemberEdPk(chatId: chatId, userId: p1.userId, p1.ed25519Pk)
            }
            return peerResult(p1.userId, .otherDevice)
        }
        guard pairing.state == .paired || pairing.state == .keyChanged, knownX != nil else { return nil }
        if same { return peerResult(p1.userId, .alreadyPaired) }
        let at = messageTime(messageDate)
        let pairedAt = pairing.pairedAt ?? 0
        // Derived before the replay check, because since 3.25.11 the check itself needs it: the two `P1`s are
        // ordered by the shared `(at, device_id)` total order, not by date alone. A key whose `device_id` will
        // not derive cannot be placed in that order at all, and the safe direction there is to change nothing —
        // a `P1` must never swap the master on a judgement this code could not actually make.
        guard let newPeerDeviceId = try? DeviceIdentity.derive(x25519Pk: p1.x25519Pk).deviceId else {
            return peerResult(p1.userId, .duplicate)
        }
        /*
         PLAN.md 3.25.10 (2026-09-20 用户真机): **only a genuine history replay is swallowed now.**

         This used to swallow anything inside `pairingRaceWindowSeconds` of the pairing as well, on the
         reading that a second `P1` this soon can only be the peer's other device losing the accept race
         (rule 8). It cannot tell that from the peer deliberately re-keying — 「重新生成密钥并重新配对」
         produces exactly the same thing: same person, different key, moments after pairing. The user hit
         it on real phones: the peer regenerated, its own screen said 配对完成, this side said
         「已忽略重复的配对信息」 and stayed on the old key, and from then on nothing the peer sent could be
         opened. The same act 121 seconds later was reported correctly, so the clock was the whole difference.

         A `P1` that does not sort after the one this chat is paired to carries nothing new by construction
         and is re-read on every scroll through the history, so it is still swallowed. The comparison is
         `OwnP1Race.sortsFirst` — the very function the own-account axis judges by (PLAN.md 3.25.11) — so an
         exact tie between two of the peer's devices is broken the same way on both sides of the chat
         instead of by whichever message happened to arrive first.
         */
        if !OwnP1Race.sortsFirst(OwnP1Race.Claim(at: pairedAt, deviceId: pairing.peerDeviceId ?? ""),
                                 OwnP1Race.Claim(at: at, deviceId: newPeerDeviceId)) {
            // PLAN.md 3.25.3 rule 2: a lower bound on "how many devices has this peer used here", nothing more —
            // memberPk / memberEdPk are deliberately left untouched, this key never gets a chance to become the
            // session source
            try? ring.setChatPairing(chatId: chatId, pairing.with(peerSeenDeviceIds: DeviceIdentity.pushSeenDeviceId(pairing.peerSeenDeviceIds, newPeerDeviceId)))
            return peerResult(p1.userId, .duplicate)
        }
        /*
         PLAN.md 3.25.11 (2026-09-20 用户定，真机之后): **adopted on sight — the tap is gone.**

         This used to stop at `keyChanged`: the new key was remembered, the master was NOT swapped, and the
         user had to find a button and press it. Two things went wrong with that on real phones. The obvious
         one is that people do not find the button. The other one is worse: `rekeySigner` refuses every
         rotate from the peer while the chat sits in `keyChanged`, so the side that was waiting for a
         confirmation answered `no_admin_key` to everything the other side sent — one direction worked and
         the other did not, for ever, and neither screen explained it.

         Nothing is sent to adopt it. DH is symmetric, so re-deriving from the peer's new public key lands on
         exactly the master the peer computed when they regenerated.

         The verdict is still `keyChanged` and the line still says the peer's key changed — that is worth
         knowing — it just no longer blocks. What is given up is PLAN 3.25.3 rule 3's guardrail: whoever
         controls the peer's Telegram account can now replace the key silently. The user was shown that
         trade and chose this.
         */
        try? ring.setMemberPk(chatId: chatId, userId: p1.userId, p1.x25519Pk)
        try? ring.setMemberEdPk(chatId: chatId, userId: p1.userId, p1.ed25519Pk)
        // PLAN.md 3.25.3 rule 3: the key being displaced moves into peerSeenDeviceIds now, at the moment it is
        // replaced — not deferred to whenever the user gets around to looking at the line.
        let seen = (pairing.peerDeviceId != nil && pairing.peerDeviceId != newPeerDeviceId)
            ? DeviceIdentity.pushSeenDeviceId(pairing.peerSeenDeviceIds, pairing.peerDeviceId!) : pairing.peerSeenDeviceIds
        try? ring.setChatPairing(chatId: chatId, pairing.withPeerKeyChanged(peerDeviceId: newPeerDeviceId, peerSeenDeviceIds: seen))
        // Re-derives the DH master and lands the chat back on `paired`; the old master stays in the ring, so
        // everything already received still opens.
        _ = completePairing(chatId: chatId, peerId: p1.userId, pairedAt: at)
        return peerResult(p1.userId, .keyChanged)
    }

    /// A P1 our own account sent in a private chat, coming back through the chat. With our own key it is this
    /// device's own invite / accept echoing back; with a different key it is another device of this account
    /// competing for, or taking over, the pairing (PLAN.md 3.7 rules 8–9): this device steps out, stops
    /// encrypting and shows how to re-pair here.
    ///
    /// Which of the two P1s counts is decided by `OwnP1Race.judge`, never by arrival order — both devices see
    /// both messages and must reach the same verdict from them whichever order they happen to arrive in.
    private func handleOwnP1(_ p1: Rekey.ParsedP1, chatId: String, messageDate: Int64?) -> Result {
        let pairing = ring.chatPairing(chatId)
        // PLAN.md 3.25.3 rule 1: the winning key was only ever compared, then thrown away — now its device_id
        // (never the key itself) is kept as `ownDeviceId`, whichever account device won
        let senderDeviceId = try? DeviceIdentity.derive(x25519Pk: p1.x25519Pk).deviceId
        let at = messageTime(messageDate)
        let holder = pairingHolder(pairing)
        if let identity = ring.identity, identity.x25519Pk == p1.x25519Pk, identity.ed25519Pk == p1.ed25519Pk {
            return applyOwnEcho(userId: p1.userId, ownDeviceId: senderDeviceId, at: at, chatId: chatId,
                                hasServerDate: messageDate != nil, pairing: pairing, holder: holder)
        }
        // A P1 whose device_id will not derive cannot be judged; yielding is the safe direction (this device
        // stops encrypting and says so, rather than encrypting with a key the peer may not hold). It is also not
        // worth parking: no later echo can make an underivable id comparable.
        guard let senderDeviceId = senderDeviceId else {
            return judgeSiblingClaim(p1.userId, nil, chatId: chatId, pairing: pairing, holder: holder, at: at)
        }
        let claim = OwnP1Race.Claim(at: at, deviceId: senderDeviceId)
        if holdSiblingClaim(chatId: chatId, pairing: pairing, claim: claim) {
            // Nothing decided and nothing changed, which is what `duplicate` renders: the verdict lands on this
            // device's own `P1` line instead, as soon as its echo makes the two dates comparable.
            return peerResult(p1.userId, .duplicate)
        }
        return judgeSiblingClaim(p1.userId, claim, chatId: chatId, pairing: pairing, holder: holder, at: at)
    }

    /// PLAN.md 3.7 rule 13: **the verdict is always taken between two server dates.**
    ///
    /// A sibling's `P1` carries one. This device's own carries one too — but only once it has echoed back; until
    /// then `startedAt` is empty, because `startPairing` has no server clock to read and this machine's own is a
    /// number the sibling can neither see nor reproduce. Comparing the two would put a server date against a wall
    /// clock: a device 30 seconds fast reads the genuinely earlier sibling as later and keeps a pairing the peer
    /// never adopted, and the sibling, reading the same facts equally wrongly, keeps its own. Both encrypt, the
    /// peer opens one of them. `pairingRaceWindowSeconds` cannot absorb that: skew *shifts* the comparison rather
    /// than widening it.
    ///
    /// So the claim is parked and the state left exactly as it was. The alternative — stepping out while the echo
    /// is missing — is worse in the same situation: both devices would step out, nobody would encrypt, and the
    /// peer would go on encrypting to a pairing no device of ours holds.
    ///
    /// Returns `true` when the claim was parked rather than judged. A device that never sent a `P1` here (no
    /// pairing record) has nothing to wait for and yields to the sibling at once, as it always did.
    private func holdSiblingClaim(chatId: String, pairing: KeyRing.Pairing?, claim: OwnP1Race.Claim) -> Bool {
        guard ring.identity != nil, let pairing = pairing,
              pairing.state != .otherDevice, pairing.startedAt == nil else { return false }
        let held = heldOwnClaims[chatId] ?? []
        // The same message can be rebuilt more than once (history refetches, a re-render of the same viewport);
        // parking it twice would judge it twice
        if held.contains(claim) { return true }
        heldOwnClaims[chatId] = Array((held + [claim]).suffix(RekeyProcessor.maxHeldClaimsPerChat))
        return true
    }

    /// One sibling `P1` measured against whatever currently holds this chat's pairing (PLAN.md 3.7 rule 13).
    /// `claim` is nil for a `P1` whose `device_id` will not derive, which cannot be judged and therefore loses.
    private func judgeSiblingClaim(_ userId: String, _ claim: OwnP1Race.Claim?, chatId: String,
                                   pairing: KeyRing.Pairing?, holder: OwnP1Race.Claim?, at: Int64) -> Result {
        let verdict = claim.map {
            OwnP1Race.judge(holder: holder, incoming: $0, windowSeconds: RekeyProcessor.pairingRaceWindowSeconds)
        } ?? .lost
        // `olderRound` is the genuine history replay the old guard meant to catch; `won` is the case it got
        // backwards, where this device's own P1 is the earlier one and the sibling lost the race. Neither
        // touches any state: this device keeps whatever it already had.
        if verdict == .olderRound || verdict == .won { return peerResult(userId, .duplicate) }
        let senderDeviceId = claim?.deviceId
        let previous = pairing?.state
        if previous == .paired || previous == .invited || previous == .keyChanged {
            ring.clearChatMaster(chatId)
            ring.clearChatRatchet(chatId)
            ring.setChatEncryption(chatId: chatId, enabled: false)
        }
        try? ring.setChatPairing(chatId: chatId, KeyRing.Pairing(
            peerId: chatId, state: .otherDevice, verified: false, pairedAt: at, ownDeviceId: senderDeviceId,
            peerDeviceId: pairing?.peerDeviceId, peerSeenDeviceIds: pairing?.peerSeenDeviceIds))
        // Lost inside the window = this device answered the same invite a moment too late ("本次配对作废");
        // outside it = the user deliberately re-paired over there and the pairing moved (rule 9). `keyChanged`
        // keeps falling through to `otherDevice` as it always has, which reads oddly — that state did hold the
        // pairing, so "this device did not take part" is not quite what happened. Left alone deliberately: it
        // is a wording question on a line this change does not otherwise touch.
        let outcome: PairingOutcome = previous == .invited ? .pairingLost
            : previous == .paired ? (verdict == .lost ? .pairingLost : .pairingMoved)
            : .otherDevice
        return peerResult(userId, outcome)
    }

    /// Judges every claim parked by `holdSiblingClaim`, now that this chat's own `P1` has a server date.
    ///
    /// The claims are replayed in arrival order, which changes nothing about the outcome — `OwnP1Race.judge` is a
    /// strict total order, so a later sibling measured against an earlier one that already took the pairing
    /// simply loses again — but it keeps each verdict reading against the state the one before it left behind.
    ///
    /// The result handed back is the last one that actually moved this device out of the pairing, so the echo's
    /// own line can carry it: the delayed loss is rendered by the same "本次配对作废" / "配对已转移" lines an
    /// immediate one uses, on this device's own `P1` instead of the sibling's. nil means nothing moved — either
    /// no claim was parked, or this device won them all.
    private func releaseHeldClaims(_ userId: String, chatId: String) -> Result? {
        guard let held = heldOwnClaims[chatId], !held.isEmpty else { return nil }
        // The echo of a `P1` we are still sending (the send-side hook, which has no message yet) carries no
        // server date, so it does not make the comparison possible: keep waiting for the real one.
        guard pairingHolder(ring.chatPairing(chatId)) != nil else { return nil }
        heldOwnClaims.removeValue(forKey: chatId)
        var decided: Result?
        for claim in held {
            let pairing = ring.chatPairing(chatId)
            let result = judgeSiblingClaim(userId, claim, chatId: chatId, pairing: pairing,
                                           holder: pairingHolder(pairing), at: claim.at)
            if result.pairing != .duplicate { decided = result }
        }
        return decided
    }

    /// This device's own P1 coming back from the server. Three things happen here and nowhere else:
    ///
    /// 1. `startedAt` is written, and this is its only writer. `startPairing` leaves it empty on purpose: the
    ///    field has to hold the message's *server* date, the one a sibling device can also see, and at send time
    ///    no such number exists. Empty is therefore meaningful — it says "the echo has not landed", which is
    ///    exactly what `holdSiblingClaim` keys off.
    /// 2. Any sibling P1 parked while that was true is judged now, against the date just written, and a delayed
    ///    loss is returned in place of this echo's own outcome so the existing "本次配对作废" line can be
    ///    rendered on this device's own P1.
    /// 3. A P1 of ours arriving while the chat is already `otherDevice` does **not** claim the pairing back.
    ///    That state means this device has already compared the two P1s and lost; the losing P1 echoing back
    ///    afterwards (history order need not match send order) is the very message it lost with, and letting it
    ///    overwrite `ownDeviceId` would make this device name itself as the holder while its own state says the
    ///    holder is elsewhere.
    private func applyOwnEcho(userId: String, ownDeviceId: String?, at: Int64, chatId: String,
                              hasServerDate: Bool, pairing: KeyRing.Pairing?, holder: OwnP1Race.Claim?) -> Result {
        if pairing?.state == .otherDevice {
            // Nothing can be parked in this state — `holdSiblingClaim` refuses it, because the holder on record
            // is already a server date and every sibling can be judged on the spot
            heldOwnClaims.removeValue(forKey: chatId)
            return peerResult(userId, .duplicate)
        }
        // An undecipherable device_id leaves whatever was stored in place rather than clearing it
        let ownDeviceId = ownDeviceId ?? pairing?.ownDeviceId
        // PLAN.md 3.25.6 rule 5: a takeover only on the own-device axis — this device's P1 just won, and a
        // different one of this account's devices held the pairing before it
        let wasEstablished = pairing?.state == .paired || pairing?.state == .keyChanged
        let isTakeover = wasEstablished && pairing?.ownDeviceId != nil && pairing?.ownDeviceId != ownDeviceId
        if let pairing = pairing {
            // Only a real server date is worth having; the send-side hook runs before the message exists and
            // passes none. An echo from before this round is one of our own older P1s and must not move it.
            let isOlderRound = holder.map { at < $0.at - RekeyProcessor.pairingRaceWindowSeconds } ?? false
            let startedAt = hasServerDate && !isOlderRound ? at : pairing.startedAt
            if pairing.ownDeviceId != ownDeviceId || pairing.startedAt != startedAt {
                try? ring.setChatPairing(chatId: chatId, KeyRing.Pairing(
                    peerId: pairing.peerId, state: pairing.state, verified: pairing.verified,
                    startedAt: startedAt, pairedAt: pairing.pairedAt, ownDeviceId: ownDeviceId,
                    peerDeviceId: pairing.peerDeviceId, peerSeenDeviceIds: pairing.peerSeenDeviceIds))
            }
        }
        if let delayed = releaseHeldClaims(userId, chatId: chatId) { return delayed }
        return Result(
            isRekey: false, ok: true, type: nil, newKeyId: nil, userId: userId, reason: nil,
            pairing: pairing?.state == .paired ? .selfPaired : .selfInvited,
            takeoverDeviceId: isTakeover ? ownDeviceId : nil)
    }

    /// The P1 that currently holds this chat's pairing on our own side of it, as `OwnP1Race.judge` needs it.
    ///
    /// Which record carries it depends on who the holder is. While this device holds the pairing the holder is
    /// this device, so the answer is its own identity plus `startedAt` (its own P1's date, on the server clock
    /// once `applyOwnEcho` has seen the echo). `ownDeviceId` is deliberately *not* used there: `startPairing`
    /// carries the previous winner's id through a re-pair on purpose, so during a takeover it still names the
    /// device being taken over from. Once this device has stepped out, the holder is the sibling that beat it,
    /// and the `otherDevice` record stores exactly that pair — which is why this reads `pairedAt` +
    /// `ownDeviceId` there and never `startedAt`, which that record omits.
    ///
    /// nil means this device has no claim to compare yet. With no pairing at all it never sent a `P1` here, so
    /// any sibling wins — the safe direction: this device stops encrypting and says so, rather than encrypting
    /// with a key the peer may not hold. With a pairing whose `startedAt` is still empty the echo simply has not
    /// landed, and `holdSiblingClaim` parks the sibling instead of letting it win by default.
    private func pairingHolder(_ pairing: KeyRing.Pairing?) -> OwnP1Race.Claim? {
        guard let pairing = pairing else { return nil }
        if pairing.state == .otherDevice {
            guard let pairedAt = pairing.pairedAt, let ownDeviceId = pairing.ownDeviceId else { return nil }
            return OwnP1Race.Claim(at: pairedAt, deviceId: ownDeviceId)
        }
        guard let startedAt = pairing.startedAt, let identity = ring.identity,
              let ownDeviceId = try? DeviceIdentity.derive(x25519Pk: identity.x25519Pk).deviceId else { return nil }
        return OwnP1Race.Claim(at: startedAt, deviceId: ownDeviceId)
    }

    private func messageTime(_ messageDate: Int64?) -> Int64 {
        return messageDate ?? clock() / 1000
    }

    /// PLAN.md 3.25.6 rule 7: how long a takeover started right now would still be swallowed for, in seconds,
    /// or `0` when it would get through.
    ///
    /// The peer applies rule 13 to the `P1` this device is about to send: a different key arriving within
    /// `pairingRaceWindowSeconds` of the peer's own `pairedAt`, or dated before it, is a `duplicate` — no rekey,
    /// no warning. The sibling that currently holds the pairing reads its own `P1` as the earlier one and does
    /// not step aside either. Only the device that sent it would believe it had taken over, and everything it
    /// then encrypted would be unreadable to the peer.
    ///
    /// What is measured is the `otherDevice` record's `pairedAt`, which is the server date of the sibling `P1`
    /// that won — the same number the peer wrote down when that `P1` completed its pairing. The comparison puts
    /// a local wall clock against that server date, so this is a prediction, not a verdict. Both ways of being
    /// wrong are mild: a clock running slow refuses a takeover that would have worked (the user waits and taps
    /// again), and a clock running fast lets a doomed one through, which is exactly what happens today. Nothing
    /// here can make a takeover fail that would otherwise have succeeded silently.
    ///
    /// The result is clamped to the window even when `pairedAt` lies ahead of this clock, so a skewed or
    /// hand-edited record can never turn into a "try again in three days".
    public static func takeoverSwallowedSeconds(_ pairing: KeyRing.Pairing?, nowSeconds: Int64) -> Int64 {
        guard let pairing = pairing, pairing.state == .otherDevice, let pairedAt = pairing.pairedAt else { return 0 }
        let remaining = pairingRaceWindowSeconds - (nowSeconds - pairedAt)
        return remaining > 0 ? min(remaining, pairingRaceWindowSeconds) : 0
    }

    /// Why `startPairing` would refuse this chat right now, or nil when it would go ahead.
    ///
    /// Separate from `startPairing` and writing nothing, so that a caller with an irreversible step of its own —
    /// `regenerateAndRepair` throws the identity key pair away before it pairs — can ask before taking it,
    /// rather than discovering the refusal once the old key is already gone.
    public func takeoverRefusal(chatId: String, confirmedTakeover: Bool) -> PairingRefusal? {
        lock.lock(); defer { lock.unlock() }
        return refusal(chatId: chatId, confirmedTakeover: confirmedTakeover)
    }

    /// `takeoverRefusal` with the lock already held (NSLock is not recursive).
    private func refusal(chatId: String, confirmedTakeover: Bool) -> PairingRefusal? {
        let pairing = ring.chatPairing(chatId)
        // Every other state is this device's own business: `invited`, `paired`, `keyChanged` and "no pairing at
        // all" all mean the pairing is here, or nowhere, and re-pairing costs no other device its own.
        guard pairing?.state == .otherDevice else { return nil }
        if !confirmedTakeover { return .needsTakeover }
        return RekeyProcessor.takeoverSwallowedSeconds(pairing, nowSeconds: clock() / 1000) > 0 ? .tooSoon : nil
    }

    /// This side announces its key in a private chat (invite or accept): pairs at once when the peer's key is
    /// already known, otherwise waits in `invited`. The caller sends this device's P1 as a plain message.
    ///
    /// Returns `.refused` instead when this device is out of the pairing (PLAN.md 3.25.6 rules 2 and 7).
    /// `confirmedTakeover` is the caller's statement that the user has been through rule 2's confirmation — an
    /// ordinary "accept" never sets it, which is what keeps a stale invite dialog, or an old control line on a
    /// device that lost the race, from quietly taking the pairing back. The guard lives here, at the one throat
    /// every entry point goes through, rather than at each of them: those entry points keep appearing (an old
    /// row in the history, a dialog raised from somewhere else), and the cost of missing one is a takeover with
    /// no warning at all. A refusal happens before anything is written, so the chat is left exactly as it was.
    public func startPairing(chatId: String, peerId: String, confirmedTakeover: Bool = false) throws -> PairingStart {
        lock.lock(); defer { lock.unlock() }
        guard ring.identity != nil else { throw SecutgCryptoError.invalidKey }
        if let refusal = refusal(chatId: chatId, confirmedTakeover: confirmedTakeover) { return .refused(refusal) }
        // Only ever the local estimate of "when this pairing completed", for the branch below where the peer's
        // key is already known. It is deliberately not written to `startedAt` — see there.
        let pairedAt = clock() / 1000
        // PLAN.md 3.25.6 "re-pair here" carries the chat's known device ids through a fresh invite:
        // peerSeenDeviceIds is chat history, not pairing-attempt state, so it must not reset here; ownDeviceId
        // is carried through too, on purpose, so a later own-P1 echo can still notice a takeover happened
        // (PLAN.md 3.25.3 rule 1 reserves writing it to that echo, never to this call).
        let previous = ring.chatPairing(chatId)
        // A new round of the race, so sibling P1s parked during the previous one no longer compete
        heldOwnClaims.removeValue(forKey: chatId)
        // `startedAt` is deliberately left empty. PLAN.md 3.7 rule 13 weighs it against a sibling's server date,
        // and the only clock reachable here is this machine's, which the sibling can neither see nor reproduce;
        // `applyOwnEcho` fills it in when the P1 comes back carrying the server's own date.
        try ring.setChatPairing(chatId: chatId, KeyRing.Pairing(
            peerId: peerId, state: .invited, verified: false,
            ownDeviceId: previous?.ownDeviceId, peerDeviceId: previous?.peerDeviceId, peerSeenDeviceIds: previous?.peerSeenDeviceIds))
        return completePairing(chatId: chatId, peerId: peerId, pairedAt: pairedAt) ? .paired : .invited
    }

    private func completePairing(chatId: String, peerId: String, pairedAt: Int64) -> Bool {
        guard let identity = ring.identity, let peerPk = ring.memberPk(chatId: chatId, userId: peerId),
              let master = try? Pairing.deriveMaster(ownX25519Sk: identity.x25519Sk, ownX25519Pk: identity.x25519Pk, peerX25519Pk: peerPk),
              let masterId = try? ring.addMaster(master) else { return false }
        let current = ring.chatPairing(chatId)
        // Carried through untouched, empty included: `startedAt` holds the server date of *this device's own* P1
        // and has exactly one writer, `applyOwnEcho`. Filling it in from the peer's `pairedAt` here would put a
        // number in the field that says "the echo has landed" when it has not, and `holdSiblingClaim` would stop
        // parking the very sibling it exists for.
        let startedAt = current?.startedAt
        try? ring.setChatMaster(chatId: chatId, masterId: masterId, label: nil)
        ring.setChatEncryption(chatId: chatId, enabled: true)
        // PLAN.md 3.25.3: the peer's device_id is kept redundantly so a later keyChanged can still say "the
        // previous one was …". `ownDeviceId` is deliberately NOT set here — only handleOwnP1's own-P1 echo ever
        // writes it (rule 1), which is what lets it notice when the echo's device differs from whatever this
        // field held going in, i.e. a takeover (PLAN.md 3.25.6 rule 5).
        try? ring.setChatPairing(chatId: chatId, KeyRing.Pairing(
            peerId: peerId, state: .paired, verified: false, startedAt: startedAt, pairedAt: pairedAt,
            ownDeviceId: current?.ownDeviceId, peerDeviceId: try? DeviceIdentity.derive(x25519Pk: peerPk).deviceId,
            peerSeenDeviceIds: current?.peerSeenDeviceIds))
        return true
    }

    /// Telegram user chats have positive ids; groups and channels are negative
    public static func isPrivateChat(_ chatId: String) -> Bool {
        return !chatId.isEmpty && chatId.allSatisfy { $0.isNumber }
    }

    private func peerResult(_ userId: String, _ pairing: PairingOutcome?) -> Result {
        return Result(isRekey: false, ok: true, type: nil, newKeyId: nil, userId: userId, reason: nil, pairing: pairing)
    }

    /// Which Ed25519 key an R1 must be signed with: the chat's offline admin key, or in an auto-paired private chat
    /// (PLAN.md 3.7 rule 6) the sender's identity key — the peer's registered one for incoming rotates, our own
    /// for the echo of a rotate we sent. reset / welcome stay admin-only.
    private func rekeySigner(_ type: Rekey.R1Type, chatId: String, senderId: String?, ownUserId: String?) -> [UInt8]? {
        if let adminPk = ring.chatAdminPk(chatId) { return adminPk }
        guard type == .rotate || type == .ratchet, RekeyProcessor.isPrivateChat(chatId), let pairing = ring.chatPairing(chatId), pairing.state == .paired,
              let senderId = senderId else { return nil }
        if senderId == pairing.peerId { return ring.memberEdPk(chatId: chatId, userId: pairing.peerId) }
        if senderId == ownUserId { return ring.identity?.ed25519Pk }
        return nil
    }

    /// Forgets the peer: pairing state, their keys, and the chat's key material itself.
    ///
    /// The master keys have to go, not just this chat's pointer to them. `KeyRing.lookupSessionKey` resolves a key
    /// globally by the master id parsed out of the wire, with no chat scoping at all, so clearing only
    /// `chatMasters[chatId]` would leave this side opening those messages exactly as before; deleting the
    /// conversation would not help either, because the key does not live in the conversation.
    ///
    /// The peer IS told now — PLAN.md 3.31.3's `U1`, which the runtime builds from the pairing record *before* it
    /// calls this and sends afterwards — but that notice is hygiene layered on top of this method, never a
    /// substitute for it: this is what makes the unpair true on this device, whether or not the notice could be
    /// built, was sent, arrived, or was honoured by whatever is on the other end.
    ///
    /// A chat with forward secrecy on is the worst case, not the best: its ratchet holds a *map* of label →
    /// masterId, so `clearChatRatchet` drops the ratchet record while every master in the chain stays in the flat
    /// store. The whole chain is collected here, before the clears below throw away the records that name it.
    public func unpair(chatId: String) {
        lock.lock(); defer { lock.unlock() }
        unpairLocked(chatId: chatId)
    }

    /// `unpair` with the lock already held (NSLock is not recursive), so `handleU1` — which runs inside
    /// `handle`'s lock — destroys keys through this body and not through a second copy of it.
    private func unpairLocked(chatId: String) {
        let peerId = ring.chatPairing(chatId)?.peerId ?? chatId
        var doomedMasterIds = Set<String>()
        if let masterId = ring.chatMasterId(chatId) { doomedMasterIds.insert(masterId) }
        if let ratchet = ring.chatRatchet(chatId) { doomedMasterIds.formUnion(ratchet.masters.values) }
        heldOwnClaims.removeValue(forKey: chatId)
        ring.clearChatPairing(chatId)
        ring.clearChatRatchet(chatId)
        ring.removeMember(chatId: chatId, userId: peerId)
        ring.clearChatMaster(chatId)
        ring.setChatEncryption(chatId: chatId, enabled: false)
        // `removeMaster` also purges the derived-session-key cache: a key gone from storage but still answered
        // from memory is not gone.
        for masterId in doomedMasterIds { ring.removeMaster(masterId) }
    }

    /// `text` is the message's own wire, kept so that a verdict of "not yet" can park it and re-run the whole
    /// judgement later; `isRetry` marks that re-run, which never parks again.
    private func handleR1(_ r1: Rekey.ParsedR1, text: String, chatId: String, senderId: String?,
                          ownUserId: String?, isRetry: Bool = false) -> Result {
        let unverifiable: String?
        if let signer = rekeySigner(r1.type, chatId: chatId, senderId: senderId, ownUserId: ownUserId) {
            unverifiable = Rekey.verify(signedText: r1.signedText, signature: r1.signature, ed25519Pk: signer)
                ? nil : "bad_signature"
        } else {
            unverifiable = "no_admin_key"
        }
        if let unverifiable = unverifiable {
            // PLAN.md 3.34.7 item 4. In a group, "cannot verify" is often "cannot verify YET": the notice that
            // would make this key trusted is parked, or has not arrived. Then the message waits too, and is
            // judged in full once a notice applies. Narrowly, though: with no admin key at all there is nothing
            // to check against, so waiting is the only honest answer — but a signature that fails against a key
            // this device DOES trust, with no notice waiting, is a forgery or a stale key, and is refused out
            // loud as before. A retry that still fails is a real refusal and is not parked a second time.
            let mayBecomeVerifiable = unverifiable == "no_admin_key" || (parkedNotices[chatId]?.isEmpty == false)
            if !isRetry, mayBecomeVerifiable, !RekeyProcessor.isPrivateChat(chatId) {
                parkRekey(chatId: chatId, ParkedRekey(text: text, senderId: senderId))
                return rekeyFailure(r1.type, "pending")
            }
            return rekeyFailure(r1.type, unverifiable)
        }
        let applied = apply(r1, chatId: chatId, ownUserId: ownUserId)
        if applied.ok { retryPending(chatId: chatId, ownUserId: ownUserId) }
        return applied
    }

    private func parkRekey(chatId: String, _ item: ParkedRekey) {
        var queue = parkedRekeys[chatId] ?? []
        guard !queue.contains(where: { $0.text == item.text }) else { return }
        queue.append(item)
        if queue.count > RekeyProcessor.maxPendingPerChat { queue.removeFirst(queue.count - RekeyProcessor.maxPendingPerChat) }
        parkedRekeys[chatId] = queue
    }

    /// Judges every `R1` parked for `chatId`, each against **its own** sender, through the ordinary road —
    /// signature check included. Called with the lock held, from the last line of an applied `N1`.
    private func retryParkedRekeys(chatId: String, ownUserId: String?) -> [Result] {
        guard let queue = parkedRekeys.removeValue(forKey: chatId), !queue.isEmpty else { return [] }
        return queue.map { item in
            guard let parsed = Rekey.parseR1(item.text) else { return rekeyFailure(.rotate, "malformed") }
            return handleR1(parsed, text: item.text, chatId: chatId, senderId: item.senderId,
                            ownUserId: ownUserId, isRetry: true)
        }
    }

    private func apply(_ r1: Rekey.ParsedR1, chatId: String, ownUserId: String?) -> Result {
        guard let keyId = KeyDerivation.parseKeyId(r1.newKeyId) else { return rekeyFailure(r1.type, "malformed") }
        guard KeyDerivation.isLabelAcceptable(keyId.label, nowMs: clock(), epochTolerance: ring.epochTolerance) else {
            return rekeyFailure(r1.type, "bad_label")
        }
        if ring.listMasterIds().contains(keyId.masterId) {
            bind(chatId: chatId, masterId: keyId.masterId, label: keyId.label)
            applyRatchetMode(chatId: chatId, type: r1.type, masterId: keyId.masterId, label: keyId.label)
            return Result(isRekey: true, ok: true, type: r1.type, newKeyId: r1.newKeyId, userId: nil, reason: "already_known")
        }
        let identity = ring.identity.map { Rekey.SealingIdentity(x25519Pk: $0.x25519Pk, x25519Sk: $0.x25519Sk) }
        switch Rekey.openR1(r1, candidateMasters: ring.candidateMasters(chatId: chatId), identity: identity, ownUserId: ownUserId) {
        case .failure(let failure):
            if failure == .noOldKey { park(chatId: chatId, r1) }
            return rekeyFailure(r1.type, failure.rawValue)
        case .success(let newMaster):
            guard let masterId = try? ring.addMaster(newMaster) else { return rekeyFailure(r1.type, "bad_payload") }
            bind(chatId: chatId, masterId: masterId, label: keyId.label)
            applyRatchetMode(chatId: chatId, type: r1.type, masterId: masterId, label: keyId.label)
            return Result(isRekey: true, ok: true, type: r1.type, newKeyId: r1.newKeyId, userId: nil, reason: nil)
        }
    }

    /// `ratchet` switches the chat into forward-secrecy mode from this master; any other rekey switches it off
    private func applyRatchetMode(chatId: String, type: Rekey.R1Type, masterId: String, label: String) {
        if type == .ratchet {
            if ring.chatMasterId(chatId) == masterId { try? ring.setChatRatchet(chatId: chatId, label: label, masterId: masterId) }
        } else {
            ring.clearChatRatchet(chatId)
        }
    }

    private func bind(chatId: String, masterId: String, label: String) {
        let bound = ring.chatKeyLabel(chatId)
        if let bound = bound, bound > label { return }
        if ring.chatMasterId(chatId) != masterId || bound != label {
            try? ring.setChatMaster(chatId: chatId, masterId: masterId, label: label)
        }
    }

    private func park(chatId: String, _ r1: Rekey.ParsedR1) {
        var queue = pending[chatId] ?? []
        guard !queue.contains(where: { $0.newKeyId == r1.newKeyId }) else { return }
        queue.append(r1)
        if queue.count > RekeyProcessor.maxPendingPerChat { queue.removeFirst(queue.count - RekeyProcessor.maxPendingPerChat) }
        pending[chatId] = queue
    }

    private func retryPending(chatId: String, ownUserId: String?) {
        guard let queue = pending.removeValue(forKey: chatId), !queue.isEmpty else { return }
        for item in queue.sorted(by: { $0.newKeyId < $1.newKeyId }) { _ = apply(item, chatId: chatId, ownUserId: ownUserId) }
    }

    private func rekeyFailure(_ type: Rekey.R1Type, _ reason: String) -> Result {
        return Result(isRekey: true, ok: false, type: type, newKeyId: nil, userId: nil, reason: reason)
    }

    private func peerFailure(_ reason: String) -> Result {
        return Result(isRekey: false, ok: false, type: nil, newKeyId: nil, userId: nil, reason: reason)
    }
}
