import Foundation

/// Moves keyring entries that an older build filed under the **string-concatenated** channel key onto the
/// arithmetic one, and — where the two readings cannot be told apart — moves nothing and leaves a mark that
/// makes the send path fail closed (PLAN.md 3.0).
///
/// ## What went wrong
///
/// `SharedChatId` says a channel is `-(bareId + 10^12)`. iOS, macOS and Windows used to glue the literal
/// prefix `"-100"` in front of the bare id instead. The two spellings are the same number exactly when the
/// bare id is ten digits long, because `100 · 10^10 == 10^12`:
///
/// ```
/// bare 1234567890 (10 digits)  "-100" + bare = -1001234567890 = -(bare + 10^12)   same
/// bare 987654321  ( 9 digits)  "-100" + bare =  -100987654321 ≠ -1000987654321    different
/// bare 1          ( 1 digit )  "-100" + bare =          -1001 ≠ -1000000000001    different
/// ```
///
/// So an old snapshot's channel entries are already correct wherever the bare id is ten digits — which is
/// the shape of essentially every channel Telegram has handed out — and wrong everywhere else. The wrong
/// ones are the ones this migration is for, and leaving them wrong is not a lookup that fails loudly: the
/// chat simply reads as "no key, encryption never enabled", and the message goes out in the clear.
///
/// ## The ambiguity, and why this refuses to guess
///
/// A legacy entry is not self-describing. `"-1001"` is both
///
/// * `"-100"` + bare `1` — channel 1 as the old code filed it, and
/// * `-1001` — basic group 1001 as the current rules spell it,
///
/// and nothing in the number says which. Guessing wrong is worse than not guessing: renaming a live basic
/// group's entry strands that group's key, and hands a channel a key whose members do not have it, so the
/// chat encrypts into a room where nobody can read it. Both readings stay possible, so:
///
/// * **Rename only when one reading is impossible.** Two bounds decide that, and only those two.
///   - `maxPlausibleBasicGroupId` — a magnitude above it cannot be a basic group. A legacy entry for a
///     nine-digit channel lands at `100·10^9 + bare ≈ 1.0 × 10^11`, two orders of magnitude above any basic
///     group id Telegram has allocated (they were `int32` until 2021 and are in the low billions today), so
///     the whole realistic legacy corpus is resolved here without a guess. The bound is a judgement call and
///     is deliberately generous: `10^10` still leaves basic-group ids room to grow by more than 2× before it
///     would matter, and sits a full order of magnitude below the band the legacy entries occupy.
///   - `SharedChatId.channelBase` as a ceiling on a *channel's* bare id. An entry already in the channel zone
///     whose implied bare id is itself past the base cannot be a channel key: encoding such an id would have
///     pushed it out of the zone. That is structural, not empirical, and it is what rescues a legacy entry
///     for an eleven-digit channel.
///
///   A rename still leaves a mark behind on the key it came from. The two bounds are a judgement, not a
///   proof, and once the move is done the source key holds nothing at all — which is precisely the shape
///   ("no key, no switch") that `prepareOutgoing` reads as "encryption was never on in this chat" and lets
///   through in the clear. So the source is quarantined too, on exactly the terms an ambiguous entry's
///   counterpart is: if the judgement was wrong, the chat that really lives at that key refuses to send
///   instead of silently downgrading. Leaving the rename branch unmarked would make it the one remaining
///   instance of the failure this whole migration exists to remove.
/// * **Otherwise keep the entry exactly where it is and quarantine the counterpart.** The entry that is there
///   keeps working for whoever it belongs to; the chat on the other reading gets a `chat_encryption_lost`
///   mark, so if it ever opens, `prepareOutgoing` refuses rather than passing plaintext through. A refusal
///   the user can act on ("re-import this group's key") beats a silent downgrade.
///
/// ## Properties
///
/// * **Idempotent.** A renamed key is `-(bare + 10^12)` with `bare` ten digits or fewer, and re-deciding it
///   yields the same key, so `decide` returns `.keep`. A quarantined source key is left in no chat-keyed map
///   at all, so the second run does not even look at it. Running twice changes nothing the second time.
/// * **Never destructive.** A rename onto an occupied key is refused and reported, never merged. The caller
///   gets a new snapshot; the input is untouched.
/// * **Never fail-open.** The one outcome this will not produce is an entry quietly disappearing from view.
public enum ChannelKeyMigration {
    /// On-disk keyring snapshot version. 1 = written before this migration existed, and therefore possibly
    /// holding string-concatenated channel keys; 2 = migrated. The number is local to this client's own
    /// snapshot file — the `K1` transfer bundle carries its own version and its own schema, so bumping this
    /// changes nothing another client reads.
    public static let snapshotVersion = 2

    /// Above this, a negative chat key cannot be a basic group — see the type's doc comment for the
    /// reasoning and for why the bound is set this far above today's ids.
    public static let maxPlausibleBasicGroupId: Int64 = 10_000_000_000

    /// What to do with one chat key.
    public enum Decision: Equatable {
        /// Already right, or nothing here says otherwise.
        case keep
        /// The legacy reading is the only possible one: move the entry to this key.
        case rename(to: String)
        /// Both readings are possible. Keep the entry; the counterpart is the key the *other* reading would
        /// have used, and it is the one that must fail closed.
        case ambiguous(counterpart: String)
    }

    /// What a run did and, just as importantly, what it deliberately did not do.
    public struct Report: Equatable {
        /// legacy key → arithmetic key, for every entry actually moved
        public var renamed: [String: String] = [:]
        /// kept key → quarantined counterpart, for every entry too ambiguous to move
        public var ambiguous: [String: String] = [:]
        /// keys left alone because the key they would have moved onto is already occupied
        public var conflicts: [String] = []

