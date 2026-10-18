import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG (PLAN.md 3.23): the part of the stranger notice that is neither the decision (that is
/// `SecutgCore.StrangerNotice`, pure and under test) nor the drawing (`SecutgStrangerNoticeItem`) —
/// the live state the block reads, and what its two buttons do.
///
/// Two things live here and nowhere else:
///
/// - **a revision promise** the chat history subscribes to. Tapping [Check] or [No need] changes
///   nothing the message list watches, so without this the row would keep asking its question until
///   a message happened to arrive. Bumping it re-runs the entry builder, and the ordinary list merge
///   then inserts, updates or removes the row — including removing it, which a local redraw could
///   not do.
/// - **the reads and writes of the answer**, so the one place that knows the storage key is
///   `SecutgLocalPrefs` and the one place that knows what the three answers mean is `SecutgCore`.
public final class SecutgStrangerNoticeState {
    public static let shared = SecutgStrangerNoticeState()

    private let lock = NSLock()
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)

    private init() {
    }

    /// Bumped whenever anything the block draws from changes locally. `ChatHistoryListNode` folds this
    /// into the signal that rebuilds its entries.
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
}

/// The block's view of the world: what to say in this chat right now, and what each button does.
public enum SecutgStrangerNoticeHost {
    /// What the block should say in this chat right now. `.hidden` means it should not be there at all.
    ///
    /// Every input comes from somewhere that already owns it — whether this is a one-to-one chat from
    /// `SecutgAccountRuntime.status`, the rest from the peer view the entries are built from — and the
    /// decision is made by `StrangerNotice.evaluate`. The same answer is then handed to
    /// `SecutgOnboardCardHost.shape` as its `isStrangerNoticeVisible`, so the two blocks that share this
    /// slot cannot disagree about whether this one is up (PLAN.md 3.24.3 rule 2).
    public static func notice(
        context: AccountContext,
        peerId: PeerId,
        isBot: Bool,
        isContact: Bool,
        hasRepliedTo: Bool,
        commonChats: Int?
    ) -> StrangerNotice.Notice {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return .hidden }
        return StrangerNotice.evaluate(StrangerNotice.Input(
            isPrivateChat: runtime.status(chatPeerId: peerId).isPrivateChat,
            isContact: isContact,
            isBot: isBot,
            hasRepliedTo: hasRepliedTo,
            decision: decision(context: context, peerId: peerId),
            commonChats: commonChats
        ))
    }

    public static func decision(context: AccountContext, peerId: PeerId) -> StrangerNotice.Decision {
        return SecutgLocalPrefs.strangerDecision(accountKey: SecutgLocalPrefs.accountKey(context.account.peerId),
                                                 userId: "\(peerId.toInt64())")
    }

    private static func setDecision(_ decision: StrangerNotice.Decision, context: AccountContext, peerId: PeerId) {
        SecutgLocalPrefs.setStrangerDecision(decision, accountKey: SecutgLocalPrefs.accountKey(context.account.peerId),
                                             userId: "\(peerId.toInt64())")
        SecutgStrangerNoticeState.shared.invalidate()
    }

    // MARK: what the buttons do (PLAN.md 3.23.3)

    public enum Action: Equatable {
        /// Remembered as `.checked`, per person and per account, so nobody is asked twice about the same
        /// account and the answer survives closing the chat (PLAN.md 3.23.3).
        case check
        /// "No need". Remembered the same way, and this person is never asked about again.
        case skip
    }

    public static func perform(_ action: Action, context: AccountContext, peerId: PeerId) {
        switch action {
        case .check:
            setDecision(.checked, context: context, peerId: peerId)
            // PLAN.md 3.23.1 rule 1 / 3.23.6: **this tap is the only thing that ever asks**. Nothing about
            // this account is looked up before it — not on opening the chat, not on drawing the question.
            //
            // The count itself is a field of the full user record, which is why there is no separate
            // "common groups" call here: asking for that record is asking for the count. It is normally
            // already on the device by the time the question is answered, in which case this refresh
            // changes nothing; when it is not — a cold chat, a bad connection — this is what fetches it,
            // and `StrangerNotice` says `checking` until it lands rather than showing a zero that only
            // means "not loaded" (3.23.4).
            context.account.viewTracker.forceUpdateCachedPeerData(peerId: peerId)
        case .skip:
            setDecision(.declined, context: context, peerId: peerId)
            // PLAN.md 3.23.7 rule 4: 「不用」 clears a re-arm mark too. 「检查」 keeps it — with the mark gone the
            // ordinary rule hides an old conversation's block at once, and the answer just asked for would never
            // be read; it goes away with the next message sent, exactly as 3.23.3's own result does.
            SecutgStrangerRearm.clearMark(context: context, peerId: peerId)
        }
    }
}

