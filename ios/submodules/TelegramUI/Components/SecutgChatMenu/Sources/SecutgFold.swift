import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import SecutgCore

/// SECUTG (PLAN.md 3.17 rule 5): folding runs of messages this device cannot open.
///
/// Three things live here. The decision — *which* messages form a run and where a run has to break — is not one
/// of them: that is `planUndecryptableFold` in SecutgCore, pure, under `swift test`, and byte-identical to
/// macOS. What is here is everything that decision needs from this client and cannot be tested without it.
///
/// - **the switch**, read from and written to `SecutgLocalPrefs` (PLAN.md 3.24.8's backend, per account, not the
///   keyring — it is a preference about how a list is drawn, not key material);
/// - **which runs the reader has opened**, per chat and for this app run only. It is deliberately not written
///   down: "I opened this run" is not a decision, it is where the user is standing right now;
/// - **a revision promise** the chat history subscribes to, because flipping the switch or opening a run changes
///   nothing the message list otherwise watches. Bumping it re-runs the entry builder, and the ordinary list
///   merge then inserts, updates *and removes* rows — a local redraw could only ever do the middle one, and
///   opening a run has to make the hidden messages actually come back.
public final class SecutgFoldState {
    public static let shared = SecutgFoldState()

    private let lock = NSLock()
    private var expandedAnchors: [PeerId: Set<Int32>] = [:]
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)

    private init() {
    }

    public var revision: Signal<Int32, NoError> {
        return self.revisionPromise.get()
    }

    public func invalidate() {
        self.lock.lock()
        self.counter &+= 1
        let value = self.counter
        self.lock.unlock()
        self.revisionPromise.set(value)
    }

    public func isEnabled(accountPeerId: PeerId) -> Bool {
        return SecutgLocalPrefs.foldsUndecryptable(accountKey: SecutgLocalPrefs.accountKey(accountPeerId))
    }

    /// Turning the switch off forgets which runs were open, because there are no runs any more; turning it on
    /// starts from everything folded, which is what the reader just asked for.
    public func setEnabled(_ isEnabled: Bool, accountPeerId: PeerId) {
        SecutgLocalPrefs.setFoldsUndecryptable(isEnabled, accountKey: SecutgLocalPrefs.accountKey(accountPeerId))
        self.lock.lock()
        self.expandedAnchors.removeAll()
        self.lock.unlock()
        self.invalidate()
    }

    public func expandedAnchors(peerId: PeerId) -> Set<Int32> {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.expandedAnchors[peerId] ?? []
    }

    public func expand(peerId: PeerId, anchorId: Int32) {
        self.lock.lock()
        self.expandedAnchors[peerId, default: []].insert(anchorId)
        self.lock.unlock()
        self.invalidate()
    }
}

/// What a folded run is drawn as (PLAN.md 3.17 rule 5).
///
/// **The count is the whole point of the line.** Folding is only acceptable because this still says how many
/// messages are behind it: a timeline that simply left them out would let somebody write to the reader without
/// the reader ever learning of it, which is both worse than the noise it saves and precisely the outcome an
/// attacker who can break decryption is after.
///
/// Drawn by the run's oldest message, which stays in the list and keeps its own id, date, sender and — rule 2 —
/// its ciphertext, untouched underneath. So a tap needs no new plumbing: it is an ordinary message bubble, and
/// the bubble's own tap handler asks `SecutgFoldState` to open the run.
public enum SecutgCollapsedLine {
    /// Bold over the whole line, for the same reason the "no key on this device" line ends in a bold action: it
    /// is the only mark in a text bubble that says "this does something when you tap it".
    public static func line(count: Int) -> (text: String, entities: [MessageTextEntity]) {
        let text = SecutgL10n.string("SecutgCollapsedUndecryptable", ["count": "\(count)"])
        return (text, [MessageTextEntity(range: 0..<text.utf16.count, type: .Bold)])
    }
}

