import Foundation
import Postbox
import SwiftSignalKit
import SecutgCore

/// SECUTG (PLAN.md 3.47): the catch-up pass over messages the Notification Service Extension wrote into the shared
/// Postbox while the app was suspended.
///
/// The extension pulls new messages with `standalonePollDifference` and stores them through
/// `StoreMessage(apiMessage:)` like the app does, but it has no secuTG runtime (`SecutgHookRegistry` is empty there),
/// so the receive hook in that initialiser skips: a P2 / R1 / U1 / G2 / GP1 that arrived in the background was never
/// applied, an E1 / E2 sits in the database as raw ciphertext without the 3.19 / 3.44 sealed marker. When the app
/// comes back those rows are already stored and nothing would ever run the hook on them again. This pass does.
///
/// **What it reads.** Per chat, the messages above a watermark kept in this device's local preferences
/// (`SecutgLocalPrefs.catchUpWatermarks`, never in a backup). The first time it runs, every chat in the list is owed
/// a look-back over its newest `CatchUp.firstEnableLookback` messages before its watermark is set (2026-10-01: it used
/// to jump straight to the top, burying every row the extension had stored before then); chats the budget does not
/// reach stay owed and the next pass continues. Chats come from the chat list, messages from the newest-first scan the macOS assistant
/// rescan uses (`chatListGetAllPeerIds` / `getTopPeerMessageId` / `scanTopMessages`). Which messages qualify, in
/// what order and how many per pass are `CatchUp` rules in SecutgCore, under test.
///
/// **What it writes.** Each qualifying message goes through the receive hook's own entry — `transformIncoming`
/// with the message's real outgoing flag, author and server date — and the result is written back in the same
/// shape the hook stores at receive time: the text, the entity attribute replaced when the hook returns entities,
/// and the `SecutgTextMetaAttribute`. So a sealed chat gets the envelope plus `.sealed`, a control line keeps its
/// wire plus its `.control` detail, and the meta attribute is what keeps the row from ever qualifying again. Every
/// processor is idempotent, so meeting the online path halfway does no harm. Local write only.
///
/// **When.** `trigger` is called when the account's app context comes up and whenever the app becomes active
/// (`SecutgCatchUpDriver` in SecutgChatMenu). One pass at a time per account; a trigger during a pass buys exactly
/// one more (`CatchUpGate`), and a pass that ran out of its ~2 s budget chains a bounded number of follow-ups.
public enum SecutgCatchUp {
    public struct ChatResult: Equatable {
        public let processed: Int
        public let advanceTo: Int32?
        public let remaining: Int
        public let truncated: Bool
    }

    private static let gatesLock = NSLock()
    private static var gates: [PeerId: CatchUpGate] = [:]
    /// First, cheap scan per chat; only a chat that fills it is scanned again with the full window. `scanTopMessages`
    /// keeps fetching after a `false`, so a small first window is what keeps the common case (a handful of new
    /// messages) from walking the whole window.
    private static let firstScanWindow = 60

    private static func gate(for accountPeerId: PeerId) -> CatchUpGate {
        gatesLock.lock(); defer { gatesLock.unlock() }
        if let gate = gates[accountPeerId] { return gate }
        let gate = CatchUpGate()
        gates[accountPeerId] = gate
        return gate
    }

    private static func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    /// Runs a pass now, or queues one after the pass already running. Safe from any thread.
    public static func trigger(postbox: Postbox, accountPeerId: PeerId) {
        let gate = gate(for: accountPeerId)
        guard gate.request() else { return }
        run(postbox: postbox, accountPeerId: accountPeerId, gate: gate)
    }

    private static func run(postbox: Postbox, accountPeerId: PeerId, gate: CatchUpGate) {
        let _ = pass(postbox: postbox, accountPeerId: accountPeerId).start(next: { moreWork in
            if gate.finish(moreWork: moreWork) {
                run(postbox: postbox, accountPeerId: accountPeerId, gate: gate)
            }
        })
    }