/// SECUTG (PLAN.md 3.23.3): has this account ever written in this chat — i.e. is this still a new
/// conversation? The answer is the only reason the 3.23 block ever goes away, so it is assembled from
/// both signals the history view can offer and handed to `StrangerNotice.hasEverWritten`, which owns the
/// rule and is unit-tested byte-identically with macOS.
///
/// Kept here rather than in the entry builder so the one place that knows how to read a Postbox read
/// state is also the one place that knows what the answer is for.
public func secutgHasEverWritten(view: MessageHistoryView, accountPeerId: PeerId, peerId: PeerId) -> Bool {
    let hasLoadedOutgoingMessage = view.entries.contains(where: { !$0.message.effectivelyIncoming(accountPeerId) })
    return StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: hasLoadedOutgoingMessage,
                                         maxOutgoingReadId: secutgMaxOutgoingReadId(view: view, peerId: peerId))
}

/// The highest outgoing message id the peer has read in this chat, or nil when no read state is known.
///
/// This is the half of the test above that does not move with the scroll position: the read state
/// describes the whole conversation, so a non-zero value still says "you wrote here" while the loaded
/// window holds nothing but the other side talking. `fixedReadStates` is the one the history view was
/// opened with; `transientReadStates` is consulted only as a fallback, since either answering yes is
/// enough.
///
/// nil means **no evidence**, never "has replied" — see `hasEverWritten` on why that direction matters.
private func secutgMaxOutgoingReadId(view: MessageHistoryView, peerId: PeerId) -> Int32? {
    func maxOutgoing(_ readStates: MessageHistoryViewReadState?) -> Int32? {
        guard case let .peer(states)? = readStates, let combined = states[peerId] else {
            return nil
        }
        var result: Int32?
        for (_, state) in combined.states {
            let value: Int32
            switch state {
            case let .idBased(_, maxOutgoingReadId, _, _, _):
                value = maxOutgoingReadId
            case let .indexBased(_, maxOutgoingReadIndex, _, _):
                value = maxOutgoingReadIndex.id.id
            }
            result = max(result ?? 0, value)
        }
        return result
    }
    if let value = maxOutgoing(view.fixedReadStates), value > 0 {
        return value
    }
    return maxOutgoing(view.transientReadStates)
}

// MARK: - re-arming after a contact is removed (PLAN.md 3.23.7)

/// SECUTG (PLAN.md 3.23.7): taking somebody out of the contacts list re-arms the 3.23 block for that chat.
///
/// The rule is `SecutgCore.StrangerRearm` (pure, under test, byte-identical with macOS); what lives here is what
/// only this client can do — observe the peer's contact state, read the boundary out of Postbox, keep the two
/// records (`SecutgLocalPrefs`) and place the block in the loaded window.
///
/// Two observation points, one baseline (rule 1): the account-wide contacts list (`install`), which catches a
/// removal synced from another device while the chat is closed, and the chat itself (`observe`), on open and on
/// every peer update its history view carries. They share the baseline under one lock, so whichever sees the
/// change first arms the chat and the other finds nothing left to do.
///
/// What clears the mark (rule 4): 「不用」 (`SecutgStrangerNoticeHost.perform`), a send from this device
/// (`noteUserSent`, from the two send funnels), this account having written after the boundary by any road the
/// read state or the loaded window can prove (`placement`), and the person coming back (`observe`). Nothing here
/// syncs to another device and nothing goes on the wire.
public enum SecutgStrangerRearm {
    /// Serialises the baseline's read-modify-write between the two observation points, which run on different
    /// queues (the contacts view on the main queue, the entry builder on the history queue).
    private static let lock = NSLock()
    /// One live listener per account. Main queue only.
    private static var listeners: [PeerId: Disposable] = [:]

    private static func userId(_ peerId: PeerId) -> String {
        return "\(peerId.toInt64())"
    }

    // MARK: the account-wide observation point