/// Turning this client's messages into the rows `planUndecryptableFold` understands, and its answer back into
/// something the entry builder can apply.
public enum SecutgFoldPlan {
    /// One folded run, as the message list needs it.
    public struct Run {
        public let count: Int
        /// The newest message of the run. The collapsed row reports this as the id it stands for, so the read
        /// tracker marks the whole span read exactly as it does for an album — without it, folding the newest
        /// messages in a chat would leave them unread forever, which is the one way this *display* switch could
        /// reach the unread count rule 5 forbids it to touch.
        public let lastIndex: MessageIndex
    }

    public struct Plan {
        /// Messages the list does not draw while their run is folded. Never removed from anything but the list.
        public let hidden: Set<MessageId>
        /// Anchor id → what its collapsed line says and stands for.
        public let runs: [MessageId: Run]

        public var isEmpty: Bool { return self.runs.isEmpty }
    }

    public static let empty = Plan(hidden: [], runs: [:])

    /// Whether one message may join a run.
    ///
    /// Only `.undecryptable`: a message stored sealed by PLAN.md 3.19 normally opens, and asking whether this
    /// particular one still does would mean an AEAD decryption per message while the list is being assembled.
    /// The four exclusions below each protect something the reader would otherwise lose outright.
    public static func isFoldable(message: Message) -> Bool {
        guard let meta = message.secutgMeta, meta.kind == .undecryptable else { return false }
        // The keyring is still loading — a line that is about to change by itself. Folding it would flash a count
        // on screen and then take it away again.
        guard SecutgUndecryptableLine.situation(detail: meta.detail) != .loading else { return false }
        // Media or an action would be hidden along with the text. An album or document group is drawn as one
        // block, and taking a member out from underneath it would leave that block describing messages that are
        // no longer there.
        guard message.media.isEmpty, message.groupingKey == nil, !message.text.isEmpty else { return false }
        // Ids are only comparable — and `lastIndex` only usable as a read watermark — inside one namespace.
        // Nothing this device failed to decrypt is anything but a received cloud message anyway.
        return message.id.namespace == Namespaces.Message.Cloud
    }

    /// - Parameters:
    ///   - messages: the chat's messages, oldest first, exactly as the list will render them.
    ///   - dayId: the day boundary **the date separator itself uses**. Passed in rather than computed here so
    ///     the two can never drift apart: a run that broke on a different day than the separator would either
    ///     swallow the separator or be drawn on both sides of it.
    ///   - firstUnreadId: the message the "unread messages" divider is drawn above, or nil when there is none.
    public static func make(
        messages: [Message],
        accountPeerId: PeerId,
        dayId: (Int32) -> Int32,
        firstUnreadId: MessageId?,
        expandedAnchorIds: Set<Int32>
    ) -> Plan {
        var rows: [FoldRow] = []
        var indexById: [Int32: MessageIndex] = [:]
        rows.reserveCapacity(messages.count)
        for message in messages {
            rows.append(FoldRow(
                id: message.id.id,
                day: dayId(message.timestamp),
                senderId: message.author?.id.toInt64().description,
                isOutgoing: !message.effectivelyIncoming(accountPeerId),
                isFoldable: isFoldable(message: message)
            ))
            indexById[message.id.id] = message.index
        }

        let planned = planUndecryptableFold(rows, firstUnreadId: firstUnreadId?.id, expandedAnchorIds: expandedAnchorIds)
        guard !planned.isEmpty, let peerId = messages.first?.id.peerId else { return empty }

        var hidden = Set<MessageId>()
        var runs: [MessageId: Run] = [:]
        for run in planned {
            // A run whose newest message we cannot locate is dropped rather than folded with a guessed
            // watermark: leaving the noise on screen costs the reader a few lines, reporting the wrong id as
            // read costs him a message.
            guard let lastIndex = indexById[run.lastId] else { continue }
            for id in run.hiddenIds {
                hidden.insert(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id))
            }
            runs[MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: run.anchorId)] =
                Run(count: run.count, lastIndex: lastIndex)
        }
        return Plan(hidden: hidden, runs: runs)
    }
}
