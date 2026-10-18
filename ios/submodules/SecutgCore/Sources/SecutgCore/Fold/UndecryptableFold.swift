import Foundation

/// Which messages a folded timeline draws as one line, and which it leaves alone (PLAN.md 3.17 rule 5).
///
/// **Folding is not deleting.** Every message of a run is still there: the line says how many there are, and one
/// tap puts them back. A timeline that quietly dropped them would leave the reader not knowing somebody had
/// written to him at all, which is worse than a line saying so — and is exactly what an attacker who can make
/// decryption fail would want. So the count is load-bearing, a run never crosses a boundary that carries
/// information of its own, and nothing outside the message list consults this file: unread counts, the chat
/// list's dot and its preview line are computed from the stored messages and never see a fold.
///
/// The planning is a pure function over rows of five fields, with no message type, store, clock or view in
/// sight. That is what lets the boundary rules below be pinned down by `swift test`, and what makes this file
/// byte-identical on iOS and macOS — each client only has to answer, per message, the five questions `FoldRow`
/// asks. Ported from the client-agnostic half of Web A `src/secutg/ui/foldUndecryptable.ts`.

/// A run of one is never worth folding: "1 message cannot be decrypted" costs the same line as the explanation
/// it would replace and says less. Two is already a saving.
public let secutgMinFoldRun = 2

/// All the planner needs to know about a message. Ordered as the list renders them, oldest first.
public struct FoldRow: Equatable {
    /// `MessageId.Id`. A caller must not mix message namespaces in one array: ids are only comparable, and
    /// `lastId` only usable as a read watermark, inside one namespace.
    public let id: Int32
    /// Start of this message's day, from **the same function the client's date separator uses** — a day
    /// computed any other way would put a run's boundary somewhere other than where the separator is drawn.
    public let day: Int32
    /// nil for a message with no author (a channel post); two nils are the same author, as they are on screen.
    public let senderId: String?
    public let isOutgoing: Bool
    /// This message is a plain-text one that failed to open, so it may join a run. Every client answers this
    /// the same way (see `SecutgFoldable` in its own render layer): undecryptable, not `not_ready`, no media,
    /// not an action, not a member of an album or document group.
    public let isFoldable: Bool

    public init(id: Int32, day: Int32, senderId: String?, isOutgoing: Bool, isFoldable: Bool) {
        self.id = id
        self.day = day
        self.senderId = senderId
        self.isOutgoing = isOutgoing
        self.isFoldable = isFoldable
    }
}

public struct FoldedRun: Equatable {
    /// The oldest message of the run: the one kept in the list, drawn as the collapsed line.
    public let anchorId: Int32
    /// The newest message of the run. The collapsed line reports **this** as the id it stands for, so the read
    /// tracker marks the whole span read exactly as it does for an album — without this, folding the newest
    /// messages in a chat would leave them unread forever, which is the one way a *display* switch could reach
    /// the unread count that PLAN.md 3.17 rule 5 forbids it to touch.
    public let lastId: Int32
    /// What «{count} messages cannot be decrypted» says.
    public let count: Int
    /// Everything but the anchor: the messages the list does not draw while the run is folded.
    public let hiddenIds: [Int32]

    public init(anchorId: Int32, lastId: Int32, count: Int, hiddenIds: [Int32]) {
        self.anchorId = anchorId
        self.lastId = lastId
        self.count = count
        self.hiddenIds = hiddenIds
    }
}

/// What ends a run. Every one of these is something the reader would otherwise lose, so the rule is the same in
/// each case: fold away the noise, never the landmark.
///
/// - **a different day** — the date separator is how someone finds "the evening of the 3rd"; a run that
///   straddled one would have to either swallow the separator or be drawn on both sides of it.
/// - **a different sender** — "who has been writing to me that I cannot read" is the question the reader is most
///   likely to have, and in the list itself a run is drawn inside one sender's group, under that sender's name
///   and avatar. Merging across senders would put one person's name over another person's messages.
/// - **incoming vs. outgoing** — the two sides sit in different bubble columns, and our own unreadable message
///   means something different (usually a key this device lost) from someone else's.
/// - **the unread divider** — the message it is drawn above starts a new run, so the divider is never one of the
///   messages a fold takes off the screen: losing it would hide the boundary between what the reader has seen
///   and what he has not, which is precisely "letting the user miss messages".
///
/// **Deliberately not here: a gap in time.** Breaking a run at, say, ten minutes would cut one long stretch into
/// a pile of one- and two-message fragments, each drawn as its own line — more lines than the explanations they
/// replaced, and the saving gone. Silence between two unreadable messages also tells the reader nothing he can
/// use: he cannot read either of them.
///
/// A message that is not foldable at all (readable, media, an action, still decrypting) ends a run too; that is
/// handled in the loop rather than here, because it also must not join the next one.
private func startsNewRun(_ previous: FoldRow, _ row: FoldRow, _ firstUnreadId: Int32?) -> Bool {
    return row.id == firstUnreadId
        || row.day != previous.day
        || row.senderId != previous.senderId
        || row.isOutgoing != previous.isOutgoing
}

/// The runs a folded timeline draws as one line each, oldest first.
///
/// - Parameters:
///   - rows: the messages as the list renders them, oldest first.
///   - firstUnreadId: the message the "unread messages" divider is drawn above, if any. It starts a new run.
///   - expandedAnchorIds: anchors the reader has tapped open. An expanded run is planned away entirely rather
///     than marked, so everything downstream sees the ordinary, unfolded timeline for it and there is no second
///     notion of "folded but showing" for anyone to get wrong. Session-only: nothing here is ever written down.
public func planUndecryptableFold(
    _ rows: [FoldRow],
    firstUnreadId: Int32? = nil,
    expandedAnchorIds: Set<Int32> = []
) -> [FoldedRun] {
    var runs: [FoldedRun] = []
    var current: [FoldRow] = []

    func flush() {
        let run = current
        current = []
        guard run.count >= secutgMinFoldRun, let anchor = run.first else { return }
        guard !expandedAnchorIds.contains(anchor.id) else { return }
        let ids = run.map { $0.id }
        runs.append(FoldedRun(
            anchorId: anchor.id,
            // Taken as a maximum rather than as "the last one", because render order is not always id order —
            // service notifications and scheduled messages carry local ids — and what this value is for is a
            // read watermark, which is only ever safe when it is the largest id of the run.
            lastId: ids.max() ?? anchor.id,
            count: run.count,
            hiddenIds: Array(ids.dropFirst())
        ))
    }

    for row in rows {
        guard row.isFoldable else {
            flush()
            continue
        }
        if let previous = current.last, startsNewRun(previous, row, firstUnreadId) { flush() }
        current.append(row)
    }
    flush()

    return runs
}
