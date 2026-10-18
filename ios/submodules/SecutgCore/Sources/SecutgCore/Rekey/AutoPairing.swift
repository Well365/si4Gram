import Foundation

/// PLAN.md 3.34.6, the automatic half of auto mode: the decisions behind 「群里每个人自动拿到钥」.
///
/// All of them are pure, so the rule can be read, argued with and tested without a Telegram account attached.
/// The sending itself is plumbing and lives in the runtime; what belongs here is *who*, *when*, and *which
/// device*.
public enum AutoPairing {
    /// PLAN.md 3.34.4: after a rebuild the key-holding device hands the new master to
    /// 「当前 Telegram 成员 ∩ 已登记公钥」, one `R1 welcome` each.
    ///
    /// **The intersection is the whole security model of auto mode**, and both halves of it matter:
    ///
    /// * `memberIds` is the *current* Telegram member list, read fresh at send time. This is what makes one
    ///   button do exclusion as well as renewal: somebody who left, or was removed, is simply not in the list
    ///   any more, so no copy is sealed for them. Nobody has to remember to exclude anyone, and there is no
    ///   separate "kick" operation to get wrong. The honest flip side, which 3.34.6 says to write into the
    ///   copy: in auto mode the member list *is* the authorisation, so whoever can add someone to the group
    ///   can let them read.
    /// * `registeredIds` is who this device has a public key on file for. A welcome is sealed to a specific
    ///   X25519 key; without one there is nothing to seal to. A member missing here is not refused, just not
    ///   ready — their device announces itself (see `shouldAnnounceIdentity`) and the next pass picks them up.
    ///
    /// A stale registration is NOT a licence: someone whose key we still hold but who is no longer in the group
    /// falls out at the `memberIds` half. The two lists are ANDed, never ORed.
    ///
    /// Returns a sorted, de-duplicated list so that two devices computing it independently (co-holding, 3.33)
    /// agree on the answer, and so a test can compare it without sorting first.
    public struct WelcomeInput {
        public let mode: Rekey.KeyMode
        /// Only groups have a member list to intersect with
        public let isGroup: Bool
        /// This device holds the chat's admin signing key, so it is able to issue `R1` at all
        public let holdsAdminKey: Bool
        /// A master is bound to the chat: `welcome` hands out the CURRENT key, so there has to be one
        public let hasKey: Bool
        public let ownUserId: String?
        /// The chat's current Telegram members
        public let memberIds: [String]
        /// Members whose `P1` this device has on file
        public let registeredIds: [String]

        public init(mode: Rekey.KeyMode, isGroup: Bool, holdsAdminKey: Bool, hasKey: Bool, ownUserId: String?,
                    memberIds: [String], registeredIds: [String]) {
            self.mode = mode; self.isGroup = isGroup; self.holdsAdminKey = holdsAdminKey; self.hasKey = hasKey
            self.ownUserId = ownUserId; self.memberIds = memberIds; self.registeredIds = registeredIds
        }
    }

    public static func welcomeRecipients(_ input: WelcomeInput) -> [String] {
        // Manual mode distributes by hand, face to face. Nothing automatic may send a key there — that is the
        // entire difference between the two modes, not a detail of one.
        guard input.mode == .auto, input.isGroup, input.holdsAdminKey, input.hasKey else { return [] }
        let registered = Set(input.registeredIds)
        return Set(input.memberIds.filter { $0 != input.ownUserId && registered.contains($0) }).sorted()
    }

    /// PLAN.md 3.34.6: how long a device that nobody answered waits before announcing itself again.
    ///
    /// The cooldown is only for the case where nobody answers — an admin who is offline for a week should not
    /// collect one announcement per app start.
    public static let announceCooldownSeconds: Int64 = 6 * 60 * 60