    /// Installed once per account (`AccountContext` init, like `SecutgKeysChanged.install`). The first emission
    /// after an upgrade only records the baseline: a removal this device never witnessed must not arm a chat out
    /// of nowhere.
    public static func install(context: AccountContext) {
        let accountPeerId = context.account.peerId
        let postbox = context.account.postbox
        listeners.removeValue(forKey: accountPeerId)?.dispose()
        listeners[accountPeerId] = (postbox.contactPeerIdsView()
        |> deliverOnMainQueue).start(next: { view in
            observeContacts(postbox: postbox, accountPeerId: accountPeerId, contacts: view.peerIds)
        })
    }

    private static func observeContacts(postbox: Postbox, accountPeerId: PeerId, contacts: Set<PeerId>) {
        let accountKey = SecutgLocalPrefs.accountKey(accountPeerId)
        let next = Set(contacts.filter { $0.namespace == Namespaces.Peer.CloudUser }.map { $0.toInt64() })
        lock.lock()
        guard let previous = SecutgLocalPrefs.strangerLastSeenContacts(accountKey: accountKey) else {
            if !next.isEmpty {
                SecutgLocalPrefs.setStrangerLastSeenContacts(next, accountKey: accountKey)
            }
            lock.unlock()
            return
        }
        // An empty list against a non-empty baseline is a list that has not loaded yet — a fresh login, a cold
        // start before the contacts sync — not a user who deleted everybody at once. Skipped, baseline kept: arming
        // every chat on the device would be exactly the 「逢人就喊狼来了」 3.23.5 forbids.
        if next.isEmpty && !previous.isEmpty {
            lock.unlock()
            return
        }
        var toArm: [Int64] = []
        var toDisarm: [Int64] = []
        for peer in previous.symmetricDifference(next) {
            let isMarked = SecutgLocalPrefs.strangerRearmBoundary(accountKey: accountKey, userId: "\(peer)") != nil
            switch StrangerRearm.observe(wasContact: previous.contains(peer), isContact: next.contains(peer), isMarked: isMarked) {
            case .arm:
                toArm.append(peer)
            case .disarm:
                toDisarm.append(peer)
            case .none:
                break
            }
        }
        SecutgLocalPrefs.setStrangerLastSeenContacts(next, accountKey: accountKey)
        lock.unlock()
        for peer in toDisarm {
            SecutgLocalPrefs.setStrangerRearmBoundary(nil, accountKey: accountKey, userId: "\(peer)")
        }
        if !toDisarm.isEmpty {
            SecutgStrangerNoticeState.shared.invalidate()
        }
        guard !toArm.isEmpty else { return }
        // The boundary is the largest message id known in the chat at this moment (rule 2) — Postbox's own top
        // index, not whatever window happens to be loaded — read for every armed chat in one transaction.
        let _ = (postbox.transaction { transaction -> [(Int64, Int32)] in
            return toArm.map { peer -> (Int64, Int32) in
                return (peer, transaction.getTopPeerMessageIndex(peerId: PeerId(peer), namespace: Namespaces.Message.Cloud)?.id.id ?? 0)
            }
        }
        |> deliverOnMainQueue).startStandalone(next: { boundaries in
            for (peer, boundary) in boundaries {
                arm(accountKey: accountKey, userId: "\(peer)", boundary: boundary)
            }
            SecutgStrangerNoticeState.shared.invalidate()
        })
    }

    // MARK: the chat's own observation point

    /// Called where the chat's entries are built, on open and on every peer update (rule 1). Same rule, same
    /// records. Invalidates nothing: the rebuild this runs inside is already about to draw the answer.
    public static func observe(context: AccountContext, peerId: PeerId, isContact: Bool, topMessageId: Int32) {
        let accountKey = SecutgLocalPrefs.accountKey(context.account.peerId)
        let peer = peerId.toInt64()
        lock.lock()
        // No baseline yet means the account-wide observer has not seen the contacts list once. It records the
        // baseline; a single chat must not stand in for the whole list.
        guard var baseline = SecutgLocalPrefs.strangerLastSeenContacts(accountKey: accountKey) else {
            lock.unlock()
            return
        }
        let wasContact = baseline.contains(peer)
        let isMarked = SecutgLocalPrefs.strangerRearmBoundary(accountKey: accountKey, userId: userId(peerId)) != nil
        let change = StrangerRearm.observe(wasContact: wasContact, isContact: isContact, isMarked: isMarked)
        if wasContact != isContact {
            if isContact {
                baseline.insert(peer)
            } else {
                baseline.remove(peer)
            }
            SecutgLocalPrefs.setStrangerLastSeenContacts(baseline, accountKey: accountKey)
        }
        lock.unlock()
        switch change {
        case .arm:
            arm(accountKey: accountKey, userId: userId(peerId), boundary: topMessageId)
        case .disarm:
            SecutgLocalPrefs.setStrangerRearmBoundary(nil, accountKey: accountKey, userId: userId(peerId))
        case .none:
            break
        }
    }

