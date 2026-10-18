import Foundation
import Postbox
import SecutgBuildInfo
import SecutgCore
import SwiftSignalKit

/// SECUTG: global plugin configuration, set by the app before any account is created
/// (AppDelegate on iOS / macOS). Falls back to the built-in crypto defaults when the app did not load a file.
public final class SecutgConfigHolder {
    public static let shared = SecutgConfigHolder()
    private let lock = NSLock()
    private var stored: SecutgConfig?

    public var config: SecutgConfig? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    public var crypto: CryptoConfig { return config?.crypto ?? CryptoConfig.defaults }
}

/// SECUTG-HOOK (PLAN.md 3.53): the App Store submission switch. This is a **Bazel build parameter**
/// (`--secutgStoreBuild` in Make.py → `--define=secutgStoreBuild=1` → `SecutgBuildInfo.isStoreBuild`,
/// generated at build time — see `//submodules/SecutgBuildInfo/BUILD`), not a runtime config file switch:
/// with the flag absent the app compiles and behaves exactly as before this switch existed. Every call site
/// that hides a feature behind this flag should be commented `// SECUTG-HOOK (PLAN.md 3.53)`.
public enum SecutgStoreBuild {
    public static let isEnabled: Bool = SecutgBuildInfo.isStoreBuild
}

/// SECUTG-HOOK (PLAN.md 3.53 amendment, 2026-10-03): this self-built iOS app has no CallKit entitlement
/// (no `voip` background mode, no PushKit VoIP push), so Telegram voice/video calls, group voice/video
/// chats, live streams and call links cannot actually work in ANY build of this app — not just the App
/// Store build. Unlike `SecutgStoreBuild`, this is unconditionally `true` and not a Bazel build parameter.
/// Every call-related entry point hidden because of this should be commented
/// `// SECUTG-HOOK (PLAN.md 3.53 amendment)` and gated on `SecutgCalls.isDisabled`, not `SecutgStoreBuild`.
public enum SecutgCalls {
    public static let isDisabled: Bool = true
}

public enum SecutgSendFailure: Equatable {
    case noKey
    case tooLong(chars: Int, limit: Int)
    case cryptoError(String)
    /// PLAN.md 3.13: a `G1` group invite carries the group key and may only travel inside an encrypted private chat
    case inviteNeedsEncryption
    /// PLAN.md 3.0: the chat's encryption switch is missing rather than off, so this device cannot tell whether
    /// the chat is supposed to encrypt. Distinct from `noKey`, which is "encryption is on and the key is gone":
    /// here it is the *switch* that is gone, and the honest answer is to refuse rather than to read the silence
    /// as consent to send in the clear. The user clears it by importing the chat's key or setting the switch.
    case encryptionStateUnknown
    /// PLAN.md 3.41.2: the chat's 「没有钥匙时禁止发送」 flag is on and it has no usable send key right now. User
    /// content only — protocol lines pass — and nothing was sent: the UI keeps the draft and shows
    /// `SecutgKeyRequiredBlocked` with 〔去配对 / 导入钥匙〕 and 〔本聊天允许明文〕 (`keyRequiredRefusals`).
    case keyRequired
}

/// One-to-one pairing dialogs (PLAN.md 3.7.1): `invite` = a fresh P1 from the peer arrived (show "{name} invites
/// you…"), `done` = the pairing completed on this device (show the safety code). `shouldConfirm` is true on the side
/// that completed the pairing from the peer's P1: it sends the encrypted "🔒 Encryption is on" text (rule 10).
public struct SecutgPairingEvent: Equatable {
    public enum Phase: Equatable { case invite, done }
    public let chatPeerId: PeerId
    public let phase: Phase
    public let code: String?
    public let shouldConfirm: Bool
}

/// What `startPairing` did.
///
/// An enum rather than a struct with an optional `p1`, because a refusal (PLAN.md 3.25.6 rules 2 and 7) carries
/// **no P1 at all**: the caller's whole job is to put the returned P1 on the wire, so the only way to be sure
/// nothing unconfirmed or doomed is sent is to hand it nothing to send. A `p1` that were merely optional would
/// leave that as a thing every call site has to remember; this way the compiler asks each of them instead.
public enum SecutgPairingStart: Equatable {
    /// The P1 to send as a plain message. `completed` is the accepting side, where the pairing finished at once
    /// and `code` is the safety code to show.
    case started(p1: String, completed: Bool, code: String?)
    /// Another device of this account holds this chat's pairing, and the caller did not state that the user has
    /// been through rule 2's takeover confirmation. Nothing was written; send them to that confirmation.
    case needsTakeover
    /// A confirmed takeover that would land inside the race window and be discarded by the peer (rule 7).
    /// The wait rides along because the dialog that has to explain the delay cannot work it out for itself.
    case tooSoon(retryAfterSeconds: Int)
}

/// SECUTG-HOOK (fix, 2026-09-27 真机): why a pairing tap sent nothing. v1 new pairing is permanently disabled (the
/// user's ruling: v2 takes priority over v1), so when v2 cannot start or accept there is no v1 P1 to fall back to —
/// that fallback is exactly what a real device sent, and the peer could never accept it. Thrown, so every
/// caller's existing `catch` shows it as 「配对失败：…」 instead of a button that silently does nothing.
public enum SecutgPairingError: Error, Equatable, CustomStringConvertible {
    /// No v2 runtime for this account (no identity yet), or not a one-to-one chat.
    case v2Unavailable
    /// The chat already has a v2 binding and no newer invite to accept.
    case alreadyPaired
    /// A v2 exchange is already in flight for the chat.
    case inFlight
    /// The cached incoming invite could not be accepted (busy / expired / cancelled / rejected).
    case acceptRefused(String)
    /// v2 could not build an INVITE.
    case inviteFailed(String)

    public var description: String {
        switch self {
        case .v2Unavailable: return "v2_unavailable"
        case .alreadyPaired: return SecutgL10n.string("SecutgPairPairedAuto")
        case .inFlight: return SecutgL10n.string("SecutgWaitingPeer")
        case let .acceptRefused(reason): return "accept_" + reason
        case let .inviteFailed(reason): return "invite_" + reason
        }
    }
}

public struct SecutgChatStatus: Equatable {
    public let encryptionEnabled: Bool
    public let hasKey: Bool
    public let currentKeyId: String?
    public let masterId: String?
    public let isAdmin: Bool
    public let hasAdminPk: Bool
    public let memberCount: Int
    public let hasIdentity: Bool
    /// One-to-one pairing (PLAN.md 3.7); nil pairingState means manual / no pairing
    public let isPrivateChat: Bool
    public let pairingState: String?
    public let pairingVerified: Bool
    /// The peer announced a key in this private chat and we have not answered yet
    public let hasIncomingInvite: Bool
    /// Whole days the current master has been in use, and whether it passed crypto.rekey_reminder_days
    public let keyAgeDays: Int?
    public let isRekeyDue: Bool
    /// Forward-secrecy mode (PLAN.md 3.8): the key changes daily and old days are destroyed
    public let isForwardSecrecy: Bool
    /// PLAN.md 3.13: where this device's key came from (nil = unknown / no key)
    public let keySource: ChatKeySource?
    /// PLAN.md 3.13, admin device: userId → level of the private chat the group key was sent through
    public let onlineInvites: [String: OnlineInviteLevel]
    /// PLAN.md 3.25.5: device_id of the peer's currently-bound key, nil until this chat has paired at least once
    public let peerDeviceId: String?
    /// PLAN.md 3.25.5: device_id of whichever of this account's own devices holds the pairing — this device's
    /// own id when `pairingState` isn't "other_device", the accept race's winner otherwise; nil without a pairing
    public let ownDeviceId: String?
    /// PLAN.md 3.24.5 rule 2: unix SECONDS when this device sent its own P1, so the onboarding card can say
    /// "they have not accepted" after seven days instead of "waiting" forever. Wording only — the `invited`
    /// state itself never expires (PLAN.md 3.7 rule 3), and nothing may clear the pairing when this elapses.
    public let pairingStartedAt: Int64?
    /// Unix seconds this pairing completed, or nil without a completed pairing. PLAN.md 3.7.1's dialog
    /// catch-up (`PairingDialogCatchUp`) keys its "have I shown this yet" marker on this value.
    public let pairedAt: Int64?
    /// SECUTG-HOOK (fix B1): PLAN.md 3.0's manual-vs-auto rekey mode, surfaced here so a group's lock
    /// UI can tell a real (`.manual`, 当面) encrypted group from a G2 auto-mode one — PLAN.md 3.35's
    /// group key travels the chat in the clear, obfuscated (not encrypted) rather than protected, and
    /// must never render with the same lock indicator as an actually-encrypted chat. Combine with
    /// `!isPrivateChat` at the call site: a private chat's own `.auto`/`.manual` split is v1's
    /// existing pairing-vs-manual-key distinction and is unaffected by this field's addition.
    public let keyMode: Rekey.KeyMode

    /// SECUTG-HOOK (fix, 2026-09-27, live-reported): `hasKey`/`encryptionEnabled` above are purely
    /// v1's KeyRing, and deliberately stay that way (see `status(chatPeerId:)`'s note on the toggle
    /// entry they gate). But the lock badge (`SecutgFloatingButton`) read the same two fields, so a
    /// chat paired ENTIRELY through v2 — no v1 record at all, the normal case for any new pairing —
    /// drew the red "no key" glyph while a real v2 binding was actively encrypting every message.
    /// These two answer the badge's question ("is this chat really encrypting right now?") without
    /// disturbing the toggle's. v2 has no on/off switch of its own — a binding either exists or it
    /// does not — so once v1 has nothing on file, "does a binding exist" already answers both.
    public let hasKeyOrV2: Bool
    /// SECUTG-HOOK (fix, 2026-09-27 真机): a v1 pairing record exists but is being ignored. `pairingState` is
    /// v2-first and a v1 record only counts when it is a real "paired" (`V2PairingStatus.resolve`); anything
    /// else is a leftover from older testing. A v1 key such a leftover left behind must not hide 〔自动配对〕.
    public let hasResidualV1Pairing: Bool
    /// SECUTG-HOOK (fix, 2026-09-27 真机): the "paired" shown is a v2 binding — the menu hides the v1-only
    /// forward-secrecy entry for it.
    public let isV2Paired: Bool
    /// SECUTG-HOOK (fix, 2026-09-27 真机): v2 has any state for this chat — a binding, an in-flight or CONFLICT
    /// exchange, or a pending invite. The v1 manual-key entries (〔手动配对〕, import) are hidden then: a v1 key
    /// imported there is a second, parallel key set.
    public let hasV2PairingState: Bool
    /// SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): the group-password gate (`GP1` policy), if any.
    public var groupPassword: SecutgGroupPasswordState = .none
    /// SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2 legacy): a 3.38.1 locked record not opened in this run.
    public var legacyGroupPasswordLocked: Bool = false
    /// PLAN.md 3.41.1: 「没有钥匙时禁止发送」 for this chat, as the lock menu's switch shows it.
    public var keyRequired: Bool = false
    public var isEncryptedOrV2: Bool { return hasKey ? encryptionEnabled : hasKeyOrV2 }

    public var isAutoPaired: Bool { return pairingState == "paired" }
    /// Security level shown to the user: nil (no key), "high" (offline key), "standard" / "verified" (auto-paired)
    public var securityLevel: String? {
        guard hasKeyOrV2 else { return nil }
        if !isAutoPaired { return "high" }
        return pairingVerified ? "verified" : "standard"
    }
}

/// One per account. Owns the keyring, applies control messages and performs the two transformations the
/// upstream hooks call: `transformIncoming` (B1) and `prepareOutgoing` (A1–A4). Every method is safe to call
/// from any thread and never throws into upstream code.
public final class SecutgAccountRuntime {
    public struct Incoming {
        public let text: String
        /// nil = keep the entities the message came with
        public let entities: [MessageTextEntity]?
        public let meta: SecutgTextMetaAttribute
    }

    public enum Outgoing: Equatable {
        case passthrough
        case encrypted(String)
        case failed(SecutgSendFailure)
    }

    public let accountPeerId: PeerId
    public let crypto: CryptoConfig
    /// UI subscribes here to show "message not sent" dialogs; payload = (chat, failure)
    public let sendFailures = ValuePipe<(PeerId, SecutgSendFailure)>()
    /// UI subscribes here to show the pairing invite / pairing-done dialogs (mirrors Web A `notifyPairing`)
    public let pairingEvents = ValuePipe<SecutgPairingEvent>()
    /// PLAN.md 3.20: a forward batch re-sent as encrypted text; payload = (target chat, how many). Said once per
    /// batch because the re-sent copies lost their "forwarded from" label and their entities.
    public let forwardNotices = ValuePipe<(PeerId, Int)>()
    /// PLAN.md 3.34.6: a member announced a public key in an auto-mode group and this device owes them a
    /// `R1 welcome`; payload = (group, user id). The decision is the processor's and the sending is the UI
    /// layer's — a state machine does not send messages, and only the UI can put text into a chat.
    public let autoWelcomes = ValuePipe<(PeerId, String)>()
    /// SECUTG-HOOK (PLAN.md UI-01): a v2 pairing wire this device must relay onward the instant it is
    /// produced — ACCEPT processed by the initiator yields a SELECT to send, SELECT processed by the
    /// responder yields a CONFIRM, CONFIRM processed by the initiator yields the READY that completes
    /// the exchange on the other side; payload = (chat, wire). The same split `autoWelcomes` already
    /// documents: the decision (and the wire itself) is `V2PairingDispatch`'s, sending it is the UI
    /// layer's job. Unlike `autoWelcomes`, nothing subscribes to this pipe yet in this pass — wiring a
    /// real sender needs an account-wide install call next to `installConfirmationSender`'s own, which
    /// is exactly the kind of real-startup wiring this pass's `V2Bootstrap.initV2Worker` also leaves
    /// for later (see its own doc). Populated correctly and inertly today: no `V2Runtime` exists for
    /// any real account yet, so nothing is ever lost by there being no listener.
    public let v2PairingWires = ValuePipe<(PeerId, String)>()
    /// PLAN.md 3.17 rule 3, the fifth moment a key can arrive (3.34.7 item 4): a control message moved what this
    /// device holds for the chat, right where the message was built. 3.17 listed four moments and this was not
    /// among them — no welcome existed when it was written, and a welcome is itself a road a key travels by.
    ///
    /// Also reported for a `P1` that registered a key in a group (3.34.3 rule 2, 2026-09-19): no key moved, but
    /// a notice parked for want of its sender's identity key can be judged now, and this is the one channel
    /// that reaches the code able to go back over the stored rows.
    ///
    /// From that instant the rows waiting on exactly this — ciphertext sealed to the new key, a welcome parked
    /// for the notice — have not been asked again, and the receive hook cannot ask them: it is handed one
    /// message at a time and the others are already stored. Only the UI layer can scan a chat, so it is told.
    /// Fresh applications only (`RekeyProcessor.Result.movedKeys`), or every reload of a history would sweep.
    public let keysChanged = ValuePipe<PeerId>()
    /// SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1 member rule 2): this device just took its FIRST locked key
    /// for the group. Reported from inside the store transaction, so the listener drops the group's local cache in
    /// a transaction of its own (`secutgDropLocalHistory`).
    public let groupPasswordAdopted = ValuePipe<PeerId>()
    /// SECUTG-HOOK (fix, 2026-09-29, review H1): the group's password GATE moved — a `GP1` applied here (on, off, or
    /// a changed password), or this run unlocked the group. The chat on screen folds it into a layout request,
    /// which is the one road to `SecutgGroupPasswordGateView.update`; without it the password page only appeared
    /// at the next rotation / keyboard event. Reported after the ring has moved, so a listener reading
    /// `needsGroupPassword` sees the new answer.
    public let groupPasswordChanged = ValuePipe<PeerId>()
    /// PLAN.md 3.41.3: a send in this chat was refused for want of a key (`SecutgSendFailure.keyRequired`) — by the
    /// send hook, or by the UI layer's own pre-check on the composer. The chat on screen answers with the inline
    /// notice above its composer; keeping it to one notice per chat is the listener's business, this only reports.
    public let keyRequiredRefusals = ValuePipe<PeerId>()
    /// Invites dated within this window pop the dialog; older ones (history loads) only show the card in the chat
    private static let freshInviteSeconds: Int64 = 10 * 60
    let ring: KeyRing // internal since PLAN.md 3.38.1 (SecutgGroupPassword.swift)
    private let processor: RekeyProcessor
    private let lastFailureLock = NSLock()
    private var lastFailureAt: [PeerId: Double] = [:]
    private let notifiedInvitesLock = NSLock()
    private var notifiedInvites: Set<String> = []
    private let savedMessagesNoticeLock = NSLock()
    private var savedMessagesNoticePending = false
    /// PLAN.md 3.34.3 rule 1: who Telegram says the admins of a group are, as the UI layer last read them.
    ///
    /// Memory-only and **absent until somebody fills it in**, which is the whole point: absent is the third
    /// state, "the member list has not loaded", and `handleN1` parks a notice on it rather than refusing one.
    /// Persisting it would turn a stale list into an answer, and a stale "no" here silently drops a notice.
    private let groupAdminsLock = NSLock()
    private var groupAdmins: [String: Set<String>] = [:]
    /// PLAN.md 3.19: the words of the messages this session has already opened, keyed by their envelope. Never
    /// written down; dropped whenever the keyring changes under us.
    let plaintextCache = SecutgPlaintextCache()
    init(accountPeerId: PeerId, storage: KeyRingStorage, crypto: CryptoConfig, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.accountPeerId = accountPeerId
        self.crypto = crypto
        self.ring = KeyRing(storage: storage, clock: clock, epochDays: crypto.epochDays, epochTolerance: crypto.epochTolerance)
        self.ring.rekeyReminderDays = crypto.rekeyReminderDays
        self.processor = RekeyProcessor(ring: ring, clock: clock)
    }

    // MARK: ids

    /// The offset a channel / supergroup id is pushed down by, so that a channel key can never collide
    /// with a basic-group key. Shared with Web and Android verbatim (`Tests/.../watermark.json`,
    /// `shared_chat_id_format.channel_id_base`).
    public static let channelChatKeyBase: Int64 = SharedChatId.channelBase

    /// Local keyring key for a chat: "123" (user) / "-123" (group) / "-1000000000123" (channel).
    ///
    /// The channel form is **arithmetic**, `-(id + 10^12)`, not the string "-100" glued in front of the
    /// bare id. The two agree only when the bare id happens to be exactly ten digits long, which is
    /// true of most present-day channels and was why the string form survived this long. For a bare id
    /// of 1 the string form yields "-1001" where every other client yields "-1000000000001", and that
    /// wrong id would travel into both the keyring archive and the 3.21 watermark payload — a screenshot
    /// traced back to the wrong conversation. Web and Android have always used the arithmetic form, so
    /// this side is the one that had to move (PLAN.md 3.0 / 3.21.1 "symbol-value encoding").
    public static func chatKey(_ peerId: PeerId) -> String {
        let raw = peerId.id._internalGetInt64Value()
        switch peerId.namespace {
        case Namespaces.Peer.CloudGroup: return SharedChatId.encodeString(kind: .basicGroup, bareId: raw)
        case Namespaces.Peer.CloudChannel: return SharedChatId.encodeString(kind: .channel, bareId: raw)
        default: return SharedChatId.encodeString(kind: .user, bareId: raw)
        }
    }

