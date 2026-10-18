import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG (PLAN.md 3.24): the part of the encryption guide that is neither the decision (that is
/// `SecutgCore.OnboardCard`, pure and under test) nor the drawing (`SecutgOnboardCardItem`) — the
/// live state the card reads, and the way a tap on it reaches the chat menu's action table.
///
/// Three things live here and nowhere else:
///
/// - **the expanded flag**, which is per chat and per app run only. It is not written down: "I opened
///   the two roads" is not a decision, it is where the user is standing right now.
/// - **a revision promise** the chat history subscribes to. Tapping a button changes nothing the
///   message list watches, so without this the card would keep drawing its old shape until a message
///   happened to arrive. Bumping it re-runs the entry builder, and the ordinary list merge then
///   inserts, updates or removes the row — including removing it, which a local redraw could not do.
/// - **the reads and writes of the "not now" memory**, so the one place that knows the storage key is
///   `SecutgLocalPrefs` and the one place that knows the counting rule is `SecutgCore.OnboardMemory`.
public final class SecutgOnboardCardState {
    public static let shared = SecutgOnboardCardState()

    private let lock = NSLock()
    private var openedChats = Set<PeerId>()
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)

    private init() {
    }

    /// Bumped whenever anything the card draws from changes locally. `ChatHistoryListNode` folds this
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

    public func isOpened(peerId: PeerId) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.openedChats.contains(peerId)
    }

    public func setOpened(_ opened: Bool, peerId: PeerId) {
        self.lock.lock()
        if opened {
            self.openedChats.insert(peerId)
        } else {
            self.openedChats.remove(peerId)
        }
        self.lock.unlock()
        self.invalidate()
    }

    /// Called when a chat is opened, so the guide starts collapsed again — the Web port gets this for
    /// free because its card is a component that remounts per chat (PLAN.md 3.24.4: two clicks and a
    /// confirmation, counted from the state the user actually finds the card in).
    public func resetExpansion(peerId: PeerId) {
        self.lock.lock()
        let changed = self.openedChats.remove(peerId) != nil
        self.lock.unlock()
        if changed {
            self.invalidate()
        }
    }
}

/// The card's view of the world: what shape to draw, and what each button does.
public enum SecutgOnboardCardHost {
    /// Telegram's own service account (PLAN.md 3.24.1 rule 2).
    private static let serviceAccountId: Int64 = 777000

    /// What the card should draw in this chat right now, or nil when it should not be there at all.
    ///
    /// Every substantive input comes from somewhere that already owns it — the pairing state and the
    /// key from `SecutgAccountRuntime.status`, the ignore count from `SecutgLocalPrefs`, and whether the
    /// 3.23 stranger block is up from the caller, which got it from `SecutgStrangerNoticeHost.notice`
    /// while building the very row that draws it. The decision is then made by `OnboardCard.evaluate`.
    /// Nothing is re-derived here, which is the only way the card and the things it shares a screen with
    /// cannot end up disagreeing (PLAN.md 3.24.3 rule 2).
    ///
    /// `isStrangerNoticeVisible` is passed in rather than worked out here on purpose: 3.23's answer now
    /// has a renderer, and one evaluation per rebuild is what makes "the guide collapses while the
    /// stranger block is up" a fact rather than two pieces of code agreeing by luck.
    public static func shape(
        context: AccountContext,
        peerId: PeerId,
        isBot: Bool,
        isStrangerNoticeVisible: Bool
    ) -> (form: OnboardCard.Form, isCompact: Bool, isOpened: Bool)? {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return nil }
        let status = runtime.status(chatPeerId: peerId)

