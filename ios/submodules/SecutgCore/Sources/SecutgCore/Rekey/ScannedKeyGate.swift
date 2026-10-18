import Foundation

/// PLAN.md 3.34.4: 「扫到的载荷 `admin_pk` **必须等于**通知里宣布的新公钥，否则拒收」.
///
/// **Manual mode's entire strength rests on this one sentence, and this is where it is claimed.** A member
/// whose key was just retired has been told, by the notice itself, to go and find somebody and scan their
/// code. Without this check the software then accepts whichever code is put in front of them first — which is
/// the same attack the mode exists to rule out, arriving through the very instruction the mode gives.
///
/// The notice already named the only acceptable key. So the comparison costs nothing and needs no new state:
/// the announced key is simply what the chat trusts, because accepting the `N1` is what put it there.
///
/// Scoped to the state an accepted `N1` leaves behind, and only that — encryption on, a key trusted, no master
/// bound. The two chats deliberately left alone:
///
/// * A **first** import has nothing to compare against. Refusing there would make it impossible ever to join a
///   group, since the trusted key only arrives with the key itself.
/// * A chat that **still holds its master** is not waiting for a replacement. Importing a different key there
///   is a member deliberately re-keying a working chat by hand, which is not this rule's business — and making
///   it this rule's business would forbid the ordinary "the admin handed me a new code" case.
///
/// A payload carrying **no** `admin_pk` is refused here too, not waved through. Creating a key always writes
/// one, so a payload without one cannot be the key the notice announced; and accepting it would leave the
/// member encrypting under a stranger's master while still trusting the real admin's signing key, which is the
/// worst of both readings. The rule as written says the scanned key must *equal* the announced one, and
/// "absent" does not equal it. (Web had this comparison inside its "if the payload carries an admin_pk"
/// branch; the macOS and Android ports read the rule as written and were right.)
public enum ScannedKeyGate {
    /// - Parameters:
    ///   - announcedAdminPk: the admin key this chat currently trusts, i.e. the one the notice announced.
    ///   - isEncrypted: this chat's encryption switch, which an accepted notice deliberately leaves on.
    ///   - hasMaster: a master is bound to this chat. An accepted notice leaves none.
    ///   - payloadAdminPk: the `admin_pk` inside the payload being imported.
    /// - Returns: whether this payload may be accepted for this chat.
    public static func accepts(announcedAdminPk: [UInt8]?, isEncrypted: Bool, hasMaster: Bool,
                               payloadAdminPk: [UInt8]?) -> Bool {
        // Not waiting for a replacement: this rule has nothing to say about the payload.
        guard let announced = announcedAdminPk, isEncrypted, !hasMaster else { return true }
        // Deliberately an equality against an optional, so a payload with no `admin_pk` is refused with the
        // mismatched ones rather than by a branch of its own that could be forgotten.
        return payloadAdminPk == announced
    }
}
