import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG (PLAN.md 3.30 rule 10): the live half of the "the other side keeps sending plaintext" bar —
/// neither the judgement (that is `SecutgCore.PlaintextPane`, pure and under test, byte-identical with
/// the other four clients) nor the drawing (`SecutgPlaintextPanelNode`).
///
/// Two things live here and nowhere else:
///
/// - **what the message list last said**, cached per chat. The expensive half of the judgement is a scan
///   of the loaded window, and the only moment it can change is when that window changes, so it is
///   computed once per history transition rather than once per layout pass.
/// - **the answer for this session**, also per chat and only in memory. Two of the bar's three buttons
///   mean exactly this and nothing else; see `perform`.
public final class SecutgPlaintextPaneState {
    public static let shared = SecutgPlaintextPaneState()

    private let lock = NSLock()
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)

    /// chat key → the loaded window, reduced to what the judgement reads (at most `recentWindow` entries)
    private var recent: [String: [PlaintextPane.Message]] = [:]
    /// chat keys the user has answered about during this run of the app
    private var dismissed: Set<String> = []

    private init() {
    }

    /// Bumped whenever the answer for some chat may have changed. `ChatControllerImpl` folds this into a
    /// layout request, which is what puts the bar on screen or takes it off; without it the bar would
    /// only appear the next time something else happened to relayout the chat.
    public var revision: Signal<Int32, NoError> {
        return self.revisionPromise.get()
    }

    fileprivate func invalidate() {
        self.lock.lock()
        self.counter &+= 1
        let value = self.counter
        self.lock.unlock()
        self.revisionPromise.set(value)
    }

    fileprivate func setRecent(_ value: [PlaintextPane.Message], key: String) {
        self.lock.lock()
        // Only the answer is compared, not the window: this runs on every history transition, which in a
        // busy chat is every arriving message, and a relayout per message would be a real cost for a bar
        // that changes state perhaps twice in a conversation.
        let changed = PlaintextPane.isPeerPlaintext(recent: self.recent[key] ?? [])
            != PlaintextPane.isPeerPlaintext(recent: value)
        self.recent[key] = value
        self.lock.unlock()
        if changed {
            self.invalidate()
        }
    }

    fileprivate func recent(key: String) -> [PlaintextPane.Message] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recent[key] ?? []
    }

    fileprivate func isDismissed(key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.dismissed.contains(key)
    }

    fileprivate func dismiss(key: String) {
        self.lock.lock()
        self.dismissed.insert(key)
        self.lock.unlock()
        self.invalidate()
    }

    /// For anything that changes a chat's encryption switch without going through this file — the lock
    /// button's own menu — so the bar appears (or goes) at the moment of the tap rather than whenever the
    /// chat next relayouts.
    public func encryptionSwitchChanged() {
        self.invalidate()
    }
}

/// The bar's view of the world: whether it belongs on screen in this chat, and what each button does.
public enum SecutgPlaintextPaneHost {
    private static func key(accountPeerId: PeerId, peerId: PeerId) -> String {
        return "\(accountPeerId.toInt64()):\(peerId.toInt64())"
    }

    // MARK: what the message list says

    /// Re-reads the loaded window and caches the message half of the judgement. Called from
    /// `ChatHistoryListNode` once per applied history transition, on the main queue.
    ///
    /// The window is the one the list itself is showing, which is what "the last 20 **listed** messages"
    /// means on every client: nothing is fetched to answer this question, and scrolling far up simply
    /// means the answer is about the messages up there (the same thing happens on Web A).
    public static func update(context: AccountContext, peerId: PeerId?, view: MessageHistoryView?) {
        guard let peerId, peerId.namespace != Namespaces.Peer.SecretChat else { return }
        let accountPeerId = context.account.peerId
        let recent = (view?.entries ?? []).suffix(PlaintextPane.recentWindow).map { entry -> PlaintextPane.Message in
            return message(entry.message, accountPeerId: accountPeerId)
        }
        SecutgPlaintextPaneState.shared.setRecent(recent, key: key(accountPeerId: accountPeerId, peerId: peerId))
    }