    /// Rule 2: the peer's decisions go — the 「不用」 memory and the 「检查」 result alike — and the mark is set.
    private static func arm(accountKey: String, userId: String, boundary: Int32) {
        SecutgLocalPrefs.clearStrangerDecision(accountKey: accountKey, userId: userId)
        SecutgLocalPrefs.setStrangerRearmBoundary(boundary, accountKey: accountKey, userId: userId)
    }

    // MARK: the mark

    public static func boundary(context: AccountContext, peerId: PeerId) -> Int32? {
        return SecutgLocalPrefs.strangerRearmBoundary(accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), userId: userId(peerId))
    }

    public static func clearMark(context: AccountContext, peerId: PeerId) {
        SecutgLocalPrefs.setStrangerRearmBoundary(nil, accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), userId: userId(peerId))
    }

    /// Rule 4: a message sent from this device in the chat. Called from the send funnels before anything is
    /// enqueued — the one signal that never has to wait for the peer to read (`StrangerRearm.hasWrittenAfterBoundary`).
    public static func noteUserSent(context: AccountContext, peerId: PeerId) {
        guard peerId.namespace == Namespaces.Peer.CloudUser, boundary(context: context, peerId: peerId) != nil else { return }
        clearMark(context: context, peerId: peerId)
        SecutgStrangerNoticeState.shared.invalidate()
    }

    /// Where the block goes in this chat (rows 2–4 / 6 of the 3.23.7 table), from the loaded window and the read
    /// state. Clears the mark itself when this account has provably written after the boundary (row 4), so the
    /// ordinary rule applies from the next rebuild on. Only the cloud namespace is read: a local, not-yet-sent
    /// message has an id from another space.
    public static func placement(context: AccountContext, peerId: PeerId, view: MessageHistoryView) -> StrangerRearm.Placement {
        guard let boundary = boundary(context: context, peerId: peerId) else { return .ordinaryRule }
        let accountPeerId = context.account.peerId
        let messages = view.entries.compactMap { entry -> StrangerRearm.Message? in
            guard entry.message.id.namespace == Namespaces.Message.Cloud else { return nil }
            return StrangerRearm.Message(id: entry.message.id.id, isIncoming: entry.message.effectivelyIncoming(accountPeerId))
        }
        let placement = StrangerRearm.placement(
            boundary: boundary,
            firstIncomingIdAfterBoundary: StrangerRearm.firstIncomingId(afterBoundary: boundary, in: messages),
            hasWrittenAfterBoundary: StrangerRearm.hasWrittenAfterBoundary(
                boundary: boundary,
                maxOutgoingReadId: secutgMaxOutgoingReadId(view: view, peerId: peerId),
                maxKnownOutgoingId: StrangerRearm.maxOutgoingId(in: messages)
            )
        )
        if case .clearMark = placement {
            clearMark(context: context, peerId: peerId)
        }
        return placement
    }
}

/// SECUTG (PLAN.md 3.23.7 rule 2): the largest message id known in this chat right now, as the chat's own
/// observation point records the boundary — the read state's `maxKnownId`, which describes the whole conversation,
/// the newest loaded message when there is no read state, or 0 for a chat with nothing in it.
public func secutgTopMessageId(view: MessageHistoryView, peerId: PeerId) -> Int32 {
    var top = view.entries.lazy.filter { $0.message.id.namespace == Namespaces.Message.Cloud }.map { $0.message.id.id }.max() ?? 0
    for readStates in [view.fixedReadStates, view.transientReadStates] {
        guard case let .peer(states)? = readStates, let combined = states[peerId] else { continue }
        for (_, state) in combined.states {
            if case let .idBased(_, _, maxKnownId, _, _) = state {
                top = max(top, maxKnownId)
            }
        }
    }
    return top
}
