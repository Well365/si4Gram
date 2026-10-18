import Foundation

/// "The latest `P1` wins" on the *own-account* axis (PLAN.md 3.7 rules 8 and 13, direction flipped by 3.25.11).
/// Byte-identical in intent to Web A `src/secutg/rekey/ownP1Race.ts`.
///
/// The situation this exists for: the peer holds one invite open and two devices of *our* account answer it
/// before either has seen the other. **This rule is not free to choose a winner: it has to name the device the
/// peer will end up talking to.** Since 3.25.11 the peer adopts a changed key on sight, so of two `P1`s of ours
/// the peer settles on the later one — and so must we. (Until 3.25.11 the peer kept the first `P1` and called
/// the second a duplicate, and this file said "earliest wins" for that reason; the criterion below is
/// unchanged, only its direction.) Our two devices are not consulted — so each of them has to arrive at that
/// same verdict on its own, and they have to arrive at the *same* one. If they disagree, both encrypt, each
/// with its own master, and the peer can read only one of them.
///
/// So the criterion has to be a **pure function of facts every device of the account can see**, and there is
/// exactly one such fact per candidate: the `P1` message itself, i.e.
///
///  - its **server date** (`messageDate`) — the only clock all three devices share. Never a local reading:
///    not this machine's wall clock at `startPairing` (the sibling has never seen it and cannot reproduce
///    it) and not `pairedAt` on an accepting device (same problem). `RekeyProcessor.applyOwnEcho` is the one
///    writer of `startedAt`, and it writes the server date the moment this device's own `P1` echoes back,
///    which is what makes the two sides comparable at all. Until then `startedAt` is empty and there is
///    nothing to judge against, which is why `RekeyProcessor.holdSiblingClaim` parks the sibling rather than
///    handing it a verdict this rule cannot honestly give.
///  - its **`device_id`** (PLAN.md 3.25.2, derived from the X25519 public key the `P1` carries), used only to
///    break an exact tie.
///
/// Whole seconds make ties ordinary rather than exotic: a genuine race is one where neither device had yet
/// received the other's `P1`, which bounds it by delivery latency — a second or two. A tie must therefore
/// resolve to *one* winner, not to "both lose" (nobody encrypts while the peer thinks it is paired) and not to
/// "both win" (the fork this whole rule exists to prevent). `device_id` is the only total order available from
/// a `P1` alone, so that is the tiebreak — and since 3.25.11 the peer breaks the same tie the same way
/// (`sortsFirst` against the `P1` it is already paired to, in `RekeyProcessor.settlePeerP1`) instead of by
/// arrival order, so the two sides agree on ties too, not 50% of the time. That is what made the flip to
/// "latest wins" affordable: the criterion is one function, used on both axes.
///
/// The second thing this settles is a conflation the old code made: a sibling `P1` dated *before* this
/// device's own was treated as a history replay and ignored, which is exactly backwards during a race —
/// earlier means it lost. Replay and race look alike (both are a sibling `P1` with an earlier date) and are
/// separated the only way the peer branch already separates them, by `pairingRaceWindowSeconds`: inside the
/// window the two `P1`s answered the same invite and compete, outside it they belong to different pairing
/// rounds and the later round simply wins.
public enum OwnP1Race {
    /// One candidate for holding this chat's pairing: a `P1` of our own account, as the chat shows it
    public struct Claim: Equatable {
        /// Unix seconds, the message's server date — never a local clock reading, see the type comment
        public let at: Int64
        /// PLAN.md 3.25.2 `device_id` of the device that sent it
        public let deviceId: String

        public init(at: Int64, deviceId: String) {
            self.at = at
            self.deviceId = deviceId
        }
    }

    public enum Verdict {
        /// From before this pairing round: a history replay, it changes nothing
        case olderRound
        /// From after this round: another device deliberately re-paired (rule 9), the pairing moved there
        case newerRound
        /// Same round, the newcomer sorts last: it holds the pairing and this device steps out
        case lost
        /// Same round, the current holder sorts last: the newcomer is a duplicate and is ignored
        case won
    }

    /// Judges one incoming own-account `P1` against the `P1` that currently holds this chat's pairing.
    /// `holder` is nil when this device never sent a `P1` in this chat, which is not a race at all — there is
    /// nothing to compare, so the newcomer holds the pairing by default.
    ///
    /// Antisymmetric by construction: run it on the two devices with the arguments swapped and one gets `won`
    /// exactly when the other gets `lost`, because `sortsFirst` is a strict total order over `(at, deviceId)`.
    /// That is the property the whole design rests on. A device's own echo compares equal to itself and sorts
    /// neither way, so it lands on `won` and changes nothing.
    ///
    /// With the direction flipped, `olderRound` and `newerRound` no longer decide anything the in-window
    /// comparison would not have decided the same way — later wins on both sides of the window. They are kept
    /// because the five clients report them differently to the user ("a device of yours re-paired" reads
    /// nothing like "an old message scrolled past"), not because the verdict turns on them.
    public static func judge(holder: Claim?, incoming: Claim, windowSeconds: Int64) -> Verdict {
        guard let holder = holder else { return .lost }
        if incoming.at < holder.at - windowSeconds { return .olderRound }
        if incoming.at > holder.at + windowSeconds { return .newerRound }
        return sortsFirst(holder, incoming) ? .lost : .won
    }

    /// Chat order as every device can recompute it: earlier date first, `device_id` breaks an exact tie.
    /// A `device_id` is 16 lowercase hex characters, so this ordering is plain ASCII order on every client.
    ///
    /// Not private because the *peer* branch of `RekeyProcessor.handleP1` has to order two of the peer's `P1`s
    /// by exactly the same rule (PLAN.md 3.25.11) — if the two sides ordered them differently they would
    /// settle on different devices, which is the fork this whole file exists to prevent.
    public static func sortsFirst(_ a: Claim, _ b: Claim) -> Bool {
        return a.at != b.at ? a.at < b.at : a.deviceId < b.deviceId
    }
}