    /// PLAN.md 3.34.6, the other half: a member's device announcing its public key on its own, so that a
    /// key-holder has something to seal a welcome to.
    ///
    /// The trigger is "I am in an auto-mode encrypted group and I hold no key". That covers both cases this
    /// exists for without distinguishing them: a member who has just been added, and a member whose key was
    /// retired a moment ago by an `N1`. Both are waiting for the same thing.
    ///
    /// It stops on its own: the welcome that answers the announcement binds a master, `hasKey` becomes true, and
    /// the condition is false from then on.
    public struct AnnounceInput {
        public let mode: Rekey.KeyMode
        public let isGroup: Bool
        /// The chat is switched on: a chat nobody is encrypting has no reason to collect public keys
        public let isEncrypted: Bool
        /// A master is bound. Holding one means the announcement has already been answered
        public let hasKey: Bool
        /// When this device last announced itself in this chat, unix seconds
        public let announcedAt: Int64?
        public let now: Int64

        public init(mode: Rekey.KeyMode, isGroup: Bool, isEncrypted: Bool, hasKey: Bool, announcedAt: Int64?, now: Int64) {
            self.mode = mode; self.isGroup = isGroup; self.isEncrypted = isEncrypted; self.hasKey = hasKey
            self.announcedAt = announcedAt; self.now = now
        }
    }

    public static func shouldAnnounceIdentity(_ input: AnnounceInput) -> Bool {
        guard input.mode == .auto, input.isGroup, input.isEncrypted else { return false }
        // Holding a key means there is nothing to wait for — announcing again would only ask for a copy of what
        // we already have.
        guard !input.hasKey else { return false }
        guard let announcedAt = input.announcedAt else { return true }
        return input.now - announcedAt >= announceCooldownSeconds
    }

    /// PLAN.md 3.34.6: 「共持时持钥者中 user_id 最小的那台执行，其余待命」.
    ///
    /// Since 3.33 several admins can hold the same group's signing key, and each of their devices sees the same
    /// announcement and would answer it. The rule picks one. The problem is that no device can see who else holds
    /// the key — holding it is not announced — so "the lowest holder" is not directly computable, and a rule that
    /// waits for a device that may be switched off leaves a member with no key at all.
    ///
    /// So the order is kept and the waiting is made to end. Rank is taken among the group's Telegram admins,
    /// which every holder is (3.32) and every device can read. The lowest-ranked holder answers the first
    /// announcement, the next one answers the second, and so on — and because a member stops announcing the
    /// moment a key arrives, a second announcement only ever happens when the first holder did not answer. One
    /// welcome in the ordinary case, a standby that really takes over when the ordinary case fails, and no device
    /// waiting on another device's presence.
    ///
    /// Both unknowns resolve towards acting: a device that is not in the admin list, and a list that has not
    /// loaded, both rank 0. A duplicate welcome costs one control line and opens the same master; silence costs
    /// somebody their key.
    public struct TurnInput {
        public let ownUserId: String?
        /// The group's Telegram admins, in any order
        public let adminIds: [String]?
        /// How many times this member has announced since we last sent them a copy. The first is 1.
        public let announceCount: Int

        public init(ownUserId: String?, adminIds: [String]?, announceCount: Int) {
            self.ownUserId = ownUserId; self.adminIds = adminIds; self.announceCount = announceCount
        }
    }

    public static func isOurTurnToWelcome(_ input: TurnInput) -> Bool {
        return input.announceCount > welcomeRank(input)
    }

    /// Exposed for the tests that pin the ordering itself rather than one device's answer.
    public static func welcomeRank(_ input: TurnInput) -> Int {
        guard let ownUserId = input.ownUserId, let adminIds = input.adminIds, !adminIds.isEmpty else { return 0 }
        let ordered = Set(adminIds).sorted(by: compareUserIds)
        return ordered.firstIndex(of: ownUserId) ?? 0
    }

    /// Telegram user ids are decimal integers wider than any of the five clients wants to push through its
    /// native number type, so they are ordered as numbers *written down*: shorter is smaller, and same-length
    /// compares digit by digit. Ordering them as plain strings would put `1000` before `85`, and two holders
    /// computing different orders would either both answer or neither would.
    private static func compareUserIds(_ a: String, _ b: String) -> Bool {
        return a.count == b.count ? a < b : a.count < b.count
    }
}
