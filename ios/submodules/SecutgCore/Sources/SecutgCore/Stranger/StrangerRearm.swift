import Foundation

/// PLAN.md 3.23.7: taking somebody out of the contacts list re-arms the 3.23 stranger notice for that chat.
///
/// 3.23.3's only gate is "this account has never written in this chat", which is right for a stranger's opening
/// line and permanently shut for somebody you have talked to for years. Deleting that person from the contacts
/// list is the user saying "my judgement about this person has changed", so it resets the 3.23 decision once:
/// the peer's decisions are cleared, the chat is *marked*, the boundary is the largest message id known at that
/// moment, and the notice is drawn before the peer's first message after the boundary — not before the
/// historical first message, which nobody is going to scroll three years back to find.
///
/// Pure, like `StrangerNotice`: every input is a fact the caller already holds, so the whole table is testable
/// without a store and iOS and macOS share it byte for byte. The persisted pieces — the peer's last seen contact
/// state, the mark and its boundary — live where the 3.23 decisions live on each client; this file only decides.
/// Nothing here syncs to another device and nothing goes on the wire: every device observes the removal on its
/// own and arms on its own (3.23.7 「不做」).
public enum StrangerRearm {
    /// What observing the peer's contact state means for the mark (rows 1 and 5 of the 3.23.7 table).
    public enum ContactChange: Equatable {
        case none
        /// 是 → 否: clear the peer's 3.23 decisions, mark the chat and record the boundary.
        case arm
        /// 否 → 是 with a mark on the chat: clear the mark and show nothing — coming back is not an event.
        case disarm
    }

    /// - Parameters:
    ///   - wasContact: the state this client last recorded for the peer. False when it never recorded one: a
    ///     person never seen as a contact cannot have been removed, so the first observation only takes note.
    ///   - isContact: the state observed now (`TelegramUser.flags.contains(.isContact)` on the Apple clients).
    ///   - isMarked: whether the chat carries a mark right now.
    public static func observe(wasContact: Bool, isContact: Bool, isMarked: Bool) -> ContactChange {
        if wasContact && !isContact { return .arm }
        // A contact with a mark on the chat is a mark that has outlived its reason, whichever way it got there
        // — the person came back while this app was running, or while it was not.
        if isContact && isMarked { return .disarm }
        return .none
    }

    /// Where the 3.23 block goes in a chat (rows 2–4 and 6 of the 3.23.7 table).
    public enum Placement: Equatable {
        /// No mark: 3.23.3's ordinary rule decides, at the top of the history.
        case ordinaryRule
        /// Marked, and the peer has not written since the boundary: draw nothing yet (等对方来信).
        case waiting
        /// Marked and the peer has written: draw the block right before this message, wording and buttons
        /// exactly as 3.23.3.
        case beforeMessage(id: Int32)
        /// This account wrote after the boundary — the judgement was made. Clear the mark and draw nothing; the
        /// ordinary rule applies from here on.
        case clearMark
    }

    /// - Parameters:
    ///   - boundary: the mark's boundary, or nil when the chat is not marked
    ///   - firstIncomingIdAfterBoundary: the peer's first message above the boundary, when one is known
    ///     (`firstIncomingId(afterBoundary:in:)`)
    ///   - hasWrittenAfterBoundary: whether this account sent anything after the boundary
    ///     (`hasWrittenAfterBoundary(boundary:maxOutgoingReadId:maxKnownOutgoingId:)`)
    public static func placement(boundary: Int32?, firstIncomingIdAfterBoundary: Int32?, hasWrittenAfterBoundary: Bool) -> Placement {
        guard boundary != nil else { return .ordinaryRule }
        if hasWrittenAfterBoundary { return .clearMark }
        guard let id = firstIncomingIdAfterBoundary else { return .waiting }
        return .beforeMessage(id: id)
    }

    /// Has this account written in the chat after the boundary — the 「本人边界后发过」 column.
    ///
    /// Both inputs are **positive** evidence and either one suffices. The outgoing read watermark is a property
    /// of the whole conversation and does not move with the loaded window (it lags until the peer reads, which is
    /// why it cannot be the only input). `maxKnownOutgoingId` is the newest message of this account's own that the
    /// client knows of — the id of a send this device just made, or of an outgoing message that happens to be
    /// loaded. Neither is ever read as *negative* evidence: a loaded window holding none of this account's
    /// messages says nothing about whether it wrote (PLAN.md 3.23.3), so "not written" is only ever the absence of
    /// both, and a client that also clears the mark at its own send hook has already answered the common case.
    public static func hasWrittenAfterBoundary(boundary: Int32, maxOutgoingReadId: Int32?, maxKnownOutgoingId: Int32?) -> Bool {
        if let maxOutgoingReadId = maxOutgoingReadId, maxOutgoingReadId > boundary { return true }
        if let maxKnownOutgoingId = maxKnownOutgoingId, maxKnownOutgoingId > boundary { return true }
        return false
    }

    /// One loaded message, reduced to the two facts this file reads.
    public struct Message: Equatable {
        public let id: Int32
        public let isIncoming: Bool

        public init(id: Int32, isIncoming: Bool) {
            self.id = id
            self.isIncoming = isIncoming
        }
    }

    /// The peer's first message above the boundary among the loaded ones, in any order; nil when none is loaded.
    public static func firstIncomingId(afterBoundary boundary: Int32, in messages: [Message]) -> Int32? {
        return messages.lazy.filter { $0.isIncoming && $0.id > boundary }.map { $0.id }.min()
    }

    /// The newest message of this account's own among the loaded ones, or nil when none is loaded — which is no
    /// evidence, never "has not written" (see `hasWrittenAfterBoundary`).
    public static func maxOutgoingId(in messages: [Message]) -> Int32? {
        return messages.lazy.filter { !$0.isIncoming }.map { $0.id }.max()
    }
}
