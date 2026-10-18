import Foundation
import Postbox
import SwiftSignalKit

/// SECUTG: re-renders one message in place, without changing anything about it (PLAN.md 3.13).
///
/// The very same id, flags, text, media and attributes go back in; what the write buys is the `stableVersion`
/// Postbox bumps on every update. The chat history compares entries by that version, so the row is rebuilt and the
/// bubble's layout runs again — which is the whole point: the group-invite card decides what it says by asking the
/// live keyring at layout time, so bumping the message is how it flips from "Import and join" to the done line the
/// moment the key is imported, rather than whenever the row happens to be laid out next.
///
/// `stableId` is preserved (`customStableId: nil` keeps the one already stored), so the list updates the row in
/// place instead of animating a delete and an insert. Local write only: nothing is sent to the server.
public func secutgRefreshMessage(postbox: Postbox, id: MessageId) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateMessage(id, update: { currentMessage in
            return .update(StoreMessage(
                id: currentMessage.id,
                customStableId: nil,
                globallyUniqueId: currentMessage.globallyUniqueId,
                groupingKey: currentMessage.groupingKey,
                threadId: currentMessage.threadId,
                timestamp: currentMessage.timestamp,
                flags: StoreMessageFlags(currentMessage.flags),
                tags: currentMessage.tags,
                globalTags: currentMessage.globalTags,
                localTags: currentMessage.localTags,
                forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                authorId: currentMessage.author?.id,
                text: currentMessage.text,
                attributes: currentMessage.attributes,
                media: currentMessage.media))
        })
    }
    |> ignoreValues
}
