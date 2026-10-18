import Foundation

/// Who a group offers to start its key over to (PLAN.md 3.32, amended by 3.33).
///
/// Worth a type of its own only because of which `isAdmin` it does **not** consult. secuTG's `isAdmin` is
/// not the group's admin list: it means "this device holds the group's signing key" — the device that created
/// the key and, since 3.33, any device it handed the key to — which is what rotate / reset / welcome all
/// require. A Telegram admin who merely imported the key has it false, exactly like any member.
///
/// When the creating device wipes — SOS destroys the signing key along with everything else — secuTG's
/// `isAdmin` is false for every remaining member while `hasKey` stays true, so the group loses rotate /
/// reset / welcome AND "create group key" in the same stroke. Groups have no "forget this group's key" action
/// either (unpair is a private-chat notion), so there is no route left by which the group's key can ever
/// change again.
///
/// Gating the way out on secuTG's `isAdmin` would therefore leave that dead end precisely where it was: the
/// people who need it are the ones for whom it is false. It is gated instead on Telegram's own admins —
/// the people the group already trusts to act for it — and not on ordinary members, because recreating the
/// key locks every member out until they import the new one, which is not a member's call to make.
///
/// The first version also excluded the device that created the key, on the grounds that it already has the
/// finer-grained rotate and reset. PLAN.md 3.33 removed that: the signing key may now be held by several
/// devices at once, and the user's decision is that recreating is open to every Telegram admin regardless —
/// the ones holding a signing key included. The confirmation says so: it retires every holder's copy, the
/// presser's own included. The parameter is gone rather than ignored, so no caller can pass it and believe
/// it still counts.
///
/// `hasKey` false is left to the plain "create group key" entry, which is the same call without a
/// confirmation in front of it: there is no key here yet to invalidate.
public enum RecreateGroupKeyGate {
    /// May this device offer to recreate this group's key?
    ///
    /// - Parameters:
    ///   - hasKey: a key for this group is on this device.
    ///   - isTelegramAdmin: Telegram's sense — this account has admin rights in the group, or owns it.
    public static func canRecreateGroupKey(hasKey: Bool, isTelegramAdmin: Bool) -> Bool {
        return hasKey && isTelegramAdmin
    }

    /// PLAN.md 3.34 (2026-09-20 用户定：「其他的非管理员不要有重建群钥匙的菜单」): the other half of the
    /// same gate — may this device offer to make the group's FIRST key?
    ///
    /// This was a bare `!hasKey` check at the call site and nothing else, which was the gap. Since 3.34.3 a
    /// group's first key is *the same act* as a rebuild with nothing to retire — same dialog, same notice,
    /// same choice of mode — so an ordinary member of a group that had no key yet was handed the rebuild,
    /// the one thing 3.32 says is not a member's call. `hasKey` decides only which of the two entries shows;
    /// `isTelegramAdmin` decides whether either does.
    ///
    /// Deliberately NOT secuTG's `isAdmin`, for the reason the type comment spells out.
    public static func canCreateGroupKey(hasKey: Bool, isTelegramAdmin: Bool) -> Bool {
        return !hasKey && isTelegramAdmin
    }
}