    /// One pass. Emits once: whether work was left for the next pass (budget or per-chat cap reached).
    static func pass(postbox: Postbox, accountPeerId: PeerId) -> Signal<Bool, NoError> {
        let accountKey = SecutgLocalPrefs.accountKey(accountPeerId)
        let budget = CatchUp.Budget(startedAtMs: nowMs())
        return postbox.transaction { transaction -> [CatchUp.DueChat] in
            guard SecutgHookRegistry.shared.runtime(for: accountPeerId) != nil else { return [] }
            let tops = chatTops(transaction)
            guard let marks = SecutgLocalPrefs.catchUpWatermarks(accountKey: accountKey) else {
                // PLAN.md 3.47 point 5, amended 2026-10-01: first enable — every chat is owed a bounded look-back
                // for the unmarked wires the extension stored before this pass existed; this pass starts on them.
                let first = CatchUpWatermarks.firstEnabled(tops)
                SecutgLocalPrefs.setCatchUpWatermarks(first, accountKey: accountKey)
                return CatchUp.dueChats(tops, marks: first)
            }
            return CatchUp.dueChats(tops, marks: marks)
        }
        |> mapToSignal { due -> Signal<Bool, NoError> in
            return processChats(due[...], postbox: postbox, accountPeerId: accountPeerId, accountKey: accountKey, budget: budget, moreWork: false)
        }
    }

