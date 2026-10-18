import Foundation

/// What a wipe on this device should do besides destroying the keys (PLAN.md 3.16 / 3.22).
///
/// Three lines of logic, in the shared module and under test, because two of the five ports got the
/// first one wrong independently — and when it is wrong nothing fails, nothing logs, and the user only
/// finds out when the devices they meant to wipe are still sitting there full of messages.
public struct WipePlan: Equatable {
    /// Post the built-in phrase to Saved Messages so the account's other devices wipe themselves.
    public let broadcastsPhrase: Bool
    /// Call `auth.resetAuthorizations` to knock the other devices offline now.
    public let resetsAuthorizations: Bool

    public init(broadcastsPhrase: Bool, resetsAuthorizations: Bool) {
        self.broadcastsPhrase = broadcastsPhrase
        self.resetsAuthorizations = resetsAuthorizations
    }

    /// - Parameters:
    ///   - isRemote: a phrase in Saved Messages triggered this, rather than the user's own tap.
    ///   - listensToPhrase: this device's `wipeListensToPhrase` preference.
    ///   - resetsAuthorizations: this device's `wipeResetsAuthorizations` preference.
    ///
    /// **`listensToPhrase` is not an input, and that is the whole point of writing this down.** It is
    /// the *receiving* side: whether this device acts on a phrase somebody else posted. Whether a wipe
    /// here tells the other devices is the *sending* side, and they are different questions. Someone
    /// who switched off "act on the wipe phrase" has said "nobody gets to wipe me remotely" — they have
    /// said nothing about whether their own panic button should protect their other machines, and
    /// reading it as if they had silences exactly the broadcast the whole of 3.22 exists for.
    ///
    /// A remotely-triggered wipe does neither: re-broadcasting would echo the phrase around the account
    /// forever, and ending sessions is the triggering device's job, not the triggered one's (3.22.4).
    public static func make(isRemote: Bool, listensToPhrase: Bool, resetsAuthorizations: Bool) -> WipePlan {
        _ = listensToPhrase
        return WipePlan(
            broadcastsPhrase: !isRemote,
            resetsAuthorizations: !isRemote && resetsAuthorizations)
    }
}
