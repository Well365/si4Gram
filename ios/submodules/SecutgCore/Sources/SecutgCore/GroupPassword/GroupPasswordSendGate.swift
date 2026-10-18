import Foundation

/// PLAN.md 3.38.2 "上锁" on the send side: a group whose password policy is on and not opened in this run sends
/// none of the user's words — never through a path that could fall back to plaintext (3.38.1 fix, found on macOS,
/// where typing on the password page reached the composer hidden under it).
///
/// The app's own control messages (`R1 / P1 / U1 / N1 / G2 / GP1`, and v2's `P2`) still go out: they carry no user
/// words, and refusing one after the keyring has already moved (a 〔重建群密钥〕 `G2`, which the password no longer
/// hides) would leave the group without the broadcast. Same rule as the Web reference's `prepareOutgoingText`.
public enum GroupPasswordSendGate {
    /// - Parameters:
    ///   - locked: the group's policy is on and this run has not unlocked it
    ///   - text: the message text; empty for media without a caption, which is refused while locked like any other
    ///     user content
    /// - Returns: true when the send must be refused
    public static func refuses(locked: Bool, text: String) -> Bool {
        guard locked else { return false }
        return text.isEmpty || !Rekey.isControlMessage(text)
    }
}