    private static func chatTops(_ transaction: Transaction) -> [CatchUp.ChatTop] {
        var tops: [CatchUp.ChatTop] = []
        for peerId in transaction.chatListGetAllPeerIds() {
            guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerId.namespace),
                  let top = transaction.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud) else { continue }
            tops.append(CatchUp.ChatTop(chatId: SecutgAccountRuntime.chatKey(peerId), topMessageId: top.id))
        }
        return tops
    }

    /// One transaction per chat, so the database is never held for the whole pass. The budget is checked before
    /// each chat; the watermark is saved after each, so an interrupted pass loses nothing it did.
    private static func processChats(_ remaining: ArraySlice<CatchUp.DueChat>, postbox: Postbox, accountPeerId: PeerId,
                                     accountKey: String, budget: CatchUp.Budget, moreWork: Bool) -> Signal<Bool, NoError> {
        guard let chat = remaining.first else { return .single(moreWork) }
        if budget.isExhausted(nowMs: nowMs()) { return .single(true) }
        return postbox.transaction { transaction -> ChatResult in
            return processChat(chat, transaction: transaction, accountPeerId: accountPeerId)
        }
        |> mapToSignal { result -> Signal<Bool, NoError> in
            if let advanceTo = result.advanceTo {
                let marks = SecutgLocalPrefs.catchUpWatermarks(accountKey: accountKey) ?? CatchUpWatermarks()
                SecutgLocalPrefs.setCatchUpWatermarks(marks.advancing(chat.chatId, to: advanceTo), accountKey: accountKey)
            }
            if result.processed > 0 || result.truncated {
                // Counts and ids only: never a message's text.
                Logger.shared.log("Secutg", "catch-up \(chat.chatId): \(result.processed) processed, \(result.remaining) left\(result.truncated ? ", scan window reached" : "")")
            }
            return processChats(remaining.dropFirst(), postbox: postbox, accountPeerId: accountPeerId, accountKey: accountKey,
                                budget: budget, moreWork: moreWork || result.remaining > 0)
        }
    }

    /// Scan → slice → run each candidate through the receive hook and write it back → where the watermark goes.
    static func processChat(_ chat: CatchUp.DueChat, transaction: Transaction, accountPeerId: PeerId) -> ChatResult {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId),
              let peerId = SecutgAccountRuntime.peerId(chatKey: chat.chatId) else {
            return ChatResult(processed: 0, advanceTo: nil, remaining: 0, truncated: false)
        }
        var scan = collect(peerId: peerId, floor: chat.floor, limit: min(firstScanWindow, chat.scanWindow), transaction: transaction)
        if !scan.reachedFloor && chat.scanWindow > firstScanWindow {
            scan = collect(peerId: peerId, floor: chat.floor, limit: chat.scanWindow, transaction: transaction)
        }
        // A look-back stops at its window on purpose: not a truncated scan, nothing to log.
        let slice = CatchUp.slice(scanned: scan.scanned, floor: chat.floor, reachedFloor: scan.reachedFloor || chat.isLookback)
        var processed = 0
        for messageId in slice.process {
            if rewrite(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId), runtime: runtime, transaction: transaction) {
                processed += 1
            }
        }
        return ChatResult(processed: processed, advanceTo: slice.advanceTo, remaining: slice.remaining, truncated: slice.truncated)
    }

    /// Newest first down to the floor. `reachedFloor` is also true when the chat simply ran out of stored messages
    /// before the window did.
    private static func collect(peerId: PeerId, floor: Int32, limit: Int, transaction: Transaction) -> (scanned: [CatchUp.Scanned], reachedFloor: Bool) {
        var scanned: [CatchUp.Scanned] = []
        var reachedFloor = false
        var seen = 0
        transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: limit) { message in
            // `scanTopMessages` keeps fetching after a `false`; the flag makes the rest of its walk a no-op.
            if reachedFloor { return false }
            seen += 1
            if message.id.id <= floor {
                reachedFloor = true
                return false
            }
            scanned.append(CatchUp.Scanned(id: message.id.id, isCandidate: CatchUp.isCandidate(text: message.text, hasSecutgMeta: message.secutgMeta != nil)))
            return true
        }
        if !reachedFloor && seen < limit { reachedFloor = true }
        return (scanned, reachedFloor)
    }

    /// The receive hook's own call and its own storing shape (`StoreMessage_Telegram.swift`, SECUTG-HOOK B1), on a
    /// message already in the database. The candidate test is repeated inside the update: the online path may have
    /// stored the same message again between the scan and here.
    private static func rewrite(_ id: MessageId, runtime: SecutgAccountRuntime, transaction: Transaction) -> Bool {
        var wrote = false
        transaction.updateMessage(id, update: { current in
            guard CatchUp.isCandidate(text: current.text, hasSecutgMeta: current.secutgMeta != nil) else { return .skip }
            let currentEntities = current.textEntitiesAttribute?.entities ?? []
            guard let transformed = runtime.transformIncoming(
                text: current.text,
                entities: currentEntities,
                chatPeerId: current.id.peerId,
                senderPeerId: current.author?.id,
                messageDate: current.timestamp,
                isOutgoing: !current.flags.contains(.Incoming)
            ) else {
                // The hook had nothing to say about it either (it would have stored it untouched): leave it.
                return .skip
            }
            wrote = true
            return .update(storeMessage(rewriting: current, with: transformed, currentEntities: currentEntities))
        })
        return wrote
    }

    /// The receive hook's storing shape (`StoreMessage_Telegram.swift`, SECUTG-HOOK B1) applied to a row already in
    /// the database: the hook's text, the entity attribute replaced when the hook returns entities, a fresh
    /// `SecutgTextMetaAttribute`, and the tags the hook's store would have derived, added to what the row has.
    /// Same id, `stableId`, flags, media and date. Shared with the 3.17 re-decrypt sweep (`secutgRedecryptChats`).
    static func storeMessage(rewriting current: Message, with transformed: SecutgAccountRuntime.Incoming, currentEntities: [MessageTextEntity]) -> StoreMessage {
        var attributes = current.attributes.filter { !($0 is SecutgTextMetaAttribute) }
        var entities = currentEntities
        if let replaced = transformed.entities {
            attributes.removeAll(where: { $0 is TextEntitiesMessageAttribute })
            if !replaced.isEmpty { attributes.append(TextEntitiesMessageAttribute(entities: replaced)) }
            entities = replaced
        }
        attributes.append(transformed.meta)
        // The tags the hook's store would have computed from the new text, added to what the row already has
        // (pinned, unseen reactions… are maintained elsewhere and must not be dropped).
        let derived = tagsForStoreMessage(incoming: current.flags.contains(.Incoming), attributes: attributes, media: current.media,
                                          textEntities: entities, isPinned: current.tags.contains(.pinned))
        return StoreMessage(
            id: current.id,
            customStableId: nil,
            globallyUniqueId: current.globallyUniqueId,
            groupingKey: current.groupingKey,
            threadId: current.threadId,
            timestamp: current.timestamp,
            flags: StoreMessageFlags(current.flags),
            tags: current.tags.union(derived.0),
            globalTags: current.globalTags.union(derived.1),
            localTags: current.localTags,
            forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init),
            authorId: current.author?.id,
            text: transformed.text,
            attributes: attributes,
            media: current.media)
    }
}