    /// One message reduced to the three facts `PlaintextPane` uses.
    ///
    /// Note what this does **not** do: it does not decide whether the message counts as plaintext. That
    /// distinction is `PlaintextPane.carriesSecutgMeta`, one pure function shared with the other four
    /// clients — getting it wrong is silent (a bar that never appears looks exactly like a peer who never
    /// stopped encrypting), so it is not something each client's UI layer gets to re-derive. All that
    /// happens here is a total switch from this platform's attribute onto the shared names, which is also
    /// what makes a future sixth `Kind` a compile error rather than a message quietly classified as
    /// plaintext.
    private static func message(_ message: Message, accountPeerId: PeerId) -> PlaintextPane.Message {
        let meta: PlaintextPane.Meta?
        switch message.secutgMeta?.kind {
        case .decrypted: meta = .decrypted
        case .undecryptable: meta = .undecryptable
        case .control: meta = .control
        case .groupInvite: meta = .groupInvite
        case .sealed: meta = .sealed
        case .plaintext: meta = .plaintext
        case nil: meta = nil
        }
        return PlaintextPane.Message(
            isIncoming: message.effectivelyIncoming(accountPeerId),
            hasText: !message.text.isEmpty,
            meta: meta
        )
    }

    // MARK: is the bar up

    /// The two live facts — this chat's encryption switch and this session's answer — folded onto the
    /// cached message half. Read from `ChatControllerNode.updateLayout`, so it stays cheap.
    public static func isDue(context: AccountContext, peerId: PeerId) -> Bool {
        guard peerId.namespace != Namespaces.Peer.SecretChat else { return false }
        let key = key(accountPeerId: context.account.peerId, peerId: peerId)
        let isDismissed = SecutgPlaintextPaneState.shared.isDismissed(key: key)
        let recent = SecutgPlaintextPaneState.shared.recent(key: key)
        // Reading the chat's status walks the keyring (current key, pairing, member list), and this runs on
        // every layout pass — a keyboard appearing, a rotation. The two in-memory facts are free and answer
        // "no" for almost every chat, so they go first; `PlaintextPane.isDue` still has the final word on
        // the chats that get past them, so the shared judgement is not duplicated here.
        guard !isDismissed, PlaintextPane.isPeerPlaintext(recent: recent),
              let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return false }
        return PlaintextPane.isDue(
            isChatEncrypted: runtime.status(chatPeerId: peerId).encryptionEnabled,
            isDismissed: isDismissed,
            recent: recent
        )
    }

    // MARK: what the buttons do

    public enum Action: Equatable {
        /// 〔Keep encrypting〕
        case keep
        /// 〔Turn encryption off〕 — the only one of the three that changes anything beyond this session
        case off
        /// 〔Ignore〕
        case ignore
    }

    /// PLAN.md 3.30 rule 10, deliberately: **`.keep` and `.ignore` do the same thing.** Both only stop the
    /// bar asking again in this chat for this session; only `.off` changes state.
    ///
    /// The two are not meant to stay synonyms — "I have decided, keep encrypting" and "do not bother me
    /// right now" are different answers, and splitting them needs somewhere to persist the first. That is
    /// a decision for all five clients at once, taken after every client has the bar at all; until then
    /// the redundancy is recorded in 3.30 rule 10 rather than rediscovered here. Do not quietly give them
    /// different behaviour, and do not drop one of them.
    public static func perform(_ action: Action, context: AccountContext, peerId: PeerId) {
        let key = key(accountPeerId: context.account.peerId, peerId: peerId)
        switch action {
        case .keep, .ignore:
            SecutgPlaintextPaneState.shared.dismiss(key: key)
        case .off:
            SecutgHookRegistry.shared.runtime(for: context.account.peerId)?
                .setChatEncryption(chatPeerId: peerId, enabled: false)
            // Deliberately *not* dismissed: the switch being off is already enough for `isDue` to say no,
            // and marking the chat answered as well would mean that turning encryption back on later in the
            // same session silently loses the warning. Web A leaves it undismissed for the same reason.
            SecutgPlaintextPaneState.shared.encryptionSwitchChanged()
        }
    }
}
