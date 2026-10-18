import Foundation
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit

/// SECUTG-HOOK (PLAN.md 3.48.7 gap e/f): forces a redraw of one already-stored message, by rewriting it to
/// itself in the Postbox transaction. iOS had no equivalent of this at all before this pass (the macOS client's
/// `secutgRedrawMessage` is the reference this is ported from) — without it, a relay card that just saved a
/// local copy (PLAN.md 3.48.7 §1) would only show the fetched content/inline image after the user scrolls the
/// message out of view and back, since nothing else tells the message list this message's content changed.
///
/// Deliberately a transaction-level rewrite rather than any kind of UI-layer "please relayout" signal: the
/// existing render hooks (`SecutgRelayCard.cardLine`, `ChatMessageTextBubbleContentNode`'s inline-image hook)
/// already read straight from `SecutgRelayRuntime`'s local-copy store on every layout pass, so the only thing
/// actually missing is a reason for the message list to lay this message out again at all.
public func secutgRedrawMessage(context: AccountContext, messageId: MessageId) {
    let _ = context.account.postbox.transaction { transaction -> Void in
        transaction.updateMessage(messageId, update: { currentMessage in
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
            }
            return .update(StoreMessage(
                id: .Id(currentMessage.id), customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey,
                threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags),
                tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags,
                forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text,
                attributes: currentMessage.attributes, media: currentMessage.media))
        })
    }.start()
}