        let shape = OnboardCard.evaluate(OnboardCard.Input(
            isPrivateChat: status.isPrivateChat,
            isBot: isBot,
            isServiceAccount: peerId.namespace == Namespaces.Peer.CloudUser && peerId.id._internalGetInt64Value() == serviceAccountId,
            hasKey: status.hasKey,
            pairingState: status.pairingState.flatMap(KeyRing.Pairing.State.init(rawValue:)),
            hasPeerKey: status.hasIncomingInvite,
            startedAt: status.pairingStartedAt,
            nowSeconds: Int64(Date().timeIntervalSince1970),
            memory: memory(context: context, peerId: peerId),
            isStrangerNoticeVisible: isStrangerNoticeVisible
            // `isHandoffNoticeVisible` is deliberately left at false: PLAN.md 3.25.5.3's take-over notice
            // is a dialog on this client (`SecutgHandoffDialogs`), not a block in the message flow, so it
            // never takes this row's place and there is nothing for `moved` to collide with.
        ))
        guard case let .card(form, isCompact) = shape else { return nil }
        return (form, isCompact, self.isOpened(peerId: peerId, form: form, isCompact: isCompact))
    }

    /// `offer` is the only shape with something to expand into; the rest draw their buttons straight
    /// away, so a stale expanded flag must not make them look different from a fresh open.
    private static func isOpened(peerId: PeerId, form: OnboardCard.Form, isCompact: Bool) -> Bool {
        guard form == .offer || isCompact else { return false }
        return SecutgOnboardCardState.shared.isOpened(peerId: peerId)
    }

    public static func memory(context: AccountContext, peerId: PeerId) -> OnboardMemory {
        return SecutgLocalPrefs.onboardMemory(accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), chatId: "\(peerId.toInt64())")
    }

    public static func setMemory(_ memory: OnboardMemory, context: AccountContext, peerId: PeerId) {
        SecutgLocalPrefs.setOnboardMemory(memory, accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), chatId: "\(peerId.toInt64())")
        SecutgOnboardCardState.shared.invalidate()
    }

    /// PLAN.md 3.24.5 rule 3 / the 3.24.8 table: unpairing — which is what withdrawing an invitation is —
    /// brings the guide back already counted as ignored once, so it returns as one collapsed line rather
    /// than arguing with somebody who just switched encryption off. Called from the menu's `unpair` entry
    /// so it applies however the user got there, not only from the card.
    public static func noteUnpaired(context: AccountContext, peerId: PeerId) {
        setMemory(memory(context: context, peerId: peerId).afterUnpair, context: context, peerId: peerId)
    }

    // MARK: what the buttons do (PLAN.md 3.24.7 rule 2)

    public enum Action: Equatable {
        /// Show the two roads. Both the collapsed row's button and the full card's button mean this, because
        /// they are the same move — and counting them the same is what keeps "open, pick a road, confirm"
        /// honest whether or not the card started collapsed (PLAN.md 3.24.3 rule 4).
        case expand
        /// PLAN.md 3.24.4 rule 1: opens the confirmation, never the pairing. Nothing leaves the device until
        /// the user has read what sending a `P1` into this chat costs.
        case autoPair
        /// PLAN.md 3.24.9: answering an invitation is itself the confirmation step, so no second dialog.
        case accept
        case offline
        case withdraw
        case repairHere
        case guideChapter
        case notNow
        case never
    }

    public static func perform(
        _ action: Action,
        context: AccountContext,
        peerId: PeerId,
        controller: ViewController?,
        sourceView: UIView?
    ) {
        switch action {
        case .expand:
            SecutgOnboardCardState.shared.setOpened(true, peerId: peerId)
        case .notNow:
            setMemory(memory(context: context, peerId: peerId).afterNotNow, context: context, peerId: peerId)
        case .never:
            setMemory(.never, context: context, peerId: peerId)
        case .autoPair:
            guard let controller else { return }
            SecutgChatMenu.syncLanguage(context: context)
            let confirm = UIAlertController(
                title: SecutgL10n.string("SecutgOnboardAuto"),
                message: SecutgL10n.string("SecutgOnboardAutoConfirm"),
                preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOnboardAutoSend"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                run(["pair"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
            }))
            confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(confirm, over: controller)
        case .accept:
            // The menu calls this entry "accept" while an invitation is pending and "pair" otherwise; both
            // run the same 3.7 step 1. Asking for either, in that order, is how the card follows the table
            // instead of guessing which name it has in this state.
            run(["accept", "pair"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        case .offline:
            run(["manual"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        case .withdraw:
            run(["unpair"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        case .repairHere:
            run(["repairHere"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        case .guideChapter:
            run(["guide"], context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        }
    }

    private static func run(_ ids: [String], context: AccountContext, peerId: PeerId, controller: ViewController?, sourceView: UIView?) {
        guard let controller else { return }
        SecutgChatMenu.run(anyOf: ids, context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        SecutgOnboardCardState.shared.invalidate()
    }
}