        public var changed: Bool { return !renamed.isEmpty || !ambiguous.isEmpty }

        public init() {}
    }

    /// The decision for one chat key, from the number alone. Pure, and the only place the rules live.
    public static func decide(chatKey: String) -> Decision {
        // A user key is positive and a channel key is negative, so only the negative ones can be confused.
        guard chatKey.hasPrefix("-") else { return .keep }
        let digits = String(chatKey.dropFirst())
        guard digits.count > 3, digits.hasPrefix("100"), let magnitude = Int64(digits), magnitude > 0 else { return .keep }
        // What `"-100" + bareId` would have meant, and where that channel belongs under the arithmetic rule.
        guard let legacyBare = Int64(digits.dropFirst(3)), legacyBare > 0 else { return .keep }
        let target = SharedChatId.encode(kind: .channel, bareId: legacyBare)
        // The ten-digit case: both spellings are the same number, so there is nothing to move.
        if target == -magnitude { return .keep }
        let counterpart = "\(target)"
        if magnitude >= SharedChatId.channelBase {
            // Reading it by today's rules makes it a channel whose bare id is past the base — impossible,
            // because encoding such an id could not have produced a key in this zone. Legacy it is.
            let bareUnderCurrentRules = magnitude - SharedChatId.channelBase
            return bareUnderCurrentRules >= SharedChatId.channelBase ? .rename(to: counterpart) : .ambiguous(counterpart: counterpart)
        }
        // Below the base, today's rules read it as a basic group of that magnitude.
        return magnitude > maxPlausibleBasicGroupId ? .rename(to: counterpart) : .ambiguous(counterpart: counterpart)
    }

    /// Applies the decisions to a whole snapshot. The input is not modified.
    public static func apply(to snapshot: KeyRing.Snapshot) -> (snapshot: KeyRing.Snapshot, report: Report) {
        let occupied = chatKeys(of: snapshot)
        var report = Report()
        var moves: [String: String] = [:]
        var quarantine = Set<String>()
        // Sorted so a run is reproducible and a report reads the same twice.
        for key in occupied.sorted() {
            switch decide(chatKey: key) {
            case .keep:
                continue
            case let .rename(target):
                guard !occupied.contains(target), !moves.values.contains(target) else {
                    // Two chats claiming one key means something is wrong, and the answer to that is to
                    // leave both readable rather than pick one.
                    report.conflicts.append(key)
                    continue
                }
                moves[key] = target
                report.renamed[key] = target
                // The entry has left `key`. If the bounds above read it wrong, the chat that really lives
                // there is now holding no key and no switch — the state the send path used to take for
                // "this chat never encrypted" — so mark it, on exactly the terms the ambiguous branch uses:
                // only an entry that carried encryption state could have been silently downgraded, and the
                // mark is dropped again the moment the user imports a key or sets the switch.
                if snapshot.chatEncryption[key] == true || snapshot.chatMasters[key] != nil {
                    quarantine.insert(key)
                }
            case let .ambiguous(counterpart):
                // Only an entry that carries encryption state can have been silently downgraded, and only
                // those are worth a mark. A key that is already in use answers for itself.
                guard snapshot.chatEncryption[key] == true || snapshot.chatMasters[key] != nil else { continue }
                guard !occupied.contains(counterpart) else { report.conflicts.append(key); continue }
                quarantine.insert(counterpart)
                report.ambiguous[key] = counterpart
            }
        }
        var out = snapshot
        out.chatMasters = rekey(snapshot.chatMasters, moves)
        out.chatKeyLabels = rekey(snapshot.chatKeyLabels, moves)
        out.chatEncryption = rekey(snapshot.chatEncryption, moves)
        out.chatAdminPks = rekey(snapshot.chatAdminPks, moves)
        out.chatAdminSks = rekey(snapshot.chatAdminSks, moves)
        out.memberPks = rekey(snapshot.memberPks, moves)
        out.memberEdPks = rekey(snapshot.memberEdPks, moves)
        out.chatPairings = rekey(snapshot.chatPairings, moves)
        out.chatRatchets = rekey(snapshot.chatRatchets, moves)
        out.chatKeySources = rekey(snapshot.chatKeySources, moves)
        out.groupOnlineInvites = rekey(snapshot.groupOnlineInvites, moves)
        out.encryptionLost = snapshot.encryptionLost.union(quarantine)
        return (out, report)
    }

    /// Every chat key the snapshot mentions anywhere.
    public static func chatKeys(of snapshot: KeyRing.Snapshot) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(snapshot.chatMasters.keys)
        keys.formUnion(snapshot.chatKeyLabels.keys)
        keys.formUnion(snapshot.chatEncryption.keys)
        keys.formUnion(snapshot.chatAdminPks.keys)
        keys.formUnion(snapshot.chatAdminSks.keys)
        keys.formUnion(snapshot.memberPks.keys)
        keys.formUnion(snapshot.memberEdPks.keys)
        keys.formUnion(snapshot.chatPairings.keys)
        keys.formUnion(snapshot.chatRatchets.keys)
        keys.formUnion(snapshot.chatKeySources.keys)
        keys.formUnion(snapshot.groupOnlineInvites.keys)
        return keys
    }

    private static func rekey<V>(_ map: [String: V], _ moves: [String: String]) -> [String: V] {
        guard !moves.isEmpty else { return map }
        var out = [String: V]()
        out.reserveCapacity(map.count)
        for (key, value) in map { out[moves[key] ?? key] = value }
        return out
    }
}
