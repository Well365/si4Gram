import Foundation

/// SECUTG-HOOK (fix, 2026-09-27): the v2 half of a private chat's pairing status, lifted out of
/// `SecutgAccountRuntime.v2Status`/`safetyCodeV2` (TelegramCore, which `swift test` cannot reach) so
/// the rules below are pinned by SecutgCore tests. `chatId` is always THIS device's own name for the
/// chat (a real 1:1 chat id is asymmetric — see `V2Processor.PendingTxn.localChatId`).
///
/// Rules, in order:
/// - A current binding reads "paired", with that binding's own safety code. It offers a cached invite
///   only when the invite post-dates the binding (the peer reinstalled/reset and is pairing afresh —
///   accepting replaces the binding) and has not expired.
/// - A cached invite is never offered once its transaction is closed on this device (another device of the
///   account accepted it, a V2Q import replaced it, the inviter cancelled it) or when the binding came from it.
/// - An in-flight transaction reads "invited" (CONFLICT reads "other_device") — EXCEPT this device's
///   own INVITE past its `expires_ms`: nobody can accept it any more, so it reads as no state rather
///   than "等待对方同意…" forever.
/// - A DONE transaction without a binding (unpaired) is no state and has no safety code.
/// - No state offers a cached incoming invite only while it is unexpired.
public struct V2PairingStatus: Equatable {
    /// nil (nothing — offer 〔自动配对〕), "invited", "paired" or "other_device".
    public let pairingState: String?
    public let verified: Bool
    public let hasIncomingInvite: Bool
    /// Short safety code of the chat's CURRENT binding; nil without one.
    public let safetyCode: String?

    public init(pairingState: String?, verified: Bool, hasIncomingInvite: Bool, safetyCode: String?) {
        self.pairingState = pairingState
        self.verified = verified
        self.hasIncomingInvite = hasIncomingInvite
        self.safetyCode = safetyCode
    }

    public static let none = V2PairingStatus(pairingState: nil, verified: false, hasIncomingInvite: false, safetyCode: nil)

    public static func of(_ runtime: V2Runtime, chatId: String) -> V2PairingStatus {
        let pairing = runtime.pairing
        // SECUTG-HOOK (fix, 2026-10-01 真机): nor one whose transaction is closed here (a sibling accepted it, a V2Q import
        // replaced it, the inviter cancelled it) or that the current binding came from.
        let liveInvite = runtime.persisted.incomingInviteStore.get(chatId).flatMap {
            pairing.isInviteExpired($0) || V2PairingDispatch.isInviteClosed(runtime, chatId: chatId, inviteWire: $0) ? nil : $0
        }
        if let binding = pairing.bindingStore.current(chatId) {
            let newerInvite = liveInvite.map { V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: binding.installedAtMs, inviteWire: $0) } ?? false
            // PLAN.md 3.39.7: transcript-derived when this device paired, the code the V2Q carried when it was cloned.
            return V2PairingStatus(pairingState: "paired", verified: binding.verified, hasIncomingInvite: newerInvite,
                                   safetyCode: pairing.safetyCodeForChat(chatId))
        }
        let nothing = V2PairingStatus(pairingState: nil, verified: false, hasIncomingInvite: liveInvite != nil, safetyCode: nil)
        guard let txnId = pairing.currentTransactionForChat(chatId), let phase = pairing.phaseOf(txnId) else { return nothing }
        switch phase {
        case .invited, .selecting, .confirming:
            if pairing.isOwnInviteExpired(txnId) { return nothing }
            return V2PairingStatus(pairingState: "invited", verified: false, hasIncomingInvite: false, safetyCode: nil)
        case .conflict:
            return V2PairingStatus(pairingState: "other_device", verified: false, hasIncomingInvite: false, safetyCode: nil)
        case .done:
            // DONE with no current binding means the pairing was undone (UNPAIR): nothing, not "paired".
            return nothing
        }
    }

    /// `of(_:chatId:)` for the runtime registered under `accountKey`; `.none` when there is none.
    public static func of(accountKey: String, chatId: String) -> V2PairingStatus {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .none }
        return of(runtime, chatId: chatId)
    }

    /// Whether v2 has anything at all for the chat: a binding, an in-flight or CONFLICT transaction, or a
    /// pending acceptable invite.
    public var hasAnyState: Bool { return pairingState != nil || hasIncomingInvite }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): a private chat's pairing status is **v2-first**. The user's ruling:
    /// v2 takes priority over v1, and v1 new pairing is permanently disabled, so a v1 pairing record is either a
    /// real v1 "paired" chat (still encrypting with E1) or a leftover from older testing. Reading the v1 record
    /// first is how a real device showed 等待对方同意 (a leftover v1 "invited") on a chat v2 had paired, and
    /// sent a v1 P1 the peer could never accept.
    ///
    /// - v2 has any state → v2's pairing state, verified flag and safety code; any v1 record is residue.
    /// - v2 has nothing → the v1 record, but only when it is "paired". v1 "invited", "key_changed" and
    ///   "other_device" are leftovers and read as no state.
    /// - An incoming invite is v2-only: no client sends a v1 P1 any more.
    public struct Resolved: Equatable {
        public enum Source: Equatable {
            /// Nothing to show (a v1 leftover may still exist — see `hasResidualV1Pairing`).
            case none
            case v2
            /// A real v1 "paired" chat, v2 having nothing for it.
            case v1
        }

        public let source: Source
        /// nil (offer 〔自动配对〕), "invited", "paired" or "other_device".
        public let pairingState: String?
        public let verified: Bool
        public let hasIncomingInvite: Bool
        /// A v1 pairing record exists but is being ignored — a leftover. A v1 key it left behind must not hide
        /// the only way left to pair.
        public let hasResidualV1Pairing: Bool

        public init(source: Source, pairingState: String?, verified: Bool, hasIncomingInvite: Bool, hasResidualV1Pairing: Bool) {
            self.source = source
            self.pairingState = pairingState
            self.verified = verified
            self.hasIncomingInvite = hasIncomingInvite
            self.hasResidualV1Pairing = hasResidualV1Pairing
        }
    }

    /// `v1State` is the raw value of the chat's v1 `KeyRing.Pairing.State`, nil without a v1 record.
    public static func resolve(_ v2: V2PairingStatus, v1State: String?, v1Verified: Bool) -> Resolved {
        if v2.hasAnyState {
            return Resolved(source: .v2, pairingState: v2.pairingState, verified: v2.verified,
                            hasIncomingInvite: v2.hasIncomingInvite, hasResidualV1Pairing: v1State != nil)
        }
        if v1State == KeyRing.Pairing.State.paired.rawValue {
            return Resolved(source: .v1, pairingState: v1State, verified: v1Verified, hasIncomingInvite: false, hasResidualV1Pairing: false)
        }
        return Resolved(source: .none, pairingState: nil, verified: false, hasIncomingInvite: false, hasResidualV1Pairing: v1State != nil)
    }
}