    /// Inverse of `chatKey`: the peer behind a keyring key such as the `group_chat_id` of a `G1` invite.
    /// Mirrors the arithmetic above — anything below `-10^12` is a channel and gets the offset taken
    /// back off, everything else negative is a basic group.
    public static func peerId(chatKey: String) -> PeerId? {
        guard let decoded = SharedChatId.decode(chatKey) else { return nil }
        switch decoded.kind {
        case .channel:
            return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(decoded.bareId))
        case .basicGroup:
            return PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(decoded.bareId))
        case .user:
            return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(decoded.bareId))
        }
    }

    /// Telegram user id as the protocol writes it in P1 / reset tables.
    public static func userId(_ peerId: PeerId) -> String {
        return "\(peerId.id._internalGetInt64Value())"
    }

    public var ownUserId: String { return SecutgAccountRuntime.userId(accountPeerId) }

    /// v1's identity keys (Ed25519 sign + X25519 encapsulation), surfaced so `Account.init`'s
    /// `V2Bootstrap.initV2Worker` call (right after `SecutgHookRegistry.shared.install(...)`) can
    /// pass them as `storedIdentity` — v2 reuses this device's v1 identity rather than generating its
    /// own (`V2IdentityBridge`'s own coexistence decision). `nil` before v1 has ever created an
    /// identity (pre-`announceIdentity`/`createMaster`/`startPairing`), same condition
    /// `SecutgChatStatus.hasIdentity` already reports elsewhere in this file.
    public var storedIdentity: KeyRing.Identity? { return ring.identity }

    // MARK: B1 receive

    /// `messageDate` is the server date of the message (unix seconds); nil (local copies) means "now". `isOutgoing`
    /// is the message's own out flag; nil falls back to comparing the sender with this account.
    public func transformIncoming(text: String, entities: [MessageTextEntity], chatPeerId: PeerId, senderPeerId: PeerId?, messageDate: Int32?, isOutgoing: Bool? = nil) -> Incoming? {
        guard chatPeerId.namespace != Namespaces.Peer.SecretChat, !text.isEmpty else { return nil }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK: v2's own wire prefix ("E2:"), checked first — a no-op for every chat that has
        // never v2-paired, since `V2Dispatch.decryptIncomingText` only ever claims text starting with
        // "E2:" at all. v1's `R1`/`P1`/`U1`/`N1` and `E1:` handling below is completely untouched for
        // every other case.
        switch V2Dispatch.decryptIncomingText(accountKey: ownUserId, chatId: chat, wireText: text) {
        case .decrypted(let plaintext):
            // SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.44): the same door and the same swap as v1's `E1:` below.
            // While the 3.19 switch is on, a chat that is on v2 (a binding, or a group state — private chats and
            // groups alike) writes the `E2:` wire to the database and keeps the words in this session's cache;
            // `SecutgSealedText` opens it again on the way to the screen (`openSealed`, the v2 receive function
            // re-run: idempotent, the replay index answers a wire it has seen with the same words). Switch off:
            // unchanged — the words are stored, the envelope rides beside them for 3.17 rule 6.
            let stored = SecutgPersist.storedForm(
                plaintext: plaintext, entities: nil, wire: text,
                keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: ownUserId, chatId: chat, localCiphertext: ring.getLocalCiphertext()))
            if stored.isSealed {
                plaintextCache.remember(wire: text, text: plaintext, entities: [])
                return Incoming(text: stored.text, entities: [], meta: SecutgTextMetaAttribute(kind: .sealed, keyId: "v2", detail: nil))
            }
            return Incoming(text: plaintext, entities: [], meta: SecutgTextMetaAttribute(kind: .decrypted, keyId: "v2", detail: nil, wire: text))
        case .failed(let reason):
            // PLAN.md 3.44 rule 2 / 3.17 rule 1: v2's own reason strings (missing_key / unknown_binding /
            // bad_signature / malformed …) are folded onto the three situations the notice knows — no key
            // here, possibly altered, not ready — by `storedFailureDetail`; never a code on screen, never a new
            // `DecryptResult.Reason` invented here.
            return Incoming(text: text, entities: [], meta: SecutgTextMetaAttribute(kind: .undecryptable, keyId: nil, detail: V2Dispatch.storedFailureDetail(reason: reason)))
        case .notV2:
            break
        }
        let isOwn = isOutgoing ?? (senderPeerId == accountPeerId)
        // SECUTG-HOOK (PLAN.md UI-01): v2's own pairing family ("P2:"), checked before v1's own
        // R1/P1/U1/N1 parsing below — a brand-new chat (no v1 pairing record for it at all) pairs
        // through v2 instead of v1's `RekeyProcessor`; a chat v1 already has ANY pairing record for is
        // never routed here (`status`/`startPairing` gate that, not this function), so this branch is
        // unreachable for it. Additive and currently inert like the `E2:` check above: no `V2Runtime`
        // has been bootstrapped for any real account in this pass either.
        if text.hasPrefix("P2:") {
            return handleP2(text: text, chatPeerId: chatPeerId, chat: chat, isOwn: isOwn, messageDate: messageDate)
        }
        if text.hasPrefix("R1:") || text.hasPrefix("P1:") || text.hasPrefix("U1:") || text.hasPrefix("N1:") || G2.isG2(text)
            || GP1.isGP1(text) { // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2)
            // Private chats: an incoming P1 can only come from the peer, an outgoing one from us.
            var sender = senderPeerId
            if sender == nil, chatPeerId.namespace == Namespaces.Peer.CloudUser { sender = chatPeerId }
            let senderId = sender.map(SecutgAccountRuntime.userId)
            let date = messageDate.map(Int64.init)
            guard let result = processor.handle(text: text, chatId: chat, senderId: senderId, ownUserId: ownUserId,
                                                messageDate: date,
                                                isSenderGroupAdmin: senderId.flatMap { isGroupAdmin(chat: chat, userId: $0) })
            else { return nil }
            // PLAN.md 3.17 rule 3 / 3.34.7 item 4: a key arrived (or left) by the one road the four listed
            // moments do not cover — the message itself, applied here where it was built. The UI layer is told
            // so it can sweep this chat's waiting rows; nothing here can, the other messages are already stored.
            if result.movedKeys {
                noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: a key that arrived by this road arms the flag
                keysChanged.putNext(chatPeerId)
            }
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a locked key was adopted — whatever
            // this run had opened of the group is shut again, and the first one ever drops the local cache.
            if result.isGroupKey, result.lockedPayload, result.ok, result.verdict == .apply {
                plaintextCache.forgetAll()
                if result.firstLockedAdoption { groupPasswordAdopted.putNext(chatPeerId) }
            }
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): a policy that turned the password ON here drops the
            // group's local cache (the listener does it in its own transaction); the keys are untouched.
            if result.isGroupPasswordPolicy, result.ok, result.verdict == .apply, result.policyTurnedOn {
                groupPasswordAdopted.putNext(chatPeerId)
            }
            // SECUTG-HOOK (fix, 2026-09-29, review H1): any applied policy — on, off, or a changed password — moves the
            // gate; the chat on screen is told so the password page goes up or comes down now, not at the next
            // rotation.
            if result.isGroupPasswordPolicy, result.ok, result.verdict == .apply {
                groupPasswordChanged.putNext(chatPeerId)
            }
            let detail: String
            if result.isGroupPasswordPolicy {
                // `groupPw:<verdict|reason>:<publisher>:<on|off|->` — the same "every verdict renders" rule as `G2`.
                detail = "groupPw:\(result.verdict?.rawValue ?? result.reason ?? "error")"
                    + ":\(result.userId ?? senderId ?? "-")"
                    + ":\(result.policyOn.map { $0 ? "on" : "off" } ?? "-")"
            } else if result.isGroupKey {
                // PLAN.md 3.35.4: the verdict IS the line, all six of them, so it is the whole of what the
                // detail has to carry besides who published it. Kept as the raw case name rather than
                // squeezed into `ok` / reason, because 「还不知道」 and 「不是管理员」 look identical to a
                // member staring at a chat where nothing happened and only one of them resolves itself.
                detail = "groupKey:\(result.verdict?.rawValue ?? result.reason ?? "error")"
                    + ":\(result.userId ?? senderId ?? "-")"
                    // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): which kind of key it was, for the line.
                    + (result.lockedPayload ? ":pw" : (result.groupPasswordDisabled ? ":pw_off" : ""))
            } else if result.isRetire {
                // PLAN.md 3.34.3. The same shape `unpair:` uses, plus the two things the sentence needs and the
                // notice alone can supply: how the replacement travels, and who to go and find if it does not
                // travel by itself. A refusal keeps its reason in the second segment and carries whatever of
                // the other two the processor got as far as reading.
                //
                // `pending` is here like any other outcome, and `controlSummary` draws nothing for it: the
                // member list has not loaded, so the only reason this line could give is one that will stop
                // being true in a moment.
                detail = "retire:\(result.ok ? (result.reason ?? "ok") : (result.reason ?? "error"))"
                    + ":\(result.mode?.rawValue ?? "-"):\(result.userId ?? senderId ?? "-")"
            } else if result.isUnpair {
                // PLAN.md 3.31.3 + 3.30 rule 10. Two things happen to a `U1` here and both of them matter.
                //
                // The reader gets `controlSummary`'s sentence, built from this `detail` — without it the peer
                // unpairs and nothing on this side says so, so the user just finds the chat no longer encrypted.
                // And the message is tagged `.control` below, which is what stops `PlaintextPane` counting a line
                // secuTG wrote itself as the peer sending plain text and raising a false "the peer has stopped
                // encrypting" warning. Windows needs a list of string keys for that second half
                // (`kSystemLineKeys`) because it stores the rendered sentence; here the kind is structural, so
                // the `.control` tag is the whole of it — and reaching this branch at all is what earns it: a
                // `U1` that never enters this `if` falls through to the `.plaintext` marker below.
                //
                // One segment, the same shape `rekey:` uses: "ok" for a notice that was acted on, "own_echo" for
                // this device's own notice coming back after it had already unpaired, and otherwise the refusal
                // reason. The three sets cannot collide — no `handleU1` refusal is named "ok" or "own_echo".
                detail = "unpair:\(result.ok ? (result.reason ?? "ok") : (result.reason ?? "error"))"
            } else if result.isRekey {
                // PLAN.md 3.32 review, batch 1: an applied message keeps its `reason` as a fourth segment —
                // `rekey:welcome:ok:already_known` is what every existing holder gets for a welcome, and
                // `RekeyLine` tells them apart from the newcomer by it. Refusals already carry theirs in the
                // third. Nothing reads a fourth segment on a `rekey:` line but `controlSummary`;
                // `ControlLineAction.onRow` answers `peer-key` only, and older lines without it still render.
                let okReason = result.ok ? (result.reason.map { ":" + $0 } ?? "") : ""
                detail = "rekey:\(result.type?.rawValue ?? "rotate"):\(result.ok ? "ok" : (result.reason ?? "error"))" + okReason
            } else {
                // PLAN.md 3.34.6 guardrail: a group announcement replacing a registered key. Its own segment
                // value rather than the private chat's `key_changed`, which is a pairing state with a
                // completely different road out (3.25.3) — the two must not be able to reach each other's
                // button. Nothing is appended after it: the `P1` this decision is about is the message's own
                // text, which this client keeps verbatim and re-reads at draw time, so unlike Web there is
                // nothing to copy into the detail.
                let groupKeyChanged = result.keyChanged ? ":group_key_changed" : ""
                detail = "peer-key:\(result.userId ?? senderId ?? "?"):\(result.ok ? "ok" : (result.reason ?? "error"))"
                    + (result.pairing.map { ":\($0.rawValue)" } ?? groupKeyChanged)
                    + pairingDetailSuffix(result, chat: chat)
                notifyPairing(chatPeerId: chatPeerId, outcome: result.pairing, messageDate: date)
                // PLAN.md 3.34.6: the decision was the processor's, the sending is the UI layer's.
                if let owed = result.owesWelcome { autoWelcomes.putNext((chatPeerId, owed)) }
                // PLAN.md 3.34.3 rule 2 (2026-09-19): a notice parked because its sender's key was not on file
                // can be judged now that a key from somebody has registered in this group. The retry is a scan
                // over the stored rows, which only the UI layer can do, so it goes down the same channel — each
                // parked row is judged as itself, and one from a different sender simply parks again.
                if result.ok, chat.hasPrefix("-") { keysChanged.putNext(chatPeerId) }
            }
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: result.newKeyId, detail: detail))
        }
        guard E1Format.isEncrypted(text) else {
            // PLAN.md 3.13 rule 6: while this chat encrypts, plain text from others is flagged "not encrypted"
            guard !isOwn, ring.isChatEncrypted(chat) else { return nil }
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .plaintext, keyId: nil, detail: nil))
        }
        let result = E1Codec.decrypt(wire: text) { [ring] keyId in ring.lookupSessionKey(keyId) }
        guard result.ok, let plaintext = result.text else {
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a group whose password this run has
            // not been given says so, instead of "no key".
            // PLAN.md 3.38.2: decryption never depends on the policy — only a legacy locked record explains a failure.
            let reason = ring.needsLegacyGroupPassword(chat) ? secutgGroupPasswordLockedDetail : result.reason?.rawValue
            return Incoming(text: text, entities: [], meta: SecutgTextMetaAttribute(kind: .undecryptable, keyId: result.keyId, detail: reason))
        }
        if GroupInvite.isG1(plaintext) {
            // A decrypted group invite becomes a card (its wire entities refer to the ciphertext, so they are dropped)
            return Incoming(text: plaintext, entities: [], meta: groupInviteMeta(plaintext, chatPeerId: chatPeerId, isOwn: isOwn))
        }
        // SECUTG-HOOK (PLAN.md 3.19): an encrypted chat writes the envelope to the database and keeps the words in
        // memory. `storedForm` decides which of the two this is; a chat that does not encrypt is stored unchanged.
        let stored = SecutgPersist.storedForm(
            plaintext: plaintext, entities: result.entities, wire: text,
            keepsCiphertextLocally: ring.keepsCiphertextLocally(chat))
        if stored.isSealed {
            plaintextCache.remember(wire: text, text: plaintext, entities: result.entities ?? [])
            return Incoming(text: stored.text, entities: [], meta: SecutgTextMetaAttribute(kind: .sealed, keyId: result.keyId, detail: nil))
        }
        // SECUTG-HOOK (PLAN.md 3.17 rule 6): the envelope is kept beside the words whatever 3.19 says. What goes on
        // the disk is `storedForm`'s business, and it asks the setting directly; whether the reader can ask to see
        // the bytes is a different question and must not be answered by the same fact.
        return Incoming(text: stored.text, entities: SecutgEntityMapper.fromEnvelope(stored.entities), meta: SecutgTextMetaAttribute(kind: .decrypted, keyId: result.keyId, detail: nil, wire: text))
    }

    /// SECUTG-HOOK (PLAN.md UI-01): `transformIncoming`'s own `"P2:"` branch, split out to keep that
    /// function's size in check. Dispatches to `V2PairingDispatch` and tags the result `.control`,
    /// reusing the exact `"peer-key:<user>:<ok/reason>:<pairingKind>"` shape v1's own peer-key line
    /// already writes (adapted only where v2 has no v1 equivalent) so `controlSummary` renders every
    /// outcome it already knows how to render. SECUTG-HOOK (fix, 2026-09-27 真机): every other step — own
    /// echoes, intermediate steps, cancels, a peer's BUSY, refusals — is a `v2line:<kind>` detail
    /// (`V2PairingLine`), so no P2 bubble is ever empty or shows a raw reason code.
    ///
    /// A private 1:1 chat's own `chatId` (`SecutgAccountRuntime.chatKey`) IS the peer's Telegram user
    /// id (`SharedChatId.encode(kind: .user, ...)` is the identity function on a bare id) — `chat` and
    /// `SecutgAccountRuntime.userId(chatPeerId)` are the same string, used interchangeably below.
    private func handleP2(text: String, chatPeerId: PeerId, chat: String, isOwn: Bool, messageDate: Int32?) -> Incoming? {
        // SECUTG-HOOK (PLAN.md 3.39.6 / 3.39.13): `isOwn` is Telegram's own outgoing flag — true for a message ANY
        // device of this account sent. Whether it is this device's own echo, its V2Q clone's or another device's is
        // decided inside, by whether this device built the event (`V2SentEventStore`) and by actor_device.
        let outcome = V2PairingDispatch.handleIncoming(accountKey: ownUserId, chatId: chat, wireText: text, isOutgoing: isOwn)
        switch outcome {
        case .notV2:
            // Cannot actually happen (the caller already matched the "P2:" prefix), but this function
            // owns no fallback of its own to run instead — v1's R1/P1/U1/N1 checks never see this text.
            return nil
        case let .join(notice):
            // SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.39.3–3.39.5): the four lines of a device joining by QR,
            // decided at dispatch time (`V2JoinNotice`) so a history re-render reads the same. `v2join:<what>[:…]`
            // is its own kind: `controlSummary` renders it, nothing else parses it.
            let detail: String
            switch notice {
            case let .done(safetyCode):
                detail = "v2join:done:\(safetyCode ?? "")"
                noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: the join is adopted, the chat can send now
            case let .siblingAdded(deviceCode): detail = "v2join:sibling:\(deviceCode)"
            case let .peerAdded(fromUser, deviceCode): detail = "v2join:peer:\(fromUser):\(deviceCode)"
            case .cloneSiblingRepaired:
                // PLAN.md 3.39.13 「必改项」 3: another device of this account paired the chat again; this device's clone
                // binding was set aside (history keys kept). Its own kind so the line can never be read as a v2join one.
                detail = "v2clone:sibling_repaired"
            }
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: detail))
        case let .invitedKeyChanged(fromUser, _, _, oldDeviceCode, newDeviceCode):
            // PLAN.md 3.43: the peer's INVITE is signed by an identity the current binding does not know — a
            // reinstall, or somebody wearing their name; this side cannot tell. Cached like any invite (the same
            // 〔同意配对〕 accepts it), nothing adopted, and rendered as the key-changed block rather than the ordinary
            // invitation line. Deliberately NOT `notifyPairing(.incoming)`: the "X invites you" dialog has no room
            // for the warning, and a dialog with 〔同意〕 on it would invite the blind accept this section is about.
            // `invite_key_changed:<old device>:<new device>` — 3.25.2's device codes, and no safety code: the peer cannot
            // compute one for the new identity before this side accepts, so the row asks the user to verify the person.
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil,
                detail: "peer-key:\(fromUser):ok:invite_key_changed:\(oldDeviceCode):\(newDeviceCode)"))
        case let .invited(fromUser, _, _):
            // The v2 analogue of v1's `hasIncomingInvite`: nothing is committed yet, so
            // `V2PairingDispatch.handleIncoming` (just called above) is what records this in
            // `V2PersistedState.incomingInviteStore` — a persisted store now (fix, mirrors E1), read
            // back by `startPairing`'s own v2 branch on an "accept" tap.
            // Reuses `notifyPairing`'s own freshness/dedupe rule (PLAN.md 3.7.1: only an invite dated
            // within the last 10 minutes records itself as fresh, once per chat and message date).
            // SECUTG-HOOK: this `notifyPairing` call is dual-purpose — v1's own incoming P1 and this v2
            // `.invited` outcome both funnel through it and both drive `SecutgPairingDialogs.presentInvite`
            // (the "X invites you" popup) via the `.invite` phase it raises. A prior round deleted that
            // dialog on the mistaken premise that it was v1-only UI and has since been restored: under
            // this controlled rollout an invite reaching here is effectively always v2's (v1 no longer
            // initiates fresh pairings), so the popup this triggers is now v2's own "someone wants to
            // pair with you" discoverability alert, on top of `hasIncomingInvite` (via `v2Status`)
            // passively surfacing the chat menu's own "accept" entry either way.
            notifyPairing(chatPeerId: chatPeerId, outcome: .incoming, messageDate: messageDate.map(Int64.init))
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: "peer-key:\(fromUser):ok:incoming"))
        case let .progressed(wire):
            // SECUTG-HOOK (fix): CANCEL and UNPAIR both produce this same `.progressed(wire: nil)`
            // shape since today's earlier fix wired their receive-side handling up — but neither is
            // "an intermediate step of an ongoing pairing", which is what every other `.progressed`
            // case here means. Left to fall into that shape, an UNPAIR rendered as an empty
            // "v2_progress" line (or worse, fell through some other case's default and rendered as
            // "公钥已登记" — wrong either way) instead of telling the reader their peer just unpaired.
            // v1 already has the exact right rendering for this (`controlSummary`'s own `kind ==
            // "unpair"` branch, `SecutgUnpairedByPeer`/`SecutgUnpaired`) — reuse it by writing the same
            // `"unpair:<outcome>"` detail shape v1's own U1 notice writes, rather than inventing a
            // second one.
            // SECUTG-HOOK (feature, 2026-09-27, "一键恢复"): a CANCEL whose reason is `user_reset` is the
            // peer's reset button — it tore this side's state down too (`V2PairingDispatch`), so it
            // reads as the peer unpairing, not as an unremarkable intermediate step.
            if let envelopeType = V2Envelope.parse(prefix: V2Messages.prefix, text: text)?.type,
               envelopeType == "UNPAIR" || (envelopeType == "CANCEL" && V2Messages.parseCancel(text)?.body.reason == "user_reset") {
                return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: "unpair:ok"))
            }
            // SECUTG-HOOK (fix): the peer's "换新密钥" (V2Roster rekey) landing here too — same shape
            // of bug as UNPAIR above, left to fall through it would land on the generic "v2_progress"
            // shape (renders as nothing) instead of telling the reader their peer just changed the key.
            // `SecutgPairKeyChanged` already says exactly this ("🔑 对方换了新密钥...请重新核对安全码"),
            // reused as-is rather than the fuller v1 `key_changed` shape (which expects device-switch
            // fields v2's simpler binding model has no equivalent for). Kind is `v2rekey`, not `rekey`:
            // v1 already owns that kind for its own, differently-shaped R1 rekey/welcome rendering
            // (`RekeyLine`) -- reusing it here would feed this detail's `parts` into that parser.
            if let envelopeType = V2Envelope.parse(prefix: V2Messages.prefix, text: text)?.type, envelopeType == "ROSTER_COMMIT" {
                return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: "v2rekey:ok"))
            }
            // SECUTG-HOOK (fix, 2026-09-27 真机): the peer abandoned the exchange (a CANCEL that is not a reset) —
            // said as such (`SecutgV2Cancelled`), never an empty bubble, and never read as a completing step.
            if V2PairingDispatch.receivedProgressLine(text) == .cancelled {
                if let wire { v2PairingWires.putNext((chatPeerId, wire)) }
                return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: V2PairingLine.cancelled.detail))
            }
            // A binding for this chat becoming installed by THIS exact call is what "completed the
            // pairing" means for v2 — the initiator's own moment is processing CONFIRM (`wire` is the
            // READY still to relay onward), the responder's is processing READY (`wire` is nil, nothing
            // left to send).
            // SECUTG-HOOK (fix, 2026-09-27): "completed" means the chat's current binding came from THIS
            // message's own transaction. Merely having a binding is not enough: on a chat that is already
            // bound (a newer invite being accepted, or any other P2 step there) every intermediate step
            // used to render as "paired + code" and fire a `.done` event with the OLD binding's code.
            if let runtime = V2RuntimeRegistry.shared.runtime(for: ownUserId),
               let messageTxnId = V2Envelope.parse(prefix: V2Messages.prefix, text: text)?.txnId,
               let txnId = runtime.pairing.bindingStore.current(chat)?.txnId, txnId == messageTxnId,
               let code = runtime.pairing.getSafetyCode(txnId)?.shortCode {
                // `shouldConfirm: false` on both sides here, unlike v1's `notifyPairing`'s always-true
                // rule for its own `.paired` outcome: v1 only ever has ONE call site completing any
                // given pairing this way, but v2 has two (the initiator on CONFIRM, the responder on
                // READY) — applying v1's rule unchanged would send the "🔒 Encryption is on" text
                // twice. Scoped out of this round (PLAN.md UI-01): nobody sends it for a v2 pairing yet.
                noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: the binding is sendable from here on
                pairingEvents.putNext(SecutgPairingEvent(chatPeerId: chatPeerId, phase: .done, code: code, shouldConfirm: false))
                if let wire { v2PairingWires.putNext((chatPeerId, wire)) }
                return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: "peer-key:\(chat):ok:paired:\(code)"))
            }
            // An intermediate step (ACCEPT processed by the initiator -> SELECT to relay; SELECT
            // processed by the responder -> CONFIRM to relay; a crossed invite answered with MERGE/ACCEPT/BUSY):
            // the wire this step produced still has to reach the peer.
            // SECUTG-HOOK (fix, 2026-09-27 真机): and the bubble says a pairing is in progress
            // (`SecutgV2Handshake`) — the old "v2_progress" detail rendered as an EMPTY bubble, which looks broken.
            if let wire { v2PairingWires.putNext((chatPeerId, wire)) }
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: V2PairingLine.handshake.detail))
        case .conflict:
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: "peer-key:\(chat):ok:other_device"))
        case let .ignored(reason):
            // SECUTG-HOOK (fix, 2026-09-27 真机): one pure mapping (`V2PairingDispatch.ignoredLine`, unit-tested in
            // SecutgCore, identical to Android's lines) instead of special-casing echoes one bug report at a time
            // and rendering the rest as an EMPTY bubble ("v2_progress"). This device's own echo (`own_echo:<type>`,
            // `handleIncoming` never processes one): INVITE → `SecutgPairInviteSent`; ACCEPT/SELECT/CONFIRM/MERGE/BUSY
            // → `SecutgV2Handshake`; READY → `SecutgV2ReadySent`; CANCEL → `SecutgV2Cancelled`, except a
            // CANCEL(user_reset), which reads like this device's own UNPAIR. The own UNPAIR / ROSTER_COMMIT echoes
            // keep the detail shapes they already had (`unpair:own_echo`, `v2rekey:own_echo`). A peer's MERGE is a
            // handshake step, a peer's BUSY says they are in another pairing, anything else is ignored.
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil,
                                                                                    detail: V2PairingDispatch.ignoredLine(reason: reason, wire: text).detail))
        case .failed:
            // SECUTG-HOOK (fix, 2026-09-27 真机): any refused P2 — bad signature, expired, unknown / cancelled txn,
            // replay, malformed — reads `SecutgV2Ignored`. It used to be `peer-key:<chat>:<reason>`, i.e.
            // "公钥已忽略：<raw reason code>" on the reader's screen.
            return Incoming(text: text, entities: nil, meta: SecutgTextMetaAttribute(kind: .control, keyId: nil, detail: V2PairingLine.ignored.detail))
        }
    }

    // MARK: reading a sealed message back (PLAN.md 3.19)

    /// What the render funnels get for a message stored as its envelope.
    public enum Opened: Equatable {
        case opened(text: String, entities: [MessageTextEntity])
        /// `detail` is a `DecryptResult.Reason` raw value, so the PLAN.md 3.17 notice says which situation this is.
        case locked(detail: String?)
    }

    /// Opens a message that was stored as its envelope. The cache answers for anything this session has already
    /// read; anything else is decrypted again, which is exactly what a restart leaves us with. A failure here means
    /// the key that opened this message once is gone — a wipe, an unpair, a rotated-away master — so the reader gets
    /// the 3.17 notice rather than a line of base64.
    ///
    /// Chat-less: only the wipe phrase scan of Saved Messages reads here; every render funnel goes through the
    /// chat-aware `openSealed(wire:chatPeerId:)`. A v2 row (PLAN.md 3.44) read without a chat is opened under the
    /// chat its own header names — this device's own name for it only in a group and in Saved Messages, which is
    /// exactly the chat-less caller.
    public func openSealed(wire: String) -> Opened {
        return openSealed(wire: wire, chat: nil)
    }

    /// SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.44): the reader for both generations. `chat` is the key of the
    /// chat the row is in — a v2 private chat's binding is filed under THIS device's own name for the chat (fix C0),
    /// so the header's `chat_id`, the sender's name for it, is only the fallback for a caller that has none.
    func openSealed(wire: String, chat: String?) -> Opened {
        if let hit = plaintextCache.opened(wire: wire) {
            return .opened(text: hit.text, entities: SecutgEntityMapper.fromEnvelope(hit.entities))
        }
        if V2E2.isWire(wire) {
            // The v2 receive function again (`openStoredText`): idempotent — the data key is a pure function of
            // persisted state, and the replay index answers a wire it has already seen with the same words — and
            // nothing is persisted for a draw. A refusal is folded onto the three 3.17 situations, never its code.
            let chatId = chat ?? V2E2.parse(wire)?.header.chatId ?? ""
            switch V2Dispatch.openStoredText(accountKey: ownUserId, chatId: chatId, wireText: wire) {
            case .decrypted(let plaintext):
                plaintextCache.remember(wire: wire, text: plaintext, entities: [])
                return .opened(text: plaintext, entities: [])
            case .failed(let reason):
                return .locked(detail: V2Dispatch.storedFailureDetail(reason: reason))
            case .notV2:
                break
            }
        }
        let result = E1Codec.decrypt(wire: wire) { [ring] keyId in ring.lookupSessionKey(keyId) }
        guard result.ok, let plaintext = result.text else { return .locked(detail: result.reason?.rawValue) }
        plaintextCache.remember(wire: wire, text: plaintext, entities: result.entities ?? [])
        return .opened(text: plaintext, entities: SecutgEntityMapper.fromEnvelope(result.entities ?? []))
    }

    /// PLAN.md 3.19 / 3.44: does this chat keep only the envelope on disk? v1's own flag (`KeyRing`, which also
    /// knows the 3.38 group-password forcing), or — the switch being on — a v2 binding / group state. The one answer
    /// for a wire of either generation; the two receive branches each ask their own half directly.
    private func keepsCiphertextLocally(chat: String) -> Bool {
        return ring.keepsCiphertextLocally(chat)
            || V2Dispatch.keepsCiphertextLocally(accountKey: ownUserId, chatId: chat, localCiphertext: ring.getLocalCiphertext())
    }

    /// PLAN.md 3.19: whether encrypted chats keep only the envelope on disk. Read by the settings row.
    public var localCiphertext: Bool { return ring.getLocalCiphertext() }

    /// PLAN.md 3.19: the setting. It applies to messages stored from now on — messages already written in readable
    /// form stay as they are, because walking the whole database to rewrite them is the one failure mode worse than
    /// the problem it fixes. The emergency wipe is what removes those.
    public func setLocalCiphertext(_ isEnabled: Bool) {
        ring.setLocalCiphertext(isEnabled)
        forgetOpenedMessages()
    }

    /// Drops the opened-message cache. Safe at any time: the envelopes are still in the database and open again
    /// from the keyring. Called whenever the keyring loses or changes keys.
    public func forgetOpenedMessages() {
        plaintextCache.forgetAll()
    }

    // MARK: emergency wipe (PLAN.md 3.16 / 3.22)
    //
    // The instant, purely-local, cannot-fail core of the wipe (step ①). The network side — sending
    // the phrase to Saved Messages, terminating other sessions, purging the Telegram database and
    // signing out — is orchestrated by the UI layer (`SecutgWipe` in TelegramUI), which owns the
    // account, network and logout facilities this module deliberately does not import.

    /// PLAN.md 3.16 item 5: tapping the wipe row asks for confirmation first. Read by the settings row.
    public var wipeNeedsConfirmation: Bool { return ring.getWipeNeedsConfirmation() }
    public func setWipeNeedsConfirmation(_ value: Bool) { ring.setWipeNeedsConfirmation(value) }

    /// PLAN.md 3.16 item 7 / 3.22.2: the extra Saved Messages phrase, or nil when none is set.
    public var wipeCustomPhrase: String? { return ring.getWipeCustomPhrase() }
    /// Returns the rejection reason, or nil on success; an empty/whitespace string clears the phrase.
    @discardableResult
    public func setWipeCustomPhrase(_ raw: String) -> WipePhrase.PhraseRejection? { return ring.setWipeCustomPhrase(raw) }

    /// PLAN.md 3.16 item 8 / 3.22.4: whether this device scans Saved Messages for the phrase at all.
    public var wipeListensToPhrase: Bool { return ring.getWipeListensToPhrase() }
    public func setWipeListensToPhrase(_ value: Bool) { ring.setWipeListensToPhrase(value) }

    /// PLAN.md 3.16 item 9 / 3.22.6: whether a local wipe also ends the account's other sessions.
    public var wipeResetsAuthorizations: Bool { return ring.getWipeResetsAuthorizations() }
    public func setWipeResetsAuthorizations(_ value: Bool) { ring.setWipeResetsAuthorizations(value) }

    /// PLAN.md 3.16 step ①: destroy every key and every wipe preference on this device, in memory and
    /// on disk, and drop the opened-message cache. Instant, local and cannot fail — this must run
    /// *before* the network side of the wipe is attempted (PLAN.md 3.22.8), so an offline device
    /// still wipes itself even though it cannot tell the others.
    public func destroyKeyring() {
        ring.destroyAllKeys()
        // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): the unlock table went with the keys; the attempt count goes too.
        groupPasswordLimiter.reset()
        // SECUTG-HOOK (fix, 2026-09-27): v2's own state goes in the same step — see V2PersistedState.wipe().
        V2RuntimeRegistry.shared.runtime(for: ownUserId)?.persisted.wipe()
        V2RuntimeRegistry.shared.reset(for: ownUserId)
        plaintextCache.forgetAll()
    }

    /// PLAN.md 3.22.3 / 3.22.5: given the Saved Messages the UI fetched (built into `candidates`) and
    /// the marker this device already acted on, return the message that should trigger the wipe, or
    /// nil. Pure delegation to `SecutgCore.WipeScan`, using this device's own custom phrase; the
    /// scheduling and the fetch are the UI layer's job (PLAN.md 3.22.4).
    public func findWipeTrigger(in candidates: [WipeScan.Candidate], nowSeconds: Int64, consumed: WipeScan.Consumed?) -> WipeScan.Candidate? {
        return WipeScan.findTrigger(candidates, options: WipeScan.Options(
            nowSeconds: nowSeconds, userId: ownUserId, customPhrase: ring.getWipeCustomPhrase(), consumed: consumed))
    }

    /// What the send path should leave in the database for our own copy of an outgoing message.
    /// `text` / `entities` nil mean "keep what is stored"; a non-nil `text` is the envelope written in place of the
    /// words (PLAN.md 3.19).
    public struct LocalCopy {
        public let text: String?
        public let entities: [MessageTextEntity]?
        public let meta: SecutgTextMetaAttribute?
        /// The exact plaintext `text` is the envelope of. The caller substitutes only when the message it is about
        /// to rewrite still says this, so a text that changed under us is left alone rather than replaced by an
        /// envelope of something else.
        public let plaintext: String?

        init(text: String? = nil, entities: [MessageTextEntity]? = nil, meta: SecutgTextMetaAttribute? = nil, plaintext: String? = nil) {
            self.text = text
            self.entities = entities
            self.meta = meta
            self.plaintext = plaintext
        }

        public var isEmpty: Bool { return text == nil && entities == nil && meta == nil }
    }

    /// The local copy of an outgoing message (B2 badge): 🔒 for text we encrypted, the readable summary for a
    /// control message we sent. The server echo of our own message carries the ciphertext / raw control text again,
    /// but Telegram keeps the local text, so this has to be attached at send time.
    ///
    /// PLAN.md 3.19: our own messages are written by the send path rather than by the receive hook, so the swap has
    /// to happen here too — otherwise half of an encrypted chat would still be sitting on disk in readable form.
    /// Some send results (`updateShortSentMessage`, the common one for a private chat) never re-store the message
    /// from the server's echo, so there is no second chance at it.
    public func localCopy(chatPeerId: PeerId, text: String, entities: [MessageTextEntity], encryptedWire: String?) -> LocalCopy {
        guard let wire = encryptedWire else {
            guard Rekey.isControlMessage(text) else { return LocalCopy() }
            let meta = transformIncoming(text: text, entities: [], chatPeerId: chatPeerId, senderPeerId: accountPeerId, messageDate: nil)?.meta
            return LocalCopy(meta: meta)
        }
        // A group invite stays as it is: it is drawn as a card from the attribute, not from the text.
        if GroupInvite.isG1(text) {
            return LocalCopy(meta: groupInviteMeta(text, chatPeerId: chatPeerId, isOwn: true))
        }
        // PLAN.md 3.44: a v2 chat's wire is `E2:` and carries no key id of its own; "v2" is the marker the receive
        // hook writes for one. The seal decision is the same as for a received message, for either generation.
        let keyId = E1Format.parse(wire)?.keyId ?? (V2E2.isWire(wire) ? "v2" : nil)
        let envelopeEntities = SecutgEntityMapper.toEnvelope(entities)
        let stored = SecutgPersist.storedForm(
            plaintext: text, entities: envelopeEntities, wire: wire,
            keepsCiphertextLocally: keepsCiphertextLocally(chat: SecutgAccountRuntime.chatKey(chatPeerId)))
        guard stored.isSealed else {
            // SECUTG-HOOK (PLAN.md 3.17 rule 6): our own message keeps its envelope too — "carry this to the device
            // that has the key" and "check this was not altered" are asked about sent messages as often as received.
            return LocalCopy(meta: SecutgTextMetaAttribute(kind: .decrypted, keyId: keyId, detail: nil, wire: wire))
        }
        plaintextCache.remember(wire: wire, text: text, entities: envelopeEntities)
        return LocalCopy(text: stored.text, entities: [], meta: SecutgTextMetaAttribute(kind: .sealed, keyId: keyId, detail: nil), plaintext: text)
    }

    /// The other half of `localCopy` for a control message: the same `P1` again, once the server has given it a
    /// date (PLAN.md 3.7 rule 13).
    ///
    /// `localCopy` runs before the message exists, so it can only pass `messageDate: nil` — and `startedAt`,
    /// which `RekeyProcessor` weighs against a sibling device's `P1`, may only ever hold a **server** date, the
    /// one clock two devices of one account share. The usual send result in a private chat is
    /// `updateShortSentMessage`, which patches the local message with an id and a date and never rebuilds it from
    /// the server's own copy, so `StoreMessage(apiMessage:)` — where every other control message reaches the
    /// keyring — never sees our own `P1` at all. Without this call `startedAt` stays empty for the life of the
    /// pairing, every sibling `P1` stays parked, and two devices of this account both go on encrypting, each with
    /// its own master: the exact fork rule 13 exists to prevent.
    ///
    /// Returns the refreshed badge for the local copy, or nil when this was not a control message.
    @discardableResult
    public func applySentControlDate(chatPeerId: PeerId, text: String, messageDate: Int32) -> SecutgTextMetaAttribute? {
        guard Rekey.isControlMessage(text) else { return nil }
        return transformIncoming(text: text, entities: [], chatPeerId: chatPeerId, senderPeerId: accountPeerId,
                                 messageDate: messageDate, isOutgoing: true)?.meta
    }

    /// PLAN.md 3.13 rule 2: only the peer of a private chat may hand us a group key, so `via` is that peer; our own
    /// echo is just a "sent" line; anything else (malformed, or a `G1` inside a group) is an invalid card.
    private func groupInviteMeta(_ text: String, chatPeerId: PeerId, isOwn: Bool) -> SecutgTextMetaAttribute {
        let parsed = GroupInvite.parse(text)
        let via: String? = isPrivateChat(chatPeerId) ? SecutgAccountRuntime.userId(chatPeerId) : nil
        let ok = parsed != nil && (isOwn || via != nil)
        // The id is a pure function of the key, so the card can ask the live keyring whether it holds this exact
        // master — which is what "already joined" means, rather than "the group has some key"
        let masterId = SecutgAccountRuntime.inviteMasterId(keyPayload: parsed?.keyPayload)
        let invite = SecutgTextMetaAttribute.GroupInvite(
            ok: ok, isOwn: isOwn, groupChatId: parsed?.groupChatId, title: parsed?.title, keyPayload: parsed?.keyPayload,
            masterId: masterId, via: via)
        return SecutgTextMetaAttribute(kind: .groupInvite, keyId: nil, detail: ok ? "ok" : "invalid", invite: invite)
    }

    /// The safety code rides along in `detail` for the "paired" system line, and — PLAN.md 3.25.5/3.25.6 rule 5 —
    /// a takeover or a key change carries the device ids and this device's own (local-only) labels for them too:
    /// the bubble renderer (`controlSummary`, static) has no keyring access, so everything it needs is baked in
    /// here at transform time, the same way the safety code already was. A sentinel "-" stands in for "absent"
    /// so a missing segment never collapses the ones after it.
    private func pairingDetailSuffix(_ result: RekeyProcessor.Result, chat: String) -> String {
        switch result.pairing {
        case .paired, .selfPaired:
            guard let code = safetyCode(chat: chat) else { return "" }
            var suffix = ":\(code)"
            if let deviceId = result.takeoverDeviceId {
                suffix += ":takeover:\(deviceId):\(SecutgAccountRuntime.encodeDetailLabel(ring.deviceLabel(deviceId)?.label))"
            }
            return suffix
        case .keyChanged:
            guard let pairing = ring.chatPairing(chat) else { return "" }
            let newId = pairing.peerDeviceId
            let oldId = pairing.peerSeenDeviceIds?.last
            return ":\(newId ?? "-"):\(SecutgAccountRuntime.encodeDetailLabel(newId.flatMap { ring.deviceLabel($0)?.label }))"
                + ":\(oldId ?? "-"):\(SecutgAccountRuntime.encodeDetailLabel(oldId.flatMap { ring.deviceLabel($0)?.label }))"
        default:
            return ""
        }
    }

    /// "-" for no label, otherwise percent-encoded so free-text user labels can never break the ":"-separated
    /// `detail` wire format. Paired with `SecutgAccountRuntime.decodeDetailLabel`.
    private static func encodeDetailLabel(_ label: String?) -> String {
        guard let label = label, !label.isEmpty,
              let encoded = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !encoded.isEmpty else { return "-" }
        return encoded
    }

    fileprivate static func decodeDetailLabel(_ raw: String) -> String? {
        guard raw != "-", !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding
    }

    /// Mirrors Web A `notifyPairing`: a completed pairing always pops the safety-code dialog (and this side sends the
    /// confirmation text); a peer's invite pops the dialog only when it is fresh, once per chat and message date.
    private func notifyPairing(chatPeerId: PeerId, outcome: RekeyProcessor.PairingOutcome?, messageDate: Int64?) {
        if outcome == .paired {
            noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: a v1 pairing that completed arms the flag
            guard let code = safetyCode(chat: SecutgAccountRuntime.chatKey(chatPeerId)) else { return }
            pairingEvents.putNext(SecutgPairingEvent(chatPeerId: chatPeerId, phase: .done, code: code, shouldConfirm: true))
            return
        }
        guard outcome == .incoming, let messageDate = messageDate else { return }
        let now = Int64(Date().timeIntervalSince1970)
        guard abs(now - messageDate) < SecutgAccountRuntime.freshInviteSeconds else { return }
        let key = "\(chatPeerId.toInt64()):\(messageDate)"
        notifiedInvitesLock.lock()
        let seen = notifiedInvites.contains(key)
        if !seen { notifiedInvites.insert(key) }
        notifiedInvitesLock.unlock()
        if seen { return }
        pairingEvents.putNext(SecutgPairingEvent(chatPeerId: chatPeerId, phase: .invite, code: nil, shouldConfirm: false))
    }

    // MARK: A1–A4 send

    public func prepareOutgoing(chatPeerId: PeerId, text: String, entities: [MessageTextEntity]) -> Outgoing {
        guard chatPeerId.namespace != Namespaces.Peer.SecretChat else { return .passthrough }
        // SECUTG-HOOK (fix, 2026-09-28 真机): a group whose password is not unlocked in this run sends NOTHING —
        // not even through a path that would otherwise fall back to plaintext. Found on macOS, where typing on the
        // password page reached the composer hidden under it.
        // PLAN.md 3.38.2: except the app's own control messages (a rebuild `G2`, a `GP1`, `R1`/`P1`/`N1`…) — they
        // carry no user words, and refusing one after the keyring has moved would leave the group without it.
        if GroupPasswordSendGate.refuses(locked: needsGroupPassword(chatPeerId: chatPeerId), text: text) { return .failed(.noKey) }
        // SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.41.2): a chat that has encrypted once refuses the user's content
        // while it has no usable send key — 3.38's gate, generalised to every chat that ever held a key. Protocol
        // lines (`P2` / `G2` / `GP1` / `N1` / `U1` …), already-sealed envelopes and the wipe phrase pass: they are how
        // a key comes back, or leave in the clear by design. Nothing is sent and the draft is kept; the chat on
        // screen shows `SecutgKeyRequiredBlocked` (`keyRequiredRefusals`). A 3.38-locked group never gets this far.
        if let refusal = keyRequiredRefusal(chatPeerId: chatPeerId, text: text) { return .failed(refusal) }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK (fix 2026-10-07, PLAN.md 3.0 fail closed): v2 chats are data-determined
        // (`V2Dispatch`), never a global switch — a chat this device has never v2-paired stays on
        // every line below exactly as before. v2's `V2DataProcessor` takes plain plaintext bytes only
        // (no entities field yet), so entities are dropped on the v2 wire — but they must NEVER gate
        // whether v2 is even tried. A message with an auto-detected mention/hashtag/URL carries
        // non-empty `entities`; the old `entities.isEmpty` guard here skipped v2 entirely for such
        // text and fell through to v1's `isChatEncrypted` check below, which is false for a v2-only
        // chat, sending the user's words in the CLEAR (real-device find, 2026-10-07). Ask v2 first for
        // ANY non-empty text: auto-detectable entities (mention/hashtag/cashtag/bot command/url/email/
        // phone) are re-detected by the receiving client from the plain text anyway; explicit
        // formatting (bold/italic/code/spoiler/text-link/custom emoji/mention-by-id) is lost on v2 —
        // acceptable, never a reason to send plaintext.
        switch V2Dispatch.prepareOutgoingTextFailClosed(accountKey: ownUserId, chatId: chat, text: text) {
        case .sent(let wire):
            return .encrypted(wire)
        case .failed:
            return .failed(.cryptoError("v2"))
        case .notOnV2:
            break
        }
        // PLAN.md 3.13: a group invite carries the group key and may only travel inside an encrypted private chat
        let isInvite = GroupInvite.isG1(text)
        if isInvite && !isPrivateChat(chatPeerId) { return .failed(.inviteNeedsEncryption) }
        // PLAN.md 3.22.7: the wipe phrase leaves Saved Messages in the CLEAR, whoever put it there —
        // the wipe button's broadcast and the user typing it in by hand (3.22.2) are the same trigger
        // taking the same road. Checked BEFORE `isChatEncrypted` precisely because Saved Messages is
        // encrypted by default (3.20): an `E1:` envelope is unreadable to every device that never
        // received this keyring, which is exactly the set of devices the fan-out exists to reach.
        //
        // Stateless, and that is the point. The flag-flipping version of this exemption
        // (`setChatEncryption(ownUserId, false)` before the broadcast) exempted only the button, never
        // the hand-typed phrase, and left Saved Messages permanently unencrypted whenever the wipe did
        // not run to completion.
        if WipePhrase.isWipePhraseToSelf(chatId: chat, ownUserId: ownUserId, text: text,
                                         customPhrase: ring.getWipeCustomPhrase()) {
            return .passthrough
        }
        // Control messages and already-encrypted retries go out untouched (idempotent on resend). Hoisted
        // above the encryption test so that the fail-closed branch below can never strand an `R1` / `P1`:
        // those are how a chat gets its key back, and refusing them would make the refusal permanent.
        if !text.isEmpty, Rekey.isControlMessage(text) || E1Format.isEncrypted(text) { return .passthrough }
        guard ring.isChatEncrypted(chat), !text.isEmpty else {
            if isInvite { return .failed(.inviteNeedsEncryption) }
            // PLAN.md 3.0 — fail closed. Reaching here means the switch is not on, and there are two very
            // different reasons for that: the user never turned it on (or turned it off), which is a
            // decision and lets the message through; or this device has lost track of the switch, which is
            // a fault and must not be read as a decision. Before the channel-key migration existed, a
            // keyring written under the old `"-100" + id` spelling produced exactly the second case on
            // every channel it held, and this line passed the message through in the clear — an encrypted
            // conversation silently downgrading itself is the worst outcome this product has.
            if !text.isEmpty, ring.isEncryptionStateUnknown(chat) { return .failed(.encryptionStateUnknown) }
            return .passthrough
        }
        guard let current = ring.currentKey(chatId: chat) else { return .failed(.noKey) }
        let limit = crypto.maxPlaintextChars
        if text.utf16.count > limit { return .failed(.tooLong(chars: text.utf16.count, limit: limit)) }
        do {
            let wire = try E1Codec.encrypt(text: text, entities: SecutgEntityMapper.toEnvelope(entities), keyId: current.keyId, sessionKey: current.sessionKey)
            return .encrypted(wire)
        } catch SecutgCryptoError.plaintextTooLong(let chars) {
            return .failed(.tooLong(chars: chars, limit: limit))
        } catch {
            return .failed(.cryptoError("\(error)"))
        }
    }

    /// Cloud drafts: nil means "send an empty draft" — plaintext must never reach the server for an encrypted chat.
    public func prepareDraft(chatPeerId: PeerId, text: String, entities: [MessageTextEntity]) -> String? {
        switch prepareOutgoing(chatPeerId: chatPeerId, text: text, entities: entities) {
        case .passthrough: return text
        case let .encrypted(wire): return wire
        case .failed(.keyRequired):
            // PLAN.md 3.41.2: the flag is on and the chat has no key. A cloud draft in the clear is the same leak as
            // a message in the clear, so an empty draft goes up instead — silently: the notice (3.41.3) is for a send
            // the user asked for, not for every keystroke.
            return nil
        case let .failed(failure):
            reportSendFailure(failure, chatPeerId: chatPeerId, isDraft: true)
            return nil
        }
    }

    public func shouldStripReplyQuote(chatPeerId: PeerId) -> Bool {
        return ring.isChatEncrypted(SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// Does this chat encrypt what leaves this device? Asked by the forward hook (PLAN.md 3.20) before it decides
    /// whether a server-side copy is acceptable.
    public func isChatEncrypted(chatPeerId: PeerId) -> Bool {
        guard chatPeerId.namespace != Namespaces.Peer.SecretChat else { return false }
        return ring.isChatEncrypted(SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// PLAN.md 3.20: announce that `count` forwards into `chatPeerId` were re-sent encrypted instead of copied.
    public func reportForwardReencrypted(chatPeerId: PeerId, count: Int) {
        guard count > 0 else { return }
        forwardNotices.putNext((chatPeerId, count))
    }

    /// Throttled to one report per chat per 5 s so a stuck draft does not spam the UI.
    public func reportSendFailure(_ failure: SecutgSendFailure, chatPeerId: PeerId, isDraft: Bool = false) {
        let now = Date().timeIntervalSince1970
        lastFailureLock.lock()
        let last = lastFailureAt[chatPeerId] ?? 0
        let throttled = isDraft && now - last < 5
        if !throttled { lastFailureAt[chatPeerId] = now }
        lastFailureLock.unlock()
        NSLog("[secutg] send blocked for \(chatPeerId): \(failure)\(isDraft ? " (draft)" : "")")
        if !throttled { sendFailures.putNext((chatPeerId, failure)) }
        // PLAN.md 3.41.3: the refusal's own channel, so the chat on screen can put the inline notice up.
        if case .keyRequired = failure, !isDraft { keyRequiredRefusals.putNext(chatPeerId) }
    }

    // MARK: UI-facing API (mirrors Web A `hooks/methods.ts`)

    public func status(chatPeerId: PeerId) -> SecutgChatStatus {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let current = ring.currentKey(chatId: chat)
        let pairing = ring.chatPairing(chat)
        // SECUTG-HOOK (fix, 2026-09-27 真机): v2-first (`V2PairingStatus.resolve`, unit-tested in SecutgCore). This
        // used to be `pairing?.state ?? v2...`: a leftover v1 "invited" on a chat v2 had paired kept the menu on
        // 等待对方同意, and the pairing tap it offered sent a v1 P1 the peer could never accept. Now: v2's state,
        // verified flag and code whenever v2 has anything for the chat; otherwise the v1 record, and only when it
        // is a real "paired" — v1 "invited"/"key_changed"/"other_device" read as nothing. The incoming invite is
        // v2-only: no client sends a v1 P1 any more, so a leftover v1 peer key (`memberPk`) no longer counts.
        let resolved = resolvedPairing(chat: chat, v1: pairing)
        // Everything else read off the v1 record — device ids, start / pair dates — only when it is what is shown.
        let shownV1 = resolved.source == .v1 ? pairing : nil
        var status = SecutgChatStatus(
            encryptionEnabled: ring.isChatEncrypted(chat),
            // SECUTG-HOOK: deliberately NOT true for a v2-only pairing — v2 has no on/off switch of its
            // own (`V2Dispatch.prepareOutgoingText` encrypts every plain-text send unconditionally once
            // a binding exists, matching the Web reference's "on by data, not by a switch" design), so
            // the toggle menu entry this field gates would show a control that does nothing. A known,
            // bounded gap for this round (PLAN.md UI-01): the "手动配对" entry stays visible on an
            // already-v2-paired chat too, offering an offline key nothing would ever use to send.
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a group whose current key is password-locked HAS a key.
            hasKey: ring.chatMasterId(chat) != nil || ring.groupPasswordRecord(chat)?.active == true,
            currentKeyId: current?.keyId,
            masterId: ring.chatMasterId(chat),
            isAdmin: ring.chatAdminSk(chat) != nil,
            hasAdminPk: ring.chatAdminPk(chat) != nil,
            memberCount: ring.listMemberIds(chatId: chat).count,
            hasIdentity: ring.identity != nil,
            isPrivateChat: isPrivateChat(chatPeerId),
            pairingState: resolved.pairingState,
            pairingVerified: resolved.verified,
            hasIncomingInvite: isPrivateChat(chatPeerId) && resolved.hasIncomingInvite,
            keyAgeDays: ring.keyAgeDays(chat),
            isRekeyDue: ring.isRekeyDue(chat),
            isForwardSecrecy: ring.chatRatchet(chat) != nil,
            keySource: ring.chatKeySource(chat),
            onlineInvites: ring.onlineInvites(chatId: chat),
            peerDeviceId: shownV1?.peerDeviceId,
            // PLAN.md 3.25.3: not read off the stored field directly — completePairing deliberately leaves
            // ownDeviceId untouched until this device's own P1 echoes back (that is what lets a later echo
            // recognise a takeover), so a state other than "other_device" always means this device itself.
            ownDeviceId: shownV1 == nil ? nil : (shownV1?.state == .otherDevice ? shownV1?.ownDeviceId : ring.ownDeviceIdentity()?.deviceId),
            pairingStartedAt: shownV1?.startedAt,
            pairedAt: shownV1?.pairedAt,
            keyMode: ring.chatKeyMode(chat),
            // SECUTG-HOOK (fix, 2026-09-27): see the field's own doc — the badge's question, not the toggle's.
            hasKeyOrV2: ring.chatMasterId(chat) != nil || ring.groupPasswordRecord(chat)?.active == true
                || V2RuntimeRegistry.shared.runtime(for: ownUserId)?.pairing.bindingStore.current(chat) != nil,
            hasResidualV1Pairing: resolved.hasResidualV1Pairing,
            isV2Paired: resolved.source == .v2 && resolved.pairingState == "paired",
            hasV2PairingState: resolved.source == .v2,
            groupPassword: isPrivateChat(chatPeerId) ? .none : groupPasswordState(chat: chat),
            legacyGroupPasswordLocked: !isPrivateChat(chatPeerId) && ring.needsLegacyGroupPassword(chat))
        // PLAN.md 3.41.1: every status read is also a look at the chat's send key, so a chat that gained a key by
        // any road is armed the next time anything draws it (auto-arm), and the menu's switch reads the flag as it
        // stands.
        noteKeyRequired(chatPeerId: chatPeerId)
        status.keyRequired = keyRequired(chatPeerId: chatPeerId)
        return status
    }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): the v2-first pairing status every UI-facing read goes through —
    /// `status`, `safetyCode`, `unpair`, `setPairingVerified` — so they can never disagree about which protocol
    /// a chat's pairing belongs to. `V2PairingStatus.of` is `.none` without a v2 runtime.
    private func resolvedPairing(chat: String, v1: KeyRing.Pairing?) -> V2PairingStatus.Resolved {
        return V2PairingStatus.resolve(V2PairingStatus.of(accountKey: ownUserId, chatId: chat),
                                       v1State: v1?.state.rawValue, v1Verified: v1?.verified ?? false)
    }

    // MARK: the forward funnel (PLAN.md 3.38.2 / 3.41.2)

    /// A forward is a server-side copy that never meets `prepareOutgoing` (the 3.20 re-send only takes text into a
    /// chat that encrypts; media, and any forward into a chat that has lost its key, would still be copied by the
    /// server). So the forward funnel asks the same two gates, in the same order (`ForwardGate`), for the target chat.
    /// True = drop the forward, nothing sent; the refusal is reported exactly as a refused send is, so the chat shows
    /// the same notice (3.41.3) — a locked group is behind its password page already.
    public func refusesForward(chatPeerId: PeerId) -> Bool {
        guard chatPeerId.namespace != Namespaces.Peer.SecretChat else { return false }
        let state = noteKeyRequired(chatPeerId: chatPeerId)
        let flag = keyRequiredStore?.isRequired(SecutgAccountRuntime.chatKey(chatPeerId)) ?? false
        guard let refusal = ForwardGate.refusal(groupPasswordLocked: needsGroupPassword(chatPeerId: chatPeerId), keyRequired: flag,
                                                chatKind: keyRequiredChatKind(chatPeerId: chatPeerId), keyState: state) else { return false }
        switch refusal {
        case .groupPasswordLocked: reportSendFailure(.noKey, chatPeerId: chatPeerId)
        case .keyRequired: reportSendFailure(.keyRequired, chatPeerId: chatPeerId)
        }
        return true
    }

    // MARK: refuse to send without a key (PLAN.md 3.41)

    /// The per-chat flags live in `V2PersistedState` (`KeyRequiredStore`'s own doc says why: that store never
    /// leaves the device and the wipe destroys it). nil until the v2 runtime is bootstrapped for this account, in
    /// which case the flag reads as off and nothing is armed — `Account.init` bootstraps it right after this runtime.
    private var keyRequiredStore: KeyRequiredStore? {
        return V2RuntimeRegistry.shared.runtime(for: ownUserId)?.persisted.keyRequiredStore
    }

    private func persistKeyRequired() {
        V2RuntimeRegistry.shared.runtime(for: ownUserId)?.persisted.persist()
    }

    /// Which of 3.41.1's three kinds this chat is. Saved Messages first: it is a user peer too.
    public func keyRequiredChatKind(chatPeerId: PeerId) -> KeyRequired.ChatKind {
        if chatPeerId == accountPeerId { return .savedMessages }
        if chatPeerId.namespace == Namespaces.Peer.CloudUser { return .privateChat }
        return .group
    }

    /// Whether the chat has a usable SEND key right now, and the identity of that key (`KeyRequired.observed`'s
    /// `keyId`: a v2 binding id, a v1 master id, a v2 group state hash). 3.41.2's definition: 1v1 = v2 `canSend`,
    /// else a v1 key (a legacy pairing or a manual key); group = a current group key by any road; Saved Messages =
    /// its own key. A v1 key counts whether or not the v1 switch is on — the switch is the user's own decision, and
    /// this flag is about the key being *gone*, not about the switch.
    public func keyRequiredKeyState(chatPeerId: PeerId) -> (state: KeyRequired.KeyState, keyId: String?) {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let v1KeyId: String? = ring.chatMasterId(chat).flatMap { ring.currentKey(chatId: chat) != nil ? "v1:" + $0 : nil }
        let v2 = V2RuntimeRegistry.shared.runtime(for: ownUserId)
        switch keyRequiredChatKind(chatPeerId: chatPeerId) {
        case .savedMessages:
            if let v1KeyId = v1KeyId { return (.savedKey, v1KeyId) }
            return (.noSavedKey, nil)
        case .group:
            if let v1KeyId = v1KeyId { return (.groupKey, v1KeyId) }
            if let state = v2?.persisted.groupStateStore.current(chat) { return (.groupKey, "v2g:" + state.stateHash) }
            return (.noGroupKey, nil)
        case .privateChat:
            if let v2 = v2, let binding = v2.pairing.bindingStore.current(chat) {
                if v2.pairing.canSend(chat) { return (.v2Sendable, "v2:" + binding.bindingId) }
                if let v1KeyId = v1KeyId { return (.v1LegacyOnly, v1KeyId) }
                return (.suspended, nil)
            }
            if let v1KeyId = v1KeyId { return (.v1LegacyOnly, v1KeyId) }
            guard let v2 = v2 else { return (.notPaired, nil) }
            switch V2PairingStatus.of(v2, chatId: chat).pairingState {
            case "invited", "other_device": return (.invited, nil)
            default: break
            }
            return (v2.pairing.bindingStore.historical(chat).isEmpty ? .notPaired : .unpaired, nil)
        }
    }

    /// 3.41.1 升级安装, once per device: every chat that holds a key today is armed. One flag read after the first
    /// time, so it is asked on every path that reads or writes a flag rather than at one startup moment — the v2
    /// state the store lives in is bootstrapped after this runtime is.
    private func ensureKeyRequiredMigrated() {
        guard let store = keyRequiredStore, !store.isMigrated else { return }
        if store.migrate(keyedChats: keyedChatsForKeyRequired()) { persistKeyRequired() }
    }

    /// chat key → send-key identity, for every chat this device can send encrypted to right now.
    private func keyedChatsForKeyRequired() -> [String: String] {
        var candidates = Set(ring.listKeyedChatIds())
        candidates.insert(SecutgAccountRuntime.chatKey(accountPeerId))
        if let v2 = V2RuntimeRegistry.shared.runtime(for: ownUserId) {
            candidates.formUnion(v2.pairing.bindingStore.allChatIdsWithCurrentBinding())
        }
        var out: [String: String] = [:]
        for chat in candidates {
            guard let peerId = SecutgAccountRuntime.peerId(chatKey: chat) else { continue }
            if let keyId = keyRequiredKeyState(chatPeerId: peerId).keyId { out[chat] = keyId }
        }
        return out
    }

    /// Every road a key arrives by ends here (3.41.1 自动打开): the chat's current send key is looked at, and the
    /// flag is armed if this is the chat's first key on this device, or a new one after a manual off. Also asked on
    /// every status read and every send, so a road that was missed is caught the next time the chat is drawn or
    /// written to. Returns the key state, which the send gate reads.
    @discardableResult
    func noteKeyRequired(chatPeerId: PeerId) -> KeyRequired.KeyState {
        let (state, keyId) = keyRequiredKeyState(chatPeerId: chatPeerId)
        guard let store = keyRequiredStore else { return state }
        ensureKeyRequiredMigrated()
        if store.observeKey(chatId: SecutgAccountRuntime.chatKey(chatPeerId), keyId: keyId) { persistKeyRequired() }
        return state
    }

    /// After a keyring transfer (PLAN.md 3.14) or a quick share: every chat the import keyed is armed.
    func armKeyRequiredForKeyedChats() {
        guard let store = keyRequiredStore else { return }
        ensureKeyRequiredMigrated()
        var changed = false
        for (chat, keyId) in keyedChatsForKeyRequired() where store.observeKey(chatId: chat, keyId: keyId) { changed = true }
        if changed { persistKeyRequired() }
    }

    /// 3.41.1's flag as it stands for this chat.
    public func keyRequired(chatPeerId: PeerId) -> Bool {
        ensureKeyRequiredMigrated()
        return keyRequiredStore?.isRequired(SecutgAccountRuntime.chatKey(chatPeerId)) ?? false
    }

    /// The lock menu's switch and the notice's 〔本聊天允许明文〕 (3.41.1 手动 / 3.41.3). Off remembers the current
    /// key, so auto-arm stays quiet until the chat gains a new one.
    public func setKeyRequired(chatPeerId: PeerId, enabled: Bool) {
        guard let store = keyRequiredStore else { return }
        ensureKeyRequiredMigrated()
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        if store.setManually(chatId: chat, enabled: enabled, currentKeyId: keyRequiredKeyState(chatPeerId: chatPeerId).keyId) {
            persistKeyRequired()
        }
    }

    /// 3.41.2 for one outgoing text (empty for media without a caption, a forward, a sticker — all user content).
    /// Observes the key first, so a chat that has one is armed by the very send that proves it. nil = let it through.
    private func keyRequiredRefusal(chatPeerId: PeerId, text: String) -> SecutgSendFailure? {
        guard chatPeerId.namespace != Namespaces.Peer.SecretChat, let store = keyRequiredStore else { return nil }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let state = noteKeyRequired(chatPeerId: chatPeerId)
        // Protocol lines and already-sealed envelopes are the roads a key comes back by; the wipe phrase to Saved
        // Messages leaves in the clear by design (PLAN.md 3.22.7) and must not be held up by a missing key either.
        let isControlLine = V2Dispatch.isProtocolWire(text)
            || WipePhrase.isWipePhraseToSelf(chatId: chat, ownUserId: ownUserId, text: text, customPhrase: ring.getWipeCustomPhrase())
        guard KeyRequired.shouldBlockSend(keyRequired: store.isRequired(chat), chatKind: keyRequiredChatKind(chatPeerId: chatPeerId),
                                          keyState: state, isControlLine: isControlLine) else { return nil }
        return .keyRequired
    }

    /// The UI layer's pre-check, asked before a composer send is enqueued so the draft stays in the box (3.41.2
    /// 草稿保留): would `prepareOutgoing` refuse this text for want of a key? Same rule, same observation.
    public func refusesForWantOfKey(chatPeerId: PeerId, text: String) -> Bool {
        return keyRequiredRefusal(chatPeerId: chatPeerId, text: text) != nil
    }

    /// Whether the chat is in the refusing state right now — flag on, no usable key. This is what keeps the notice
    /// (3.41.3) on screen, and what takes it down by itself when a key arrives or the flag is turned off.
    public func isRefusingWithoutKey(chatPeerId: PeerId) -> Bool {
        return refusesForWantOfKey(chatPeerId: chatPeerId, text: "")
    }

    /// The UI pre-check found a refusal: reported down the same channel the send hook uses (3.41.3).
    public func reportKeyRequiredRefusal(chatPeerId: PeerId) {
        reportSendFailure(.keyRequired, chatPeerId: chatPeerId)
    }

    // MARK: device identification and labels (PLAN.md 3.25)

    /// This device's own device_id / device_code, or nil without an identity yet.
    public func ownDeviceIdentity() -> (deviceId: String, deviceCode: String)? {
        guard let identity = ring.ownDeviceIdentity() else { return nil }
        return (identity.deviceId, identity.deviceCode)
    }

    /// The `XXX-XXX` code for any device_id this account has ever seen — recoverable from the id alone
    /// (PLAN.md 3.25.2), so it works for a peer's device too, not only this device's own.
    public static func deviceCode(forId deviceId: String) -> String? {
        return DeviceIdentity.deviceCode(forId: deviceId)
    }

    /// This device's user-written name for `deviceId`, or nil when it has none (PLAN.md 3.25.3).
    public func deviceLabel(_ deviceId: String) -> String? {
        return ring.deviceLabel(deviceId)?.label
    }

    /// A blank (or whitespace-only) label clears it. Throws only when `deviceId` is not a well-formed device id.
    public func setDeviceLabel(_ deviceId: String, _ label: String) throws {
        try ring.setDeviceLabel(deviceId: deviceId, label: label)
    }

    public func listDeviceLabels() -> [String: KeyRing.DeviceLabel] {
        return ring.listDeviceLabels()
    }

    /// PLAN.md 3.25.5: "{label} · {code}" when labelled, else "{code}（未备注）" — the one line every device
    /// display in the UI (status row, safety-code dialog, header block, settings row) should read off.
    public func deviceDisplayText(_ deviceId: String) -> String {
        let code = DeviceIdentity.deviceCode(forId: deviceId) ?? deviceId
        if let label = deviceLabel(deviceId), !label.isEmpty {
            return SecutgL10n.string("SecutgDeviceLabeled", ["label": label, "code": code])
        }
        return SecutgL10n.string("SecutgDeviceUnlabeled", ["code": code])
    }

    /// The master an invite's key payload resolves to, without importing anything — `blake2b(master)[0:8]`, the
    /// same id the keyring files the key under. The invite card carries it and the UI falls back to it for cards
    /// stored before it was carried.
    public static func inviteMasterId(keyPayload: String?) -> String? {
        return keyPayload
            .flatMap { KeyPayload.parse($0) }
            .flatMap { try? KeyDerivation.computeMasterId($0.masterKey) }
    }

    /// PLAN.md 3.13: does this device's keyring hold this exact master? Asked at render time by the invite card,
    /// which is persisted and must not bake the answer in — the card has to flip the moment the key is imported.
    public func hasMaster(_ masterId: String) -> Bool {
        return ring.listMasterIds().contains(masterId)
    }

    private func isPrivateChat(_ chatPeerId: PeerId) -> Bool {
        return chatPeerId.namespace == Namespaces.Peer.CloudUser && chatPeerId != accountPeerId
    }

    // MARK: encrypted group invite (PLAN.md 3.13, mirrors Web A `secutgPrivateChatLevel` / `secutgBuildGroupInvite` / `secutgAcceptGroupInvite`)

    public struct GroupInviteBuilt: Equatable {
        /// The `G1` text; the caller sends it as ordinary text in the private chat and the A1 hook encrypts it
        public let text: String
        public let level: OnlineInviteLevel
    }

    public enum GroupInviteError: Error { case notAdmin, noKey, privateChatNotEncrypted, badPayload }

    /// Level of the private chat with `userPeerId`, as far as trusting it with a group key goes: `manual` (offline
    /// key), `verified` / `unverified` (auto-paired), nil (not encrypted or not paired here).
    public func privateChatLevel(userPeerId: PeerId) -> OnlineInviteLevel? {
        return privateChatLevel(chat: SecutgAccountRuntime.chatKey(userPeerId))
    }

    private func privateChatLevel(chat: String) -> OnlineInviteLevel? {
        guard ring.isChatEncrypted(chat), ring.chatMasterId(chat) != nil else { return nil }
        guard let pairing = ring.chatPairing(chat) else { return .manual }
        guard pairing.state == .paired else { return nil }
        return pairing.verified ? .verified : .unverified
    }

    /// Admin side (rule 1): the group key wrapped as `G1` for the encrypted private chat with `userPeerId`; the
    /// member and the chat's level are recorded in the group's online-invite ledger.
    public func buildGroupInvite(groupPeerId: PeerId, userPeerId: PeerId, title: String) throws -> GroupInviteBuilt {
        let group = SecutgAccountRuntime.chatKey(groupPeerId)
        guard ring.chatAdminSk(group) != nil else { throw GroupInviteError.notAdmin }
        guard let level = privateChatLevel(userPeerId: userPeerId) else { throw GroupInviteError.privateChatNotEncrypted }
        guard let payload = exportPayload(chatPeerId: groupPeerId) else { throw GroupInviteError.noKey }
        let text = try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: payload, title: title))
        ring.recordOnlineInvite(chatId: group, userId: SecutgAccountRuntime.userId(userPeerId), level: level)
        return GroupInviteBuilt(text: text, level: level)
    }

    /// Member side (rule 2): imports the key from an invite card, remembers it came online through `via`'s chat,
    /// turns encryption on and returns the `P1` the caller posts in the group so the admin can include this member
    /// in rekeys. Importing the same master again is idempotent.
    public func acceptGroupInvite(groupPeerId: PeerId, keyPayload: String, via: String) throws -> String {
        let viaLevel = privateChatLevel(chat: via) ?? .unverified
        guard importMaster(chatPeerId: groupPeerId, payload: keyPayload, source: .online(via: via, viaLevel: viaLevel)) else {
            throw GroupInviteError.badPayload
        }
        return try announceIdentity()
    }

    // MARK: one-to-one pairing (PLAN.md 3.7)

    /// Invite or accept: makes sure identity keys exist, marks the chat invited (or pairs at once when the peer's
    /// key is known) and returns the P1 to send as a plain message. When the pairing completed right away (the
    /// accepting side) the safety-code dialog is announced through `pairingEvents` — without the confirmation
    /// text, which the inviting side sends when its P1 completes the pairing (Web A `secutgStartPairing`).
    /// `confirmedTakeover` is this caller's statement that the user has been through PLAN.md 3.25.6 rule 2's
    /// confirmation. A plain accept leaves it unset and is refused while another device of this account holds
    /// the pairing — which is what stops a stale invite dialog, or an old invite row scrolled back into view,
    /// from taking the pairing away from that device without a word about what it costs.
    public func startPairing(chatPeerId: PeerId, confirmedTakeover: Bool = false) throws -> SecutgPairingStart {
        // SECUTG-HOOK (fix, 2026-09-27 真机): v2 ONLY, whatever v1 records exist. This used to try v2 only when v1
        // had no record (or a v2 invite was cached) and otherwise fell through to v1's `processor.startPairing`: a
        // real device with a leftover v1 record sent a v1 P1, rendered its own bubble as "已向对方发出加密对话邀请",
        // and the peer had no 同意配对 to offer — a v1 P1 can never be accepted through v2. v1 new pairing is
        // permanently disabled (the user's ruling), so a v2 refusal is thrown (`SecutgPairingError`, shown by every
        // caller's `catch`) and never answered with a v1 P1. Every pair / accept / repair / repairHere entry, and
        // `regenerateAndRepair`, comes through here. `confirmedTakeover` belonged to v1's takeover confirmation
        // and gates nothing any more: v2's own "other device" (CONFLICT) is repaired in `startPairingV2`.
        return try startPairingV2(chatPeerId: chatPeerId, chat: SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// SECUTG-HOOK (PLAN.md UI-01): the v2 half of `startPairing(chatPeerId:)` — since the 2026-09-27 真机 fix,
    /// the whole of it. Accepts the cached incoming INVITE when there is one, otherwise sends a fresh INVITE;
    /// throws `SecutgPairingError` when v2 can do neither (no v1 fallback — see `startPairing`).
    private func startPairingV2(chatPeerId: PeerId, chat: String) throws -> SecutgPairingStart {
        guard isPrivateChat(chatPeerId), let runtime = V2RuntimeRegistry.shared.runtime(for: ownUserId) else {
            throw SecutgPairingError.v2Unavailable
        }
        // SECUTG-HOOK (fix, 2026-09-27): state `status` now reads as "nothing" must not block the fresh pairing
        // that reading offers.
        dropExpiredV2PairingState(runtime, chat: chat)
        // SECUTG-HOOK (fix, 2026-09-27 真机): 〔在本机重新配对〕 on a v2 "other_device" (CONFLICT) chat must start a
        // fresh INVITE, and the terminal CONFLICT txn would keep the in-flight guard below refusing forever.
        // Local only (`dropConflictsForChat`): the peer's copy of that exchange is terminal too.
        if runtime.pairing.dropConflictsForChat(chat) > 0 { runtime.persisted.persist() }
        if let inviteWire = runtime.persisted.incomingInviteStore.get(chat) {
            // Accept: an unaccepted incoming INVITE is already on file for this chat
            // (`V2PersistedState.incomingInviteStore`) — the explicit "user tapped accept" action
            // `V2Processor.acceptInvite` requires. `V2PairingDispatch.acceptInvite` itself removes the
            // cached entry once it succeeds.
            switch V2PairingDispatch.acceptInvite(accountKey: ownUserId, chatId: chat, inviteWire: inviteWire) {
            case let .sent(acceptWire):
                return .started(p1: acceptWire, completed: false, code: nil)
            case let .failed(reason):
                // SECUTG-HOOK (fix, 2026-09-27 真机): an invite that can never be accepted (cancelled, rejected,
                // expired) stops being offered, so the next tap starts a fresh pairing instead of failing the
                // same way forever. `busy` stays: the chat's slot is held by a live exchange that may still end.
                if reason != "busy" {
                    runtime.persisted.incomingInviteStore.remove(chat)
                    runtime.persisted.persist()
                }
                throw SecutgPairingError.acceptRefused(reason)
            case .notOnV2:
                throw SecutgPairingError.v2Unavailable
            }
        }
        // Initiate: refuse to manufacture a second INVITE for a chat v2 has already paired, or is mid-flight on.
        guard runtime.pairing.bindingStore.current(chat) == nil else { throw SecutgPairingError.alreadyPaired }
        guard runtime.pairing.currentTransactionForChat(chat) == nil else { throw SecutgPairingError.inFlight }
        // A private 1:1 chat's `chatId` IS the peer's own Telegram user id (`SecutgAccountRuntime.chatKey`).
        switch V2PairingDispatch.startPairing(accountKey: ownUserId, chatId: chat, targetUser: chat) {
        case let .sent(inviteWire):
            return .started(p1: inviteWire, completed: false, code: nil)
        case let .failed(reason):
            throw SecutgPairingError.inviteFailed(reason)
        case .notOnV2:
            throw SecutgPairingError.v2Unavailable
        }
    }

    /// SECUTG-HOOK (fix, 2026-09-27): an expired cached incoming invite can never be accepted
    /// (`acceptInvite` refuses it), and our own INVITE past its expires_ms can never be answered — both
    /// now read as "nothing" in `v2Status`, so the tap that reading offers (〔自动配对〕) must not trip over
    /// them: the first would fail the accept and fall through to nil, the second would keep
    /// `startPairingV2`'s "already mid-flight" guard refusing forever. Local effect only; the CANCEL
    /// `cancelPairing` builds is not sent (nobody can act on an expired invite).
    private func dropExpiredV2PairingState(_ runtime: V2Runtime, chat: String) {
        var changed = false
        if let cached = runtime.persisted.incomingInviteStore.get(chat), runtime.pairing.isInviteExpired(cached) {
            runtime.persisted.incomingInviteStore.remove(chat)
            changed = true
        }
        if let txnId = runtime.pairing.currentTransactionForChat(chat), runtime.pairing.isOwnInviteExpired(txnId) {
            _ = runtime.pairing.cancelPairing(txnId: txnId, reason: "expired")
            changed = true
        }
        if changed { runtime.persisted.persist() }
    }

    /// A refusal, carrying the wait rule 7 has left to run.
    ///
    /// The seconds are read here rather than carried out of the processor so the number the dialog quotes is as
    /// fresh as the moment it is shown, and floored at one: a second can tick over in between, and "retry in 0
    /// seconds" would be a worse answer than one second too many.
    private func refused(_ refusal: RekeyProcessor.PairingRefusal, chat: String) -> SecutgPairingStart {
        guard refusal == .tooSoon else { return .needsTakeover }
        let remaining = RekeyProcessor.takeoverSwallowedSeconds(ring.chatPairing(chat), nowSeconds: Int64(Date().timeIntervalSince1970))
        return .tooSoon(retryAfterSeconds: Int(max(1, remaining)))
    }

    /// PLAN.md 3.7 rule 12 (Web A `secutgRegenerateAndRepair`): the user suspects this device's keys leaked. The
    /// identity key pair is replaced with a brand-new one and a fresh P1 goes to this chat; the peer sees a key
    /// change and must confirm. Every other auto-paired chat on this device is left bound to the old identity and
    /// needs re-pairing too; old masters stay, so history still reads.
    ///
    /// The refusal (PLAN.md 3.25.6 rule 2) is checked **first**, before the old key pair is gone. Regenerating
    /// and then being refused would leave this device with a new identity, no pairing in this chat, and every
    /// other auto-paired chat on it bound to a key that no longer exists — worse than the takeover it declined,
    /// and unlike that takeover, with no way back. `confirmedTakeover` is deliberately not offered here: the
    /// dialog in front of this one warns about a new identity, not about what a takeover costs the other device.
    public func regenerateAndRepair(chatPeerId: PeerId) throws -> SecutgPairingStart {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        if let refusal = processor.takeoverRefusal(chatId: chat, confirmedTakeover: false) {
            return refused(refusal, chat: chat)
        }
        try ring.setIdentity(try Rekey.generateIdentity())
        return try startPairing(chatPeerId: chatPeerId)
    }

    public func safetyCode(chatPeerId: PeerId) -> String? {
        return safetyCode(chat: SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// Twelve digits both peers read out to each other; nil until the chat is paired on this device
    private func safetyCode(chat: String) -> String? {
        // SECUTG-HOOK (fix, 2026-09-27 真机): v2-first, like `status` — a leftover v1 record must not put its old
        // code under a v2 pairing. Only a real v1 "paired" chat (v2 having nothing for it) still has a v1 code.
        let v1 = ring.chatPairing(chat)
        guard resolvedPairing(chat: chat, v1: v1).source == .v1, let pairing = v1,
              let identity = ring.identity, let peerPk = ring.memberPk(chatId: chat, userId: pairing.peerId) else {
            return safetyCodeV2(chat: chat)
        }
        return try? Pairing.safetyCode(identity.x25519Pk, peerPk)
    }

    /// SECUTG-HOOK (PLAN.md UI-01): v2's own safety code, read only when v1 has none for this chat.
    /// `V2Processor.getSafetyCode` needs the completed transaction's txnId, which `V2Binding` itself
    /// carries (`bindingStore.current(chat)?.txnId`) — no extra by-chatId lookup needed beyond what
    /// `v2Status` already uses to detect "paired".
    ///
    /// Known, bounded gap for this round: `V2Processor.PairingProcessor`'s in-flight `pending` store
    /// (which is what actually holds the peer identity/wire `getSafetyCode` reads) is memory-only —
    /// `V2Runtime`'s own doc already accepts this for pairing bookkeeping in general — so a chat paired
    /// before this process's last restart returns nil here until that gap is closed.
    private func safetyCodeV2(chat: String) -> String? {
        // SECUTG-HOOK (fix, 2026-09-27): same rule as before (the CURRENT binding's own txnId; an
        // unpaired chat — DONE txn, no binding — has none), now read from the unit-tested
        // `V2PairingStatus` so the menu, the badge and this code can never disagree.
        return V2PairingStatus.of(accountKey: ownUserId, chatId: chat).safetyCode
    }

    /// Auto-paired chats: issue a fresh master as `R1:rotate` signed with this device's identity key and switch to it.
    public func rotatePairedKey(chatPeerId: PeerId) throws -> String {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK (fix): no v1 pairing record but a v2 binding exists — route to v2's own rekey
        // (`V2Roster.rekey`, a fresh random master resealed to every already-trusted device on the
        // binding, no old key needed) instead of falling straight to `throw RekeyError.notAdmin`
        // below, which is what every v2-only chat (now the default for every fresh pairing) did until
        // now: `isAutoPaired` reports `true` for a v2 chat too, so this function WAS being called, it
        // just always failed silently before reaching any real work.
        // SECUTG-HOOK (fix, 2026-09-27 真机): a v2 binding wins whatever v1 record exists (v2-first, like
        // `status`, which now shows such a chat as v2-paired). The `ring.chatPairing(chat) == nil` condition this
        // used to carry sent a chat with a leftover v1 record to the v1 road below, which refuses it.
        if let v2Runtime = V2RuntimeRegistry.shared.runtime(for: ownUserId),
           v2Runtime.pairing.bindingStore.current(chat) != nil {
            guard case .sent(let wire) = V2PairingDispatch.rekey(accountKey: ownUserId, chatId: chat) else { throw RekeyError.notAdmin }
            return wire
        }
        guard let pairing = ring.chatPairing(chat), pairing.state == .paired, let identity = ring.identity else { throw RekeyError.notAdmin }
        guard let currentId = ring.chatMasterId(chat), let current = ring.masterKey(for: currentId) else { throw RekeyError.noCurrentMaster }
        let fresh = KeyDerivation.generateMasterKey()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let built = try Rekey.buildRotate(newMaster: fresh, oldMaster: current, adminSk: identity.ed25519Sk, nowMs: nowMs, epochDays: crypto.epochDays)
        try adopt(fresh, chat: chat, keyId: built.newKeyId)
        return built.wire
    }

    /// Forward secrecy (PLAN.md 3.8): on sends `R1:ratchet` from a fresh base master, off sends a plain rotate.
    public func setForwardSecrecy(chatPeerId: PeerId, enabled: Bool) throws -> String {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK (fix, 2026-09-27 真机): v1-only. On a v2-bound chat an `R1:ratchet` would re-key a leftover v1
        // record the chat no longer encrypts with (the menu hides the entry there; this is the backstop).
        if V2RuntimeRegistry.shared.runtime(for: ownUserId)?.pairing.bindingStore.current(chat) != nil { throw RekeyError.notAdmin }
        guard let pairing = ring.chatPairing(chat), pairing.state == .paired, let identity = ring.identity else { throw RekeyError.notAdmin }
        guard let currentId = ring.chatMasterId(chat), let current = ring.masterKey(for: currentId) else { throw RekeyError.noCurrentMaster }
        let fresh = KeyDerivation.generateMasterKey()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let built = enabled
            ? try Rekey.buildRatchet(baseMaster: fresh, oldMaster: current, identityEdSk: identity.ed25519Sk, nowMs: nowMs, epochDays: crypto.epochDays)
            : try Rekey.buildRotate(newMaster: fresh, oldMaster: current, adminSk: identity.ed25519Sk, nowMs: nowMs, epochDays: crypto.epochDays)
        try adopt(fresh, chat: chat, keyId: built.newKeyId)
        if enabled, let label = KeyDerivation.parseKeyId(built.newKeyId)?.label, let id = ring.chatMasterId(chat) {
            try ring.setChatRatchet(chatId: chat, label: label, masterId: id)
        } else {
            ring.clearChatRatchet(chat)
        }
        return built.wire
    }

    /// Forgets the peer's keys and pairing so the next P1 from either side starts a fresh invitation, and hands
    /// back the `U1` notice telling the peer to destroy their copy of the key too (PLAN.md 3.31.3). Sending it is
    /// the caller's job: see `SecutgChatMenu.unpairAndNotify`, which every unpair path on this client goes through.
    ///
    /// The notice is built **before** the records are cleared, because it is addressed to the peer this chat
    /// *had* — afterwards there is nothing left to say who that was. Destroying is not conditional on it: with
    /// no identity to sign with this side still forgets everything and simply sends nothing. That asymmetry is
    /// the whole design. The security property is local — once this device's copy is gone it can read nothing
    /// and encrypts nothing — and the notice is hygiene on top of it, which is why a failure to build or deliver
    /// one is not allowed to hold up the destruction, and why nothing retries it.
    ///
    /// A chat with no pairing produces no notice: there is no peer it would be about, and "I have unpaired from
    /// you" sent into a chat that was never paired is noise the other side has no rule for.
    @discardableResult
    public func unpair(chatPeerId: PeerId) -> String? {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK (fix, 2026-09-27 真机): v2-first, like `status`. Unless the chat is a real v1-only "paired"
        // chat, unpairing is v2's: tear down the binding (fix A9), or cancel an exchange stuck in flight, or — the
        // 〔解除配对〕 entry is also offered for a bare cached invite — decline that invite locally. These used to
        // require `ring.chatPairing(chat) == nil`, so a leftover v1 record sent the tap down v1's road: a v1 U1
        // went out (the peer rendered it "换钥消息已忽略：no_peer_key") and the v2 binding stayed live. A leftover
        // v1 record is now cleared locally and silently — no U1 — so its key cannot keep encrypting (E1) the chat
        // the user just unpaired. A real v1 "paired" record is left alone (`dropResidualV1Pairing`).
        if resolvedPairing(chat: chat, v1: ring.chatPairing(chat)).source != .v1,
           let runtime = V2RuntimeRegistry.shared.runtime(for: ownUserId) {
            var wire: String?
            if runtime.pairing.bindingStore.current(chat) != nil {
                if case .sent(let unpairWire) = V2PairingDispatch.unpair(accountKey: ownUserId, chatId: chat) { wire = unpairWire }
            } else if runtime.pairing.currentTransactionForChat(chat) != nil {
                // SECUTG-HOOK (fix): a v2 transaction stuck in flight (INVITED/SELECTING/CONFIRMING, never reaching
                // DONE) — `V2PairingDispatch.unpair` only knows how to tear down an installed binding and would
                // no-op here, leaving `startPairingV2`'s own guard refusing every future attempt on this chat.
                if case .sent(let cancelWire) = V2PairingDispatch.cancelPairing(accountKey: ownUserId, chatId: chat, reason: "user_cancelled") { wire = cancelWire }
            } else if runtime.persisted.incomingInviteStore.get(chat) != nil {
                runtime.persisted.incomingInviteStore.remove(chat)
                runtime.persisted.persist()
            }
            dropResidualV1Pairing(chat: chat)
            forgetOpenedMessages()
            return wire
        }
        let notice = unpairNotice(chat: chat)
        processor.unpair(chatId: chat)
        // PLAN.md 3.19: the keys that opened this chat's sealed messages are gone, so what this session remembers
        // of them goes too — a reader must be told the message is locked, not shown a stale copy of it.
        forgetOpenedMessages()
        return notice
    }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): a leftover v1 pairing record (anything but "paired") is destroyed
    /// locally, with its key, and without a U1 — nobody is paired with it. A real v1 "paired" record is kept:
    /// with the v2 binding gone the chat falls back to it on both sides, the same way it read before v2.
    private func dropResidualV1Pairing(chat: String) {
        guard let leftover = ring.chatPairing(chat), leftover.state != .paired else { return }
        processor.unpair(chatId: chat)
    }

    /// SECUTG-HOOK (feature, 2026-09-27, "一键恢复"; split 2026-10-03, PLAN.md 3.50): the local clearing shared by
    /// `resetChat` (双方一起) and `resetChatLocally` (仅在本机) — a more thorough sibling of `unpair` for when a
    /// chat's encryption state is confused enough that diagnosing the exact combination of v1 residue, a
    /// stuck v2 transaction (in EITHER role — `unpair` above only ever finds ONE via
    /// `currentTransactionForChat`'s own `.first`, whichever it happens to return; this clears every open
    /// transaction the chat has, in both roles), a cached-but-unactioned invite, and/or an installed v2
    /// binding is not worth it — every one of them is cleared unconditionally, restoring the chat to the
    /// same clean state a never-configured chat starts in. Unlike `unpair` this is not gated on any of
    /// them being present: called on an already-clean chat, every branch below is a no-op.
    ///
    /// `notify` controls only whether the v2 wires this clearing produced are registered as sent
    /// (`V2PairingDispatch.noteSent`, PLAN.md 3.39.13, so their echoes would read as this device's own) —
    /// the local destruction above is identical either way. `resetChat` passes `true`: its notices are
    /// best-effort SENT by the caller (`SecutgChatMenu`), so marking them sent is correct. `resetChatLocally`
    /// passes `false`: PLAN.md 3.50's whole point is that nothing goes out on the wire, so nothing here may be
    /// marked as having been sent — a wire that were falsely marked sent could make this device ignore the
    /// peer's own, unrelated use of the identical transaction id later.
    private func clearChatState(chat: String, notify: Bool) -> [String] {
        var notices: [String] = []
        if let runtime = V2RuntimeRegistry.shared.runtime(for: ownUserId) {
            notices.append(contentsOf: runtime.pairing.cancelAllForChat(chat))
            // PLAN.md 3.39.7: a binding whose roster does not name this device is torn down with nothing to send
            // (`unpair` answers "").
            if runtime.pairing.bindingStore.current(chat) != nil, let wire = runtime.pairing.unpair(chat), !wire.isEmpty {
                notices.append(wire)
            }
            if notify {
                // PLAN.md 3.39.13: built here, so their echoes must read as this device's own, not its clone's.
                V2PairingDispatch.noteSent(accountKey: ownUserId, wires: notices)
            }
            runtime.persisted.incomingInviteStore.remove(chat)
            runtime.persisted.persist()
        }
        if let notice = unpairNotice(chat: chat) {
            notices.append(notice)
        }
        processor.unpair(chatId: chat)
        forgetOpenedMessages()
        return notices
    }

    /// Every notice returned is best-effort to send — local state is already correct by the time each is
    /// built, so a peer who never receives any of them leaves this device no less correct. See
    /// `clearChatState` for what is actually cleared; this is that plus `notify: true`.
    public func resetChat(chatPeerId: PeerId) -> [String] {
        return clearChatState(chat: SecutgAccountRuntime.chatKey(chatPeerId), notify: true)
    }

    /// PLAN.md 3.50 「仅在本机重置本聊天的加密」: the exact same local clearing as `resetChat`, but nothing is
    /// sent and nothing is returned to send — the caller (`SecutgChatMenu`) puts no message on the wire at
    /// all, unlike `resetChat`'s best-effort notices. The peer is left believing whatever it believed before;
    /// this device simply forgets.
    public func resetChatLocally(chatPeerId: PeerId) {
        _ = clearChatState(chat: SecutgAccountRuntime.chatKey(chatPeerId), notify: false)
    }

    /// The `U1` for the pairing this chat holds *right now*, or nil when there is nothing to say. Called from
    /// `unpair` alone, and only on the line before the records it reads are destroyed.
    ///
    /// `at` is unix seconds now — not zero, not a stored timestamp. The receiver refuses a notice dated before
    /// its own `pairedAt` (3.31.3 rule 5), so a zero would be thrown away by the very side it was written for.
    ///
    /// `try?` rather than a rethrow: signing can only fail locally, and rule 2 says the destruction happens
    /// either way. A caller that had to handle an error here could be tempted not to destroy.
    private func unpairNotice(chat: String) -> String? {
        guard ring.chatPairing(chat) != nil, let identity = ring.identity else { return nil }
        return try? Rekey.buildU1(userId: ownUserId, at: Int64(Date().timeIntervalSince1970), ed25519Sk: identity.ed25519Sk)
    }

    @discardableResult
    public func setPairingVerified(chatPeerId: PeerId, verified: Bool) -> Bool {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // SECUTG-HOOK (fix, 2026-09-27 真机): only when the v1 record is what `status` shows. The flag the status
        // shows is v2's whenever v2 has state; writing a leftover v1 record's flag instead would be invisible.
        guard let pairing = ring.chatPairing(chat), pairing.state == .paired,
              resolvedPairing(chat: chat, v1: pairing).source == .v1 else { return false }
        return (try? ring.setChatPairing(chatId: chat, pairing.with(verified: verified))) != nil
    }

    /// Human-readable line for a control message's `detail` (rendered by the bubble hook B2), in the current Telegram language via `SecutgL10n`.
    ///
    /// `accountPeerId` / `chatPeerId` are needed by two branches — the paired line, which names the two devices
    /// from the live keyring (PLAN.md 3.25.5), and the three "your other device has it" lines, which name the
    /// one that has it (PLAN.md 3.7 rule 8). Everything else stays a pure function of `detail`, and a caller
    /// that cannot supply them still gets the line, just without the device tail.
    public static func controlSummary(detail: String?, accountPeerId: PeerId? = nil, chatPeerId: PeerId? = nil,
                                      senderName: String? = nil) -> String {
        let parts = (detail ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first, !kind.isEmpty else { return "Si4Gram" } // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        // PLAN.md 3.34.3: the group's key was retired. Answered first, for the same reason `unpair` is: an `N1`
        // is neither a rekey nor a pairing, and left to fall through it would land on the `peer-key` default
        // and render as a pairing line. The member is about to find they cannot send, and this line is the only
        // thing that explains why.
        //
        // `retire:<ok|own_echo|reason>:<mode|->:<uid|->`. `pending` renders nothing at all: the member list has
        // not loaded, so the only reason this line could give is one that stops being true in a moment — and a
        // line the reader cannot act on, about a state they cannot see, is worse than silence.
        if kind == "retire" {
            let outcome = parts.count > 1 ? parts[1] : "error"
            let mode = parts.count > 2 ? parts[2] : "-"
            let name = displayName(senderName, fallbackUserId: parts.count > 3 ? parts[3] : "-")
            if outcome == "pending" { return "" }
            // This device's own notice coming back. It did everything when it sent it, and "{name} rebuilt this
            // group's key" on the user's own outgoing message would be plainly wrong — and it is the line they
            // would see every single time they rebuild, because the echo always arrives.
            if outcome == "own_echo" { return SecutgL10n.string("SecutgRetiredByYou") }
            // `already_applied` is this device reading a notice it has already obeyed — a history page scrolled
            // back over, a cold start re-deriving its lines. It is an outcome, not a refusal, and it says the
            // same thing the first reading said: this key was retired, by this person.
            guard outcome == "ok" || outcome == "already_applied" else {
                return SecutgL10n.string("SecutgRekeyRejected", ["reason": outcome])
            }
            let line = SecutgL10n.string("SecutgRetiredByAdmin", ["name": name])
            // What happens next is the key's mode, and the two answers are opposite instructions: wait, or go
            // and find somebody. Saying neither leaves the reader with a chat that has stopped working — and
            // saying either one after the replacement is in is stale advice on a line they keep scrolling past,
            // so the half that has to happen is only shown while it still has to.
            guard !holdsKey(accountPeerId: accountPeerId, chatPeerId: chatPeerId) else { return line }
            return line + " " + (mode == Rekey.KeyMode.auto.rawValue
                ? SecutgL10n.string("SecutgRetiredWaitAuto")
                : SecutgL10n.string("SecutgRetiredScanNeeded", ["name": name]))
        }
        /*
         PLAN.md 3.35.4: the group's key arrived in the clear. **Every verdict renders a line** — that is the
         rule, not a preference, and it is why this branch has no path that returns "".

         `park` is the one that matters most, and it is the one the `retire` branch above deliberately draws
         nothing for. The difference is what the two are waiting on: a parked `N1` is a notice the member will
         hear about again, while a parked `G2` IS the key, and in auto mode there is no other road to it.
         "Nothing on screen" is exactly what 3.35.1 says four batches of fixes kept producing.
         */
        // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): the group-password policy. Applied, own and stale
        // copies all say what the policy was (a stale one is an older, true event in the history); parked and refused
        // ones have their own password lines (SecutgGroupPwConfirming / SecutgGroupPwNotAdmin), not the group-key ones.
        if kind == "groupPw" {
            let verdict = parts.count > 1 ? parts[1] : "error"
            let name = displayName(senderName, fallbackUserId: parts.count > 2 ? parts[2] : "-")
            let state = parts.count > 3 ? parts[3] : "-"
            switch verdict {
            case G2.Verdict.apply.rawValue, G2.Verdict.own.rawValue, G2.Verdict.stale.rawValue:
                return SecutgL10n.string(state == "off" ? "SecutgGroupPwDisabledLine" : "SecutgGroupPwAdopted")
            case G2.Verdict.park.rawValue: return SecutgL10n.string("SecutgGroupPwConfirming")
            case G2.Verdict.refuseNotAdmin.rawValue: return SecutgL10n.string("SecutgGroupPwNotAdmin", ["name": name])
            default: return SecutgL10n.string("SecutgRekeyRejected", ["reason": verdict])
            }
        }
        if kind == "groupKey" {
            let verdict = parts.count > 1 ? parts[1] : "error"
            let name = displayName(senderName, fallbackUserId: parts.count > 2 ? parts[2] : "-")
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): the locked kind and the "turned off" kind
            // have their own lines; every other verdict reads as before.
            let pwKind = parts.count > 3 ? parts[3] : ""
            if verdict == G2.Verdict.apply.rawValue && pwKind == "pw" { return SecutgL10n.string("SecutgGroupPwAdopted") }
            if verdict == G2.Verdict.apply.rawValue && pwKind == "pw_off" {
                return SecutgL10n.string("SecutgGroupKeyApplied", ["name": name]) + "\n" + SecutgL10n.string("SecutgGroupPwDisabledLine")
            }
            switch verdict {
            case G2.Verdict.apply.rawValue: return SecutgL10n.string("SecutgGroupKeyApplied", ["name": name])
            case G2.Verdict.own.rawValue: return SecutgL10n.string("SecutgGroupKeyByYou")
            case G2.Verdict.park.rawValue: return SecutgL10n.string("SecutgGroupKeyConfirming")
            case G2.Verdict.refuseNotAdmin.rawValue: return SecutgL10n.string("SecutgGroupKeyNotAdmin", ["name": name])
            case G2.Verdict.refuseNotAuto.rawValue: return SecutgL10n.string("SecutgGroupKeyNotAuto")
            case G2.Verdict.stale.rawValue: return SecutgL10n.string("SecutgGroupKeyStale")
            // No verdict at all means it never got as far as being judged: malformed, for another chat, or a
            // sender who is not who the wire names. Refused, and said so.
            default: return SecutgL10n.string("SecutgRekeyRejected", ["reason": verdict])
            }
        }
        // PLAN.md 3.31.3: the peer unpaired and this side destroyed its copy of the key. Answered before the
        // rekey / pairing split below, because a `U1` is neither of those — left to fall through it would land
        // on the `peer-key` default and render as a pairing line, the opposite of what happened. A refused
        // notice (forged signature, not this chat's peer, a replay dated before the current pairing) is shown
        // as a rejection rather than silently: a message that tried to destroy keys and was turned away is
        // worth seeing.
        if kind == "unpair" {
            let outcome = parts.count > 1 ? parts[1] : "error"
            // "own_echo" is this device's own notice coming back after it had already unpaired. Saying "the
            // other side unpaired this chat" on the user's own outgoing message would be plainly wrong, and it
            // is the line they would see every single time they unpair — the echo always arrives.
            // `SecutgUnpaired` is the wording the local unpair toast already uses, so the two say the same
            // thing rather than nearly the same.
            if outcome == "own_echo" { return SecutgL10n.string("SecutgUnpaired") }
            // SECUTG-HOOK (fix, 2026-09-27 真机): a notice this side had nothing to unpair for (no pairing with that
            // peer, or a leftover v1 record that never learned their key) changed nothing and threatened nothing —
            // `SecutgV2Ignored`, not "换钥消息已忽略：no_peer_key". Genuine refusals keep the line below.
            if RekeyProcessor.isNothingToUnpair(outcome) { return SecutgL10n.string("SecutgV2Ignored") }
            return outcome == "ok"
                ? SecutgL10n.string("SecutgUnpairedByPeer")
                : SecutgL10n.string("SecutgRekeyRejected", ["reason": outcome])
        }
        // SECUTG-HOOK (fix, 2026-09-27 真机): a v2 pairing step (`V2PairingLine`, written by `handleP2`). Every value
        // renders a line — this kind exists so that no P2 bubble is ever empty or shows a raw reason code.
        if kind == V2PairingLine.detailKind {
            guard let line = V2PairingLine(rawValue: parts.count > 1 ? parts[1] : "") else { return SecutgL10n.string("SecutgV2Ignored") }
            switch line {
            case .inviteSent: return SecutgL10n.string("SecutgPairInviteSent")
            case .handshake: return SecutgL10n.string("SecutgV2Handshake")
            case .readySent: return SecutgL10n.string("SecutgV2ReadySent")
            case .cancelled: return SecutgL10n.string("SecutgV2Cancelled")
            case .peerBusy: return SecutgL10n.string("SecutgV2PeerBusy")
            case .ignored: return SecutgL10n.string("SecutgV2Ignored")
            case .unpairedByYou: return SecutgL10n.string("SecutgUnpaired")
            case .rotatedByYou: return SecutgL10n.string("SecutgRotatedByYou")
            // SECUTG-HOOK (fix, 2026-10-01 真机): another device of this account accepted the invite this one was offered
            case .siblingAccepted: return SecutgL10n.string("SecutgV2SiblingAccepted")
            }
        }
        // SECUTG-HOOK (feature, 2026-09-29, PLAN.md 3.39.3–3.39.5): a device joining a 1v1 chat by QR, `v2join:<what>`
        // written by `handleP2`. `done` carries the safety code the QR brought; `sibling`/`peer` carry the joined
        // device's code (3.25.2's `XXX-XXX`); the peer line names the message's author, the account that added it.
        // SECUTG-HOOK (feature, 2026-10-01, PLAN.md 3.39.13): this device's V2Q clone binding was set aside because
        // another device of the account paired the chat again — `v2clone:sibling_repaired`, written by `handleP2`.
        if kind == "v2clone" {
            return SecutgL10n.string("SecutgV2CloneSiblingRepaired")
        }
        if kind == "v2join" {
            let what = parts.count > 1 ? parts[1] : ""
            switch what {
            case "done": return SecutgL10n.string("SecutgV2JoinDone", ["code": parts.count > 2 ? parts[2] : ""])
            case "sibling": return SecutgL10n.string("SecutgV2JoinSiblingAdded", ["code": parts.count > 2 ? parts[2] : ""])
            case "peer": return SecutgL10n.string("SecutgV2JoinPeerAdded", ["name": senderName ?? (parts.count > 2 ? parts[2] : ""), "code": parts.count > 3 ? parts[3] : ""])
            case "expired_rekeyed": return SecutgL10n.string("SecutgV2JoinExpiredRekeyed")
            default: return SecutgL10n.string("SecutgV2Ignored")
            }
        }
        if kind == "v2rekey" {
            // SECUTG-HOOK (fix): v2's own "换新密钥" (V2Roster rekey) — a distinct kind from `rekey`
            // below (v1's R1 rotate/welcome), not a sub-case of it, since v2's binding model has no
            // equivalent of the device-switch fields that case's parser expects.
            let outcome = parts.count > 1 ? parts[1] : "error"
            // SECUTG-HOOK (fix, 2026-09-27 真机): this device's own echo used to render as "" — an EMPTY bubble. It
            // says what happened now, the same line Android shows and v1's own R1 echo already has.
            if outcome == "own_echo" { return SecutgL10n.string("SecutgRotatedByYou") }
            return SecutgL10n.string("SecutgPairKeyChanged")
        }
        if kind == "rekey" {
            // PLAN.md 3.32 review, batch 1: which sentence is `RekeyLine`'s call, shared with the other four
            // clients. `ok` and the type come off the stored detail; the reason is the third segment on a
            // refusal and the optional fourth on an applied message (`already_known`, the welcome an existing
            // holder sees). `hasKey` is asked of the live keyring, the way `pairedDeviceCodes` asks it — it is
            // what parts "the admin left you out" from "you were never given a key", and it is not a fact the
            // message carries. `SecutgRekeyRejected` is the one key that still takes the raw reason.
            let type = parts.count > 1 ? parts[1] : "rotate"
            let outcome = parts.count > 2 ? parts[2] : "error"
            let ok = outcome == "ok"
            let reason: String? = ok ? (parts.count > 3 ? parts[3] : nil) : outcome
            // PLAN.md 3.34.7 item 4: nil is a row whose verdict was `pending` — the welcome overtook the notice
            // that would make its signing key trusted, and it will be judged again the moment that lands. Like
            // the parked notice above it draws nothing: the only reason it could give stops being true in a
            // moment, and a line the reader cannot act on is worse than silence.
            guard let key = RekeyLine.key(ok: ok, type: Rekey.R1Type(rawValue: type), reason: reason, hasKey: holdsKey(accountPeerId: accountPeerId, chatPeerId: chatPeerId)) else { return "" }
            return key == "SecutgRekeyRejected"
                ? SecutgL10n.string(key, ["reason": outcome])
                : SecutgL10n.string(key)
        }
        let outcome = parts.count > 2 ? parts[2] : "error"
        let pairing = parts.count > 3 ? parts[3] : ""
        // `peer-key:<uid>:ok:paired:<safety code>[:takeover:<device_id>:<label>]` — appended at transform time
        let code = parts.count > 4 ? parts[4] : ""
        switch pairing {
        case "incoming": return SecutgL10n.string("SecutgPairInviteHint")
        case "paired", "self_paired":
            guard !code.isEmpty else { return SecutgL10n.string("SecutgPairPairedAuto") }
            // PLAN.md 3.25.6 rule 5: a takeover of this account's own earlier pairing, not a first-time one —
            // parts[6] is the winning device's id, parts[7] this device's own (possibly absent) label for it.
            let line: String
            if parts.count > 7, parts[5] == "takeover" {
                let device = deviceDetailText(deviceId: parts[6], encodedLabel: parts[7])
                line = SecutgL10n.string("SecutgPairTransferredLine", ["device": device, "code": code])
            } else {
                line = SecutgL10n.string("SecutgPairDoneLine", ["code": code])
            }
            // Both flavours of the paired line get the device codes: a takeover is still a pairing this reader
            // now has, and is in fact the case where "which two devices is this?" is hardest to answer.
            guard let devices = pairedDeviceCodes(accountPeerId: accountPeerId, chatPeerId: chatPeerId) else { return line }
            return line + " " + devices
        case "self_invited": return SecutgL10n.string("SecutgPairInviteSent")
        case "already_paired": return SecutgL10n.string("SecutgPairAlready")
        // PLAN.md 3.43: a v2 INVITE from an identity the chat's binding does not know. Two of v1's three sentences — ①
        // the key changed, ③ which two devices and the admission that this app cannot tell a new phone from an
        // impostor — then 3.43's own line: check through another channel that it really is them. Deliberately NOT ②
        // (`SecutgPairKeyChangedCode`): before this side accepts, the peer holds no key of ours and cannot compute a
        // code to compare against, so a number here would be one nobody can check. The device codes are baked in the
        // detail at dispatch time (`peer-key:<uid>:ok:invite_key_changed:<old>:<new>`): unlike v1's `key_changed`
        // nothing was adopted, so there is no live state to read them from. The 〔同意配对〕 that acts on it is the row's.
        case "invite_key_changed":
            let keyChanged = SecutgL10n.string("SecutgPairKeyChanged")
            let oldDevice = parts.count > 4 ? parts[4] : "-"
            let newDevice = parts.count > 5 ? parts[5] : "-"
            let detail = (oldDevice != "-" || newDevice != "-")
                ? " " + SecutgL10n.string("SecutgPairKeyChangedDetail", ["oldDevice": oldDevice, "newDevice": newDevice])
                : ""
            return keyChanged + detail + "\n" + SecutgL10n.string("SecutgV2KeyChangedHint")
        case "key_changed":
            // PLAN.md 3.7 rule 5 + 3.25.5 item 4 + 3.25.11. Three segments, side by side, always in this order:
            //   ① `SecutgPairKeyChanged` — "🔑 对方换了新密钥，本对话已自动用新密钥重新配对。请重新核对安全码。"
            //   ② `SecutgPairKeyChangedCode` — the NEW safety code, when this device can compute one
            //   ③ `SecutgPairKeyChangedDetail` — which two devices, plus the honest admission that this app
            //      cannot tell "they switched devices" from "the same device generated a new key"
            //
            // ① is never dropped. It is the sentence that says the key changed at all, and ③ does not
            // contain it: ③ names two device codes and admits this app cannot tell a new device from the same
            // device's regenerated key, but it never says that anything changed. Returning ③ *instead of* ①
            // — which is what this branch did until 3.25.5 item 4, whenever both device ids happened to be
            // known — deleted the warning in precisely the case where the most is known about the change, and
            // left the calmest-sounding half of the message standing alone.
            //
            // ② and ③ are tails, not replacements. Web (`src/secutg/ui/SecutgControlLine.tsx`) renders ①, then
            // the code when it has one, then the detail when it has one; Android (`SecutgHooks.controlSummary`,
            // the `key_changed` case) concatenates the same three with spaces. This is that same shape.
            //
            // Wire format: `peer-key:<uid>:ok:key_changed:<new_id>:<new_label>:<old_id>:<old_label>`. A stored
            // message older than those fields, and a device that never recorded the peer's previous device id,
            // both fall back to ① on its own — which is the half that has to survive anyway.
            let keyChanged = SecutgL10n.string("SecutgPairKeyChanged")
            // PLAN.md 3.25.11: the key is already adopted by the time this renders, so the one thing left for
            // the reader to do is compare the NEW safety code. It sits between ① and ③, the order Web
            // (`src/secutg/ui/SecutgControlLine.tsx`) and Android (`SecutgHooks.controlSummary`, the
            // `key_changed` case) both put it in. Read from the live keyring rather than from the wire, the
            // same route `pairedDeviceCodes` takes and for the same two reasons: a row stored before this
            // change carries no such field, and the code worth comparing is the one in force now.
            let code = liveSafetyCode(accountPeerId: accountPeerId, chatPeerId: chatPeerId)
            let head = code.map { keyChanged + " " + SecutgL10n.string("SecutgPairKeyChangedCode", ["code": $0]) } ?? keyChanged
            guard parts.count > 7, parts[4] != "-" || parts[6] != "-" else { return head }
            let newDevice = deviceDetailText(deviceId: parts[4], encodedLabel: parts[5])
            let oldDevice = deviceDetailText(deviceId: parts[6], encodedLabel: parts[7])
            return head + " " + SecutgL10n.string("SecutgPairKeyChangedDetail", ["oldDevice": oldDevice, "newDevice": newDevice])
        // PLAN.md 3.34.6 guardrail. The sentence says "nothing was changed" and what that costs in the same
        // breath: until the reader accepts it, that person gets no copy of the group key. Without the second
        // half "nothing happened" looks like nothing happening, and nobody knows a decision is owed.
        case "group_key_changed":
            let name = displayName(senderName, fallbackUserId: parts.count > 1 ? parts[1] : "-")
            return SecutgL10n.string("SecutgGroupKeyChangedLine", ["name": name])
        case "duplicate": return SecutgL10n.string("SecutgPairDuplicate")
        // SECUTG-HOOK (PLAN.md UI-01): an intermediate v2 handshake step (ACCEPT/SELECT/CONFIRM being
        // relayed onward) — the same "nothing to say yet" rule the `retire`/`groupKey` branches above
        // already use for their own `pending` outcome: the only reason this line could give stops
        // being true in a moment, and a line the reader cannot act on is worse than silence.
        // SECUTG-HOOK (fix, 2026-09-27 真机): rows stored before `v2line:` existed still carry this detail; they read
        // as a pairing in progress rather than as an empty bubble.
        case "v2_progress": return SecutgL10n.string("SecutgV2Handshake")
        // PLAN.md 3.7 rule 8: all three of these say "你的另一台设备" and stop there. The one question the person
        // standing at *this* device actually has — "then which of my machines can encrypt here?" — was left to a
        // two-level-deep 更多…→状态, or to the handoff notice that a single tap on〔知道了〕removes for good.
        case "other_device", "pairing_lost", "pairing_moved":
            let key = pairing == "pairing_lost" ? "SecutgPairLostBody"
                : (pairing == "pairing_moved" ? "SecutgPairMovedLine" : "SecutgPairOtherDeviceLine")
            let line = SecutgL10n.string(key)
            guard let holder = holdingDeviceLine(accountPeerId: accountPeerId, chatPeerId: chatPeerId) else { return line }
            return line + " " + holder
        default: return outcome == "ok"
            ? SecutgL10n.string("SecutgPeerKeyRegistered")
            : SecutgL10n.string("SecutgPeerKeyRejected", ["reason": outcome])
        }
    }

    /// The name a sentence calls somebody by: what the caller resolved from the message's author, or the bare
    /// user id when it could not. A user id is a poor name and a far better one than an empty gap in the middle
    /// of a sentence that is telling the reader who to go and find.
    private static func displayName(_ senderName: String?, fallbackUserId: String) -> String {
        if let senderName = senderName, !senderName.isEmpty { return senderName }
        return fallbackUserId == "-" ? SecutgL10n.string("SecutgRoleMember") : fallbackUserId
    }

    /// PLAN.md 3.25.5: name both devices right under the safety code, reusing the exact fragment the pair-done
    /// dialog already shows. It belongs *here* and not in the `E1` confirmation text ("🔒 加密已开启") because that
    /// one is a real sent message: both ends read the same characters, so a "本机 / 对方" baked into it would be
    /// backwards for whoever receives it. This line is rendered locally on each side, so the two roles are always
    /// right for the person reading them — and `SecutgSafetyDeviceCodes` already says "本机：" itself, so the own
    /// device takes the plain display text, never an extra `SecutgSelfDevice` prefix.
    ///
    /// Unlike the rest of `controlSummary` this asks the live keyring, the way the group-invite card asks
    /// `hasMaster`: the labels are local and editable, so baking them into the stored `detail` would leave a
    /// renamed device wearing its old name forever. Both ids or neither — half a line names one device and
    /// leaves the reader guessing what happened to the other.
    /// The chat's **current** safety code, asked of the live keyring at render time — the same route
    /// `pairedDeviceCodes` takes. The `key_changed` line needs it (PLAN.md 3.25.11) and the stored `detail`
    /// cannot supply it: rows written before that change carry no such field, and the code worth comparing is
    /// the one in force now rather than whatever was in force when the row was first drawn.
    private static func liveSafetyCode(accountPeerId: PeerId?, chatPeerId: PeerId?) -> String? {
        guard let accountPeerId, let chatPeerId,
              let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else { return nil }
        return runtime.safetyCode(chatPeerId: chatPeerId)
    }

    private static func pairedDeviceCodes(accountPeerId: PeerId?, chatPeerId: PeerId?) -> String? {
        guard let accountPeerId, let chatPeerId,
              let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId),
              let own = runtime.ownDeviceIdentity(),
              let peerDeviceId = runtime.status(chatPeerId: chatPeerId).peerDeviceId else { return nil }
        return SecutgL10n.string("SecutgSafetyDeviceCodes", [
            "own": runtime.deviceDisplayText(own.deviceId), "peer": runtime.deviceDisplayText(peerDeviceId),
        ])
    }

    /// Whether this device holds a key for the chat, asked of the live keyring at render time (PLAN.md 3.32
    /// review, batch 1) — the same route `pairedDeviceCodes` takes, for the same reason: the message cannot
    /// carry it. Read live, a `not_addressed` line flips from "not in yet" to "left out" once the person
    /// imports a key, which is Web's behaviour too (`SecutgControlLine.tsx` reads `status.chatMasters`).
    /// False without the ids: no caller omits them today, and "no key yet" is the milder of the two lines.
    private static func holdsKey(accountPeerId: PeerId?, chatPeerId: PeerId?) -> Bool {
        guard let accountPeerId, let chatPeerId,
              let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else { return false }
        return runtime.status(chatPeerId: chatPeerId).hasKey
    }

    /// PLAN.md 3.7 rule 8: the "持有配对的设备：…" tail for every surface that otherwise only says "你的另一台
    /// 设备" and stops — the three control lines above and the onboarding card's `moved` form.
    ///
    /// The device named here is the pairing record's `ownDeviceId`, i.e. **whichever of this account's devices
    /// holds the pairing** — deliberately the opposite of `pairedDeviceCodes`, which names `ownDeviceIdentity()`.
    /// On these surfaces this device is by definition *not* the holder, so naming this device would answer a
    /// question nobody asked. All three outcomes — lost the accept race, moved away, never took part — write the
    /// same pairing record with the winner in that field, so the answer is already sitting in the local keyring.
    ///
    /// Asked of the live keyring rather than of the stored `detail`, for `pairedDeviceCodes`' reason: the label
    /// is local and editable, and baking it into a stored message would leave a renamed device wearing its old
    /// name forever. `nil` when this device never saw the winning `P1` go by — nothing about pairings is kept
    /// server-side and the protocol has no device-to-device message, so there is no way to ask — and then the
    /// caller drops the tail rather than print "持有配对的设备：" with nothing after it.
    public static func holdingDeviceLine(accountPeerId: PeerId?, chatPeerId: PeerId?) -> String? {
        guard let accountPeerId, let chatPeerId,
              let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId),
              let holderDeviceId = runtime.status(chatPeerId: chatPeerId).ownDeviceId else { return nil }
        return SecutgL10n.string("SecutgStatusOwnDevice", ["device": runtime.deviceDisplayText(holderDeviceId)])
    }

    /// PLAN.md 3.25.5: "{label} · {code}" when this device (whoever is rendering) has a local label for
    /// `deviceId`, else "{code}（未备注）" — `encodedLabel` is whatever `encodeDetailLabel` baked into `detail`.
    private static func deviceDetailText(deviceId: String, encodedLabel: String) -> String {
        let code = DeviceIdentity.deviceCode(forId: deviceId) ?? deviceId
        if let label = decodeDetailLabel(encodedLabel) {
            return SecutgL10n.string("SecutgDeviceLabeled", ["label": label, "code": code])
        }
        return SecutgL10n.string("SecutgDeviceUnlabeled", ["code": code])
    }

    /// Every chat this device holds a key for, as peers. A transferred keyring can carry a key for any of them, so
    /// this is the sweep the re-decrypt pass takes after an import (PLAN.md 3.17).
    public func keyedChatPeerIds() -> [PeerId] {
        return ring.listKeyedChatIds().compactMap(SecutgAccountRuntime.peerId(chatKey:))
    }

    /// Enabling requires a key (Web A stage 6 review rule).
    @discardableResult
    public func setChatEncryption(chatPeerId: PeerId, enabled: Bool) -> Bool {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        if enabled && ring.chatMasterId(chat) == nil && ring.groupPasswordRecord(chat)?.active != true { return false } // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1)
        ring.setChatEncryption(chatId: chat, enabled: enabled)
        return true
    }

    /// Admin: fresh master + per-chat signing key; returns the QR payload for other members.
    ///
    /// PLAN.md 3.34.1: `mode` is a property of the key, not of this device. It is written into the ring and into
    /// the payload here, once, so every member reads the same answer and a later retire notice can repeat it.
    /// `manual` is the default because it is the half that cannot go wrong quietly: it asks a person.
    public func createMaster(chatPeerId: PeerId, mode: Rekey.KeyMode = .manual) throws -> String {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let master = KeyDerivation.generateMasterKey()
        let signing = try Rekey.generateSigningKeys()
        let masterId = try ring.addMaster(master)
        try ring.setChatAdminPk(chatId: chat, signing.pk)
        try ring.setChatAdminSk(chatId: chat, signing.sk)
        try ring.setChatMaster(chatId: chat, masterId: masterId, label: KeyDerivation.toEpochLabel(nowMs: Int64(Date().timeIntervalSince1970 * 1000), epochDays: crypto.epochDays))
        ring.setChatEncryption(chatId: chat, enabled: true)
        try ring.setChatKeySource(chatId: chat, .offline)   // PLAN.md 3.13 rule 3
        // Strictly after `setChatMaster`, which clears the chat's provenance and would take the mode with it
        ring.setChatKeyMode(chatId: chat, mode)
        noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: a key made here (group, Saved Messages) arms the flag
        return KeyPayload.build(masterKey: master, adminPk: signing.pk, mode: mode)
    }

    /// PLAN.md 3.34: 「重建群密钥」 — the one group action there is, and the one road into a group's first key.
    ///
    /// Three things have to happen in this order, on this device, with nothing in between, which is why they
    /// are one method and not three calls from the menu:
    ///
    /// 1. Read what the group currently trusts. `createMaster` overwrites the chat's admin key pair, so once it
    ///    has run the old public key is gone from this device and the notice can no longer name it — and naming
    ///    it is the whole of the replay guard (3.34.3 rule 3).
    /// 2. Make the new key, in the mode the admin chose. The mode is a property of the key: it goes into the QR
    ///    payload and into the notice, so nobody has to be told it separately (3.34.1).
    /// 3. Sign the notice with **this account's identity key**, never the new admin key — at the moment a member
    ///    reads this, that key is exactly what they have no reason to trust yet.
    ///
    /// A group's FIRST key comes through here too, with no old public key to name. The notice is the same one;
    /// only the "old" half is empty, and the receiving side's replay check reads that as "applies only where
    /// nothing is trusted yet".
    ///
    /// The caller sends `notice` **before** anything else: it is what retires the copy every member holds, and a
    /// welcome that overtakes it would be applied and then thrown away by the notice that followed it.
    /// PLAN.md 3.35.6: `broadcast` is the `G2` carrying the key itself, in AUTO mode only. nil in manual
    /// mode by design — 当面配对 never puts a key on the wire, and that is the whole of the difference.
    public func recreateGroupKey(chatPeerId: PeerId, mode: Rekey.KeyMode) throws
    -> (notice: String, payload: String, broadcast: String?) {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        guard chat.hasPrefix("-") else { throw RekeyError.notAdmin }
        let oldAdminPk = ring.chatAdminPk(chat)
        let identity: KeyRing.Identity
        if let existing = ring.identity {
            identity = existing
        } else {
            identity = try Rekey.generateIdentity()
            try ring.setIdentity(identity)
        }
        let payload = try createMaster(chatPeerId: chatPeerId, mode: mode)
        // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a plain key replaces any locked one.
        ring.supersedeGroupPassword(chat)
        guard let newAdminPk = ring.chatAdminPk(chat) else { throw RekeyError.notAdmin }
        let at = Int64(Date().timeIntervalSince1970)
        let notice = try Rekey.buildN1(
            chatId: chat, userId: ownUserId, at: at, mode: mode,
            oldAdminPk: oldAdminPk, newAdminPk: newAdminPk, ed25519Sk: identity.ed25519Sk)
        // Rule 3's anchor on the admin's own device (PLAN.md 3.34.3, 2026-09-19): a co-holder's notice from
        // BEFORE this rebuild, arriving afterwards, must not undo it. This device's own notice comes back as an
        // echo and does nothing, so the anchor has to be written here rather than by the receive hook.
        ring.setChatNoticeAt(chatId: chat, at)
        // PLAN.md 3.35: in auto mode the key itself goes into the group, wrapped under the shared passphrase
        // (read `G2Obfuscation` before reading anything into that word). It carries the SAME `at` as the
        // notice, which is why an auto-mode notice must not write the anchor on the RECEIVING side: it would
        // make this broadcast stale on arrival (3.35.5.1 / 3.35.5.2).
        let broadcast = mode == .auto
            ? G2.build(chatId: chat, at: at, keyPayload: payload, publisherId: ownUserId)
            : nil
        return (notice, payload, broadcast)
    }

    /// PLAN.md 3.34.1: how this group's current key reaches members. `manual` wherever it is not known.
    public func chatKeyMode(chatPeerId: PeerId) -> Rekey.KeyMode {
        return ring.chatKeyMode(SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// PLAN.md 3.34.4 / 3.34.6: the key-holding device's side of an auto-mode group — one `R1 welcome` per
    /// member who is both still in the group and has a public key on file.
    ///
    /// `welcome` is single-recipient by wire (it seals straight to one X25519 key, with no addressing table),
    /// so this returns one message per person rather than one message for everybody. That is not an accident of
    /// the implementation: each recipient's copy is sealed to them and to nobody else, and a member who joins
    /// later gets the same single message through the same path with no special case.
    ///
    /// `memberIds` has to come from the caller because this layer cannot see Telegram's member list. Whoever
    /// calls this is responsible for passing the CURRENT one — `AutoPairing.welcomeRecipients` says why that
    /// list is the whole security model of auto mode.
    public func buildAutoWelcomes(chatPeerId: PeerId, memberIds: [String]) -> [(userId: String, wire: String)] {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let recipients = AutoPairing.welcomeRecipients(AutoPairing.WelcomeInput(
            mode: ring.chatKeyMode(chat),
            isGroup: chat.hasPrefix("-"),
            holdsAdminKey: ring.chatAdminSk(chat) != nil,
            hasKey: ring.chatMasterId(chat) != nil,
            ownUserId: ownUserId,
            memberIds: memberIds,
            registeredIds: ring.listMemberIds(chatId: chat)))
        return recipients.compactMap { userId in
            guard let wire = try? buildRekey(chatPeerId: chatPeerId, request: .welcome(userId: userId)) else { return nil }
            return (userId, wire)
        }
    }

    /// PLAN.md 3.34.6: whether this device should post its own `P1` into this group without being asked,
    /// because it is waiting for a key in an auto-mode group.
    ///
    /// The caller holds `announcedAt` (in memory is enough): the cooldown exists only so that an admin who is
    /// offline for a week does not collect one announcement per app start, and a fresh install that has
    /// forgotten it announces once, which is the right thing to do anyway.
    public func shouldAnnounceIdentity(chatPeerId: PeerId, announcedAt: Int64?) -> Bool {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        return AutoPairing.shouldAnnounceIdentity(AutoPairing.AnnounceInput(
            mode: ring.chatKeyMode(chat),
            isGroup: chat.hasPrefix("-"),
            isEncrypted: ring.isChatEncrypted(chat),
            // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a locked group's key is here, just behind a password.
            hasKey: ring.chatMasterId(chat) != nil || ring.groupPasswordRecord(chat)?.active == true,
            announcedAt: announcedAt,
            now: Int64(Date().timeIntervalSince1970)))
    }

    /// PLAN.md 3.34.6: adopt a group announcement that REPLACES the key already on file for `userId`.
    ///
    /// The only road to that, and it exists solely so a person can take the decision. Receiving one never
    /// adopts it (see `RekeyProcessor.handleP1`), because a `P1` proves who the server said sent the message
    /// and nothing about whether that person still holds the account.
    ///
    /// `userId` comes from the control line's own detail, where the processor wrote it after checking it
    /// against the sender. Verifying against that — rather than against the id inside the wire, which would
    /// only prove the message agrees with itself — is what keeps a hand-pasted `P1` from walking in.
    @discardableResult
    public func adoptMemberKey(chatPeerId: PeerId, userId: String, p1: String) -> Bool {
        guard let parsed = Rekey.parseP1(p1.trimmingCharacters(in: .whitespacesAndNewlines)),
              Rekey.verifyP1(parsed, senderId: userId) else { return false }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        do {
            try ring.setMemberPk(chatId: chat, userId: parsed.userId, parsed.x25519Pk)
            try ring.setMemberEdPk(chatId: chat, userId: parsed.userId, parsed.ed25519Pk)
            return true
        } catch {
            return false
        }
    }

    /// PLAN.md 3.34.3 rule 1: who Telegram says this group's admins are, as the UI layer last read them.
    ///
    /// The UI layer is the only place that can answer this — the list lives in the postbox and loads
    /// asynchronously — so it hands the answer down, and until it does `isGroupAdmin` says "not known", which
    /// is what parks a notice instead of refusing it.
    ///
    /// An EMPTY list is not an answer either (PLAN.md 3.34.7 item 4). Every group has an owner, so a list with
    /// nobody in it is a list that was not actually fetched — which is precisely what a basic group's
    /// `LegacyGroupParticipants` hands over before it loads. Recording it would turn "not loaded" into "nobody
    /// here is an admin" and refuse every genuine notice with `not_admin`; seen on a phone on 2026-09-19, where
    /// the group's own creator was refused. Refused here as well as at the caller: this is the write, and the
    /// rule belongs where the damage would be done.
    /// - Returns: whether the answer actually moved. Nothing is unparked when it did not — re-judging on every
    ///   repeat of the same list would re-run the whole queue on every chat open.
    @discardableResult
    public func setGroupAdmins(chatPeerId: PeerId, userIds: [String]) -> Bool {
        guard !userIds.isEmpty else { return false }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let incoming = Set(userIds)
        groupAdminsLock.lock(); defer { groupAdminsLock.unlock() }
        guard groupAdmins[chat] != incoming else { return false }
        groupAdmins[chat] = incoming
        return true
    }

    /// The group's Telegram admins as last read, or nil when the list has not loaded. Used by the co-holder
    /// turn rule (PLAN.md 3.34.6) as well as by rule 1.
    public func groupAdminIds(chatPeerId: PeerId) -> [String]? {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        groupAdminsLock.lock(); defer { groupAdminsLock.unlock() }
        return groupAdmins[chat].map { $0.sorted() }
    }

    /// nil means "the admin list has not loaded", which `RekeyProcessor.handleN1` parks on. Private chats have
    /// no admin list at all, and the processor refuses an `N1` there before it ever reads this.
    private func isGroupAdmin(chat: String, userId: String) -> Bool? {
        groupAdminsLock.lock(); defer { groupAdminsLock.unlock() }
        return groupAdmins[chat].map { $0.contains(userId) }
    }

    /// Saved Messages encrypts itself the first time this account is seen (PLAN.md 3.20).
    ///
    /// Saved Messages is a chat with nobody: there is no peer to agree a key with, so the usual reason to wait for
    /// the user does not apply — and it is the one chat whose entire contents live on the server by definition. A key
    /// is made here rather than asked for. `isPrivateChat` deliberately excludes this account, so the chat takes the
    /// "group" branch of the menu — create / import a key rather than pair with someone — which is what it needs.
    ///
    /// The cost is announced once, by whoever drains `consumeSavedMessagesNotice`: the key exists only on this
    /// device, so the other devices of this account read ciphertext until the keyring is carried over (PLAN.md 3.14).
    /// Once, and only once, because the keyring is persisted: the key is created on exactly one launch, ever.
    @discardableResult
    public func ensureSavedMessagesKey() -> Bool {
        let chat = SecutgAccountRuntime.chatKey(accountPeerId)
        guard ring.chatMasterId(chat) == nil else { return false }
        guard (try? createMaster(chatPeerId: accountPeerId)) != nil else { return false }
        ring.setChatEncryption(chatId: chat, enabled: true)
        savedMessagesNoticeLock.lock()
        savedMessagesNoticePending = true
        savedMessagesNoticeLock.unlock()
        return true
    }

    /// True exactly once after `ensureSavedMessagesKey` actually made a key, for the UI to say so and never again.
    public func consumeSavedMessagesNotice() -> Bool {
        savedMessagesNoticeLock.lock(); defer { savedMessagesNoticeLock.unlock() }
        let pending = savedMessagesNoticePending
        savedMessagesNoticePending = false
        return pending
    }

    public func exportPayload(chatPeerId: PeerId) -> String? {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        guard let masterId = ring.chatMasterId(chat), let master = ring.masterKey(for: masterId) else { return nil }
        return KeyPayload.build(masterKey: master, adminPk: ring.chatAdminPk(chat), mode: ring.chatKeyMode(chat))
    }

    /// Why an import was refused, when it was. `wrongAdminKey` is the only one a real person walks into and can
    /// act on, so it is the only one with a sentence of its own (PLAN.md 3.34.4).
    public enum ImportResult: Equatable { case imported, notAPayload, wrongAdminKey, failed }

    /// Member: import a scanned / pasted `secutg://key?…` payload. `source` records where it came from (PLAN.md
    /// 3.13 rule 3): the offline QR / paste by default, or the encrypted invite card that carried it.
    ///
    /// **Everything that can refuse comes first, before anything is written.** A payload this method goes on to
    /// reject must leave the chat exactly as it found it — a stranger's master bound to a chat whose payload was
    /// then refused is worse than no import at all, and nothing below the first write may fail.
    public func importMasterResult(chatPeerId: PeerId, payload: String, source: ChatKeySource = .offline) -> ImportResult {
        guard let parsed = KeyPayload.parse(payload) else { return .notAPayload }
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        // PLAN.md 3.34.4: in a group waiting for its replacement key, the code being scanned MUST carry the key
        // the notice announced. The rule itself is `ScannedKeyGate`, pure and under test; what belongs here is
        // only reading the three facts it judges out of the live ring.
        guard ScannedKeyGate.accepts(announcedAdminPk: ring.chatAdminPk(chat),
                                     isEncrypted: ring.isChatEncrypted(chat),
                                     hasMaster: ring.chatMasterId(chat) != nil,
                                     payloadAdminPk: parsed.adminPk) else {
            return .wrongAdminKey
        }
        do {
            let masterId = try ring.addMaster(parsed.masterKey)
            if let adminPk = parsed.adminPk { try ring.setChatAdminPk(chatId: chat, adminPk) }
            try ring.setChatMaster(chatId: chat, masterId: masterId, label: nil)
            ring.setChatEncryption(chatId: chat, enabled: true)
            try ring.setChatKeySource(chatId: chat, source)
            // PLAN.md 3.34.1: the mode arrived with the key. A payload from an older build carries none and
            // parses as `manual`, the reading that sends the user to a person rather than leaving them waiting
            // for a key nobody is going to send.
            ring.setChatKeyMode(chatId: chat, parsed.mode)
            // An offline key replaces auto pairing: the chat is now manually paired (security level: high)
            ring.clearChatPairing(chat)
            noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: an imported key arms the flag
            return .imported
        } catch {
            return .failed
        }
    }

    /// The same import for the callers that only ever had two answers. A refusal is a refusal to them; the one
    /// that needs telling apart (3.34.4) asks `importMasterResult` directly.
    public func importMaster(chatPeerId: PeerId, payload: String, source: ChatKeySource = .offline) -> Bool {
        return importMasterResult(chatPeerId: chatPeerId, payload: payload, source: source) == .imported
    }

    /// This device's X25519 / Ed25519 identity, created on first use; returns the P1 text to post in a chat.
    public func announceIdentity() throws -> String {
        let identity: KeyRing.Identity
        if let existing = ring.identity {
            identity = existing
        } else {
            identity = try Rekey.generateIdentity()
            try ring.setIdentity(identity)
        }
        return try Rekey.buildP1(userId: ownUserId, x25519Pk: identity.x25519Pk, ed25519Pk: identity.ed25519Pk, ed25519Sk: identity.ed25519Sk)
    }

    public func registeredMembers(chatPeerId: PeerId) -> [String] {
        return ring.listMemberIds(chatId: SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// The X25519 key this chat currently has on file for `userId`, or nil. Read by the 3.34.6 control line to
    /// tell "a decision is owed" from "it has already been taken", wherever it was taken.
    public func registeredMemberKey(chatPeerId: PeerId, userId: String) -> [UInt8]? {
        return ring.memberPk(chatId: SecutgAccountRuntime.chatKey(chatPeerId), userId: userId)
    }

    public enum RekeyRequest {
        case rotate
        /// user ids to keep (must all have registered P1 keys)
        case reset(keep: [String])
        case welcome(userId: String)
    }

    public enum RekeyError: Error { case notAdmin, noCurrentMaster, unknownMember(String), emptyRecipients, crypto(String) }

    /// Admin: build the signed R1 for this chat and switch the local ring to the new master. The caller sends the text.
    public func buildRekey(chatPeerId: PeerId, request: RekeyRequest) throws -> String {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        guard let adminSk = ring.chatAdminSk(chat) else { throw RekeyError.notAdmin }
        guard let currentId = ring.chatMasterId(chat), let current = ring.masterKey(for: currentId) else { throw RekeyError.noCurrentMaster }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let built: Rekey.Built
        do {
            switch request {
            case .rotate:
                let fresh = KeyDerivation.generateMasterKey()
                built = try Rekey.buildRotate(newMaster: fresh, oldMaster: current, adminSk: adminSk, nowMs: nowMs, epochDays: crypto.epochDays)
                try adopt(fresh, chat: chat, keyId: built.newKeyId)
            case let .reset(keep):
                var recipients = [String: [UInt8]]()
                for userId in keep {
                    guard let pk = ring.memberPk(chatId: chat, userId: userId) else { throw RekeyError.unknownMember(userId) }
                    recipients[userId] = pk
                }
                guard !recipients.isEmpty else { throw RekeyError.emptyRecipients }
                let fresh = KeyDerivation.generateMasterKey()
                built = try Rekey.buildReset(newMaster: fresh, recipients: recipients, adminSk: adminSk, nowMs: nowMs, epochDays: crypto.epochDays)
                try adopt(fresh, chat: chat, keyId: built.newKeyId)
            case let .welcome(userId):
                guard let pk = ring.memberPk(chatId: chat, userId: userId) else { throw RekeyError.unknownMember(userId) }
                built = try Rekey.buildWelcome(currentMaster: current, newcomerX25519Pk: pk, adminSk: adminSk, nowMs: nowMs, epochDays: crypto.epochDays)
            }
        } catch let error as RekeyError {
            throw error
        } catch {
            throw RekeyError.crypto("\(error)")
        }
        return built.wire
    }

    // MARK: keyring transfer between this user's own devices (PLAN.md 3.14, mirrors Web A `secutgExportKeyring` /
    // `secutgInspectKeyring` / `secutgImportKeyring`)

    public struct ExportResult {
        public let bundle: String
        /// Shown once and never stored: without it the file is useless
        public let code: String
        public let fileName: String
        public let summary: TransferSummary
    }

    public struct InspectResult {
        public let summary: TransferSummary
        /// This device already has an identity that differs from the one in the file
        public let needsIdentityChoice: Bool
    }

    public enum TransferError: Error, Equatable {
        case nothingToExport
        /// Wrong transfer code, or the file was altered
        case badCode
        case crypto(String)
    }

    /// Wraps this device's keys in a `K1` container under a freshly generated transfer code. `.all` takes the whole
    /// keyring including the identity key pair (device migration); `.chat` takes only the named chats, and carries the
    /// identity only when asked (an auto-paired private chat needs it, a group does not).
    public func exportKeyring(
        scope: TransferScope, chatPeerIds: [PeerId] = [], withIdentity: Bool = false, device: String = "Si4Gram iOS", // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        includeDeviceLabels: Bool = true
    ) throws -> ExportResult {
        let chatIds = chatPeerIds.map(SecutgAccountRuntime.chatKey)
        if scope == .chat && chatIds.isEmpty { throw TransferError.nothingToExport }
        // PLAN.md 3.25.4 rule 2: the export dialog's "不包含设备备注" checkbox, off by default (= included)
        let snapshot = scope == .all
            ? ring.exportSnapshot(includeDeviceLabels: includeDeviceLabels)
            : ring.exportChatsSnapshot(chatIds: chatIds, withIdentity: withIdentity, includeDeviceLabels: includeDeviceLabels)
        let createdAt = Int64(Date().timeIntervalSince1970)
        let payload = TransferPayload(
            scope: scope, chatIds: scope == .chat ? chatIds : nil,
            createdAt: createdAt, device: device, snapshot: snapshot)
        let code = TransferCode.generate()
        let bundle: String
        do {
            bundle = try TransferBundle.build(payload, code: code)
        } catch {
            throw TransferError.crypto("\(error)")
        }
        return ExportResult(
            bundle: bundle, code: code,
            fileName: "secutg-keys-\(SecutgAccountRuntime.transferStamp(createdAt)).secutg",
            summary: TransferBundle.summarize(payload, nowSeconds: createdAt))
    }

    /// Opens the container so the UI can show what is inside before anything is written (PLAN.md 3.14 rule 1).
    /// SECUTG-HOOK (PLAN.md 3.39.7, 2026-09-29): a single chat's import (a K1 chat-scope file, a K1Q, a V2Q) never
    /// touches this device's global identity — the "替换本机身份" choice is offered for the whole-keyring import only.
    public func inspectKeyring(bundle: String, code: String) throws -> InspectResult {
        guard let payload = TransferBundle.open(bundle, code: code) else { throw TransferError.badCode }
        let local = ring.identity
        let incoming = payload.snapshot.identityEd25519Pk
        let isSame = local != nil && incoming != nil && local!.ed25519Pk == incoming!
        return InspectResult(
            summary: TransferBundle.summarize(payload, nowSeconds: Int64(Date().timeIntervalSince1970)),
            needsIdentityChoice: payload.scope == .all && local != nil && incoming != nil && !isSame)
    }

    @discardableResult
    public func importKeyring(bundle: String, code: String, replaceIdentity: Bool) throws -> KeyRingMergeResult {
        guard let payload = TransferBundle.open(bundle, code: code) else { throw TransferError.badCode }
        // SECUTG-HOOK (PLAN.md 3.39.7): see `inspectKeyring` — a chat-scope file can carry an identity (3.14's
        // auto-paired export) but may never install it; only a whole-keyring import replaces the identity.
        let merged = ring.mergeSnapshot(payload.snapshot, replaceIdentity: replaceIdentity && payload.scope == .all)
        armKeyRequiredForKeyedChats() // PLAN.md 3.41.1: keys that arrived by transfer arm their chats
        return merged
    }

    // MARK: clone this 1v1 chat onto my other device by QR (PLAN.md 3.39.13)

    /// PLAN.md 3.39.13: the V2Q for `chatPeerId`, a 1v1 chat this device holds a current, sendable v2 binding for. The
    /// code carries this device's identity for the chat — whoever scans it becomes this device there. Nothing is
    /// written: show it, then forget it.
    public func prepareJoinShare(chatPeerId: PeerId) -> V2PairingDispatch.JoinShareOutcome {
        guard isPrivateChat(chatPeerId) else { return .notPaired }
        return V2PairingDispatch.prepareJoinShare(accountKey: ownUserId, chatId: SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// The manifest of a scanned V2Q for `chatPeerId` — the chat the user is scanning IN, which must be the one the
    /// code names (`wrong_chat` otherwise). Nothing is written.
    public func inspectJoin(chatPeerId: PeerId, text: String) -> V2PairingDispatch.JoinInspectOutcome {
        guard isPrivateChat(chatPeerId) else { return .refused(.wrongChat) }
        return V2PairingDispatch.inspectJoin(accountKey: ownUserId, chatId: SecutgAccountRuntime.chatKey(chatPeerId), text: text)
    }

    /// PLAN.md 3.39.13: installs the clone — the chat reads and sends from this moment, and nothing is sent.
    public func installJoin(chatPeerId: PeerId, text: String) -> V2PairingDispatch.JoinInstallOutcome {
        guard isPrivateChat(chatPeerId) else { return .refused(.wrongChat) }
        let outcome = V2PairingDispatch.installJoin(accountKey: ownUserId, chatId: SecutgAccountRuntime.chatKey(chatPeerId), text: text)
        if case .installed = outcome {
            // PLAN.md 3.19: history sealed under the masters the code brought can be opened now.
            forgetOpenedMessages()
            noteKeyRequired(chatPeerId: chatPeerId) // PLAN.md 3.41.1: the chat has a sendable key from now on
            keysChanged.putNext(chatPeerId) // PLAN.md 3.17 rule 3: rows waiting for a key are swept
        }
        return outcome
    }

    /// PLAN.md 3.14.1: one chat's keys as a single QR text (`K1Q:<code>:<K1 container>`) for another device of this
    /// same user. Saved Messages and groups only — a 1v1 private chat's v2 binding is tied to this device's identity,
    /// so copying its key alone cannot work (that is the V2Q clone's job, PLAN.md 3.39.13), and this refuses it
    /// rather than trusting every caller to have hidden the entry. Never carries the identity key pair. The
    /// transfer code is fresh for every call and lives only inside the QR it returns.
    public func exportQuickShare(chatPeerId: PeerId, device: String = "Si4Gram iOS") throws -> QuickShare.Outcome { // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        if isPrivateChat(chatPeerId) { throw TransferError.nothingToExport }
        let chatId = SecutgAccountRuntime.chatKey(chatPeerId)
        // Device labels stay home: they are 3.14's optional part and every byte counts in a QR (same as Web A).
        let base = ring.exportChatsSnapshot(chatIds: [chatId], withIdentity: false, includeDeviceLabels: false)
        let history = QuickShare.history(full: ring.snapshot(), chatId: chatId, base: base)
        do {
            return try QuickShare.build(
                chatId: chatId, base: base, historyNewestFirst: history, createdAt: Int64(Date().timeIntervalSince1970),
                device: device, code: TransferCode.generate())
        } catch {
            throw TransferError.crypto("\(error)")
        }
    }

    /// PLAN.md 3.14.1: the merge behind a scanned quick-share QR, after the same manifest and confirmation as 3.14.
    /// Identical to `importKeyring` except that a Saved Messages key replaces this device's own 3.20 key as the
    /// sending key, the old one staying as a read-only history key (2026-09-28; `KeyRing.mergeQuickShare`).
    /// Groups keep the never-roll-back merge. A whole-keyring file is refused: it is never a quick share.
    @discardableResult
    public func importQuickShare(bundle: String, code: String) throws -> KeyRingMergeResult {
        guard let payload = TransferBundle.open(bundle, code: code), payload.scope == .chat else { throw TransferError.badCode }
        let merged = ring.mergeQuickShare(payload, savedChatId: SecutgAccountRuntime.chatKey(accountPeerId))
        armKeyRequiredForKeyedChats() // PLAN.md 3.41.1: keys that arrived by quick share arm their chats
        return merged
    }

    /// `YYYYMMDDHHMM` in UTC, the same stamp Web A puts in the file name.
    static func transferStamp(_ unixSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    private func adopt(_ master: [UInt8], chat: String, keyId: String) throws {
        let masterId = try ring.addMaster(master)
        try ring.setChatMaster(chatId: chat, masterId: masterId, label: KeyDerivation.parseKeyId(keyId)?.label)
    }
}

/// SECUTG: lookup table the upstream hooks use. Populated from `Account.init`.
public final class SecutgHookRegistry {
    public static let shared = SecutgHookRegistry()
    private let lock = NSLock()
    private var byAccount: [PeerId: SecutgAccountRuntime] = [:]
    private var byPostbox: [ObjectIdentifier: SecutgAccountRuntime] = [:]

    @discardableResult
    public func install(accountPeerId: PeerId, accountRecordId: String, basePath: String, postbox: Postbox) -> SecutgAccountRuntime {
        lock.lock(); defer { lock.unlock() }
        if let existing = byAccount[accountPeerId] {
            byPostbox[ObjectIdentifier(postbox)] = existing
            return existing
        }
        let storage = SecutgKeyRingStorage(accountKey: accountRecordId, basePath: basePath)
        let runtime = SecutgAccountRuntime(accountPeerId: accountPeerId, storage: storage, crypto: SecutgConfigHolder.shared.crypto)
        // PLAN.md 3.20: this is where the account's own peer id first becomes known, and Saved Messages needs no
        // agreement with anybody, so it makes its own key here rather than waiting to be asked. Idempotent: the
        // keyring is persisted, so only the very first launch of this account on this device creates anything.
        runtime.ensureSavedMessagesKey()
        byAccount[accountPeerId] = runtime
        byPostbox[ObjectIdentifier(postbox)] = runtime
        return runtime
    }

    public func runtime(for accountPeerId: PeerId) -> SecutgAccountRuntime? {
        lock.lock(); defer { lock.unlock() }
        return byAccount[accountPeerId]
    }

    public func runtime(forPostbox postbox: Postbox) -> SecutgAccountRuntime? {
        lock.lock(); defer { lock.unlock() }
        return byPostbox[ObjectIdentifier(postbox)]
    }
}
