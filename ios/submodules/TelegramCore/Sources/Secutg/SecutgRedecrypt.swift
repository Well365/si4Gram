import Foundation
import Postbox
import SwiftSignalKit
import SecutgCore

/// SECUTG: opens the messages that could not be opened when they arrived, now that the keyring has a key it did
/// not have before (PLAN.md 3.17 point 3).
///
/// The decrypt hook sits in `StoreMessage(apiMessage:)`, so a message is opened exactly once, when it is stored.
/// That is the right place for the ordinary case and precisely the wrong one for the commonest failure: a group
/// member who is sent messages before the key reaches them. Postbox keeps what the hook wrote and never runs it
/// again, so without this pass those messages stay unreadable on this device forever. They do not have to: the
/// stored text is still the ciphertext — the notice in the bubble is a rendering decision only — so all that is
/// needed is to ask again.
///
/// **How the messages are found.** Postbox indexes messages by peer, namespace and `MessageTags`; there is no index
/// over message attributes, and `SecutgTextMetaAttribute` is not a tag, so the enumeration has to be a per-peer scan
/// either way. Two kinds of row are selected (`CatchUp.isRedecryptCandidate`, SecutgCore, under test):
///   - `kind == .undecryptable`, written by exactly one branch of the receive hook — a content wire that was tried
///     against the keyring and refused;
///   - since 2026-10-01, a row with **no** meta attribute whose text is a content wire (`E1:` / E2-shaped). That is
///     the row the Notification Service Extension stored while the app was in the background: it has no secuTG
///     runtime, so the hook never ran and nothing marked it. The old rule (undecryptable only) never re-opened such
///     a row, and PLAN.md 3.47's catch-up skipped it too once it lay under the watermark — so a V2Q import on a real
///     iPhone left that chat's earlier messages shut.
/// Every other row is left alone: plain text, control messages, invites, and a decrypted message whose plaintext
/// happens to look like a wire (it carries `.decrypted`) — sniffing text alone would catch that last one and
/// destroy it.
///
/// **What is written back.** Exactly what the receive hook would have stored (`SecutgCatchUp.storeMessage`): the
/// hook's text (plaintext, or the identical envelope plus `.sealed` under 3.19 / 3.44), its entities, a fresh meta
/// attribute, the derived tags; same id, `stableId`, flags, media and timestamp. A refused row that still fails keeps
/// its stored ciphertext and attribute untouched, because it is what a later key will need; an unmarked row that
/// still fails gets the hook's `.undecryptable` verdict, so it reads as the right 3.17 situation and is found by the
/// next sweep the ordinary way. Local write only: nothing is sent to the server.
///
/// **What PLAN.md 3.19 changed here: nothing, deliberately.** A chat that keeps only the envelope on disk stores its
/// openable messages as `.sealed` and opens them at render time, so the "a key arrived, re-read the old messages"
/// problem this sweep exists for does not arise there — which is 3.19 point 6, and the reason the two mechanisms are
/// not fighting. What is still needed is the other half: a message that arrived in such a chat *before* the key did
/// is stored `.undecryptable`, and this sweep is what opens it. It does that by calling the same receive hook, which
/// now seals: the text it writes back is the identical ciphertext and only the attribute flips to `.sealed`. So the
/// sweep never puts plaintext on the disk of a chat that asked not to have any, and for a chat with the setting off
/// it behaves exactly as it always did.
///
/// `peerIds` nil sweeps every chat, which is what a transferred keyring needs — its masters can open messages in any
/// chat, not just the ones it re-bound. The four callers are in PLAN.md 3.17: importing a chat key, accepting a
/// group invite, completing a pairing, and importing a transferred keyring.
///
/// - Returns: how many messages became readable.
public func secutgRedecryptChats(postbox: Postbox, accountPeerId: PeerId, peerIds: [PeerId]? = nil) -> Signal<Int, NoError> {
    return postbox.transaction { transaction -> Int in
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else { return 0 }

        // Collect first, rewrite after: `withAllMessages` is a read over the peer's messages and must not be
        // re-entered by a write while it is running.
        var candidates: [MessageId] = []
        for peerId in peerIds ?? transaction.chatListGetAllPeerIds() {
            guard peerId.namespace != Namespaces.Peer.SecretChat else { continue }
            transaction.withAllMessages(peerId: peerId, { message in
                if CatchUp.isRedecryptCandidate(text: message.text, stored: secutgStoredMeta(message.secutgMeta)) {
                    candidates.append(message.id)
                }
                return true
            })
        }
        guard !candidates.isEmpty else { return 0 }

        var opened = 0
        for id in candidates {
            transaction.updateMessage(id, update: { currentMessage in
                return secutgReopen(currentMessage, runtime: runtime, opened: &opened)
            })
        }
        return opened
    }
}

/// `SecutgTextMetaAttribute` reduced to what `CatchUp.isRedecryptCandidate` asks.
func secutgStoredMeta(_ meta: SecutgTextMetaAttribute?) -> CatchUp.StoredMeta {
    guard let meta = meta else { return .unmarked }
    return meta.kind == .undecryptable ? .undecryptable : .other
}

/// One candidate through the receive hook's own entry, with the message's real outgoing flag, author and server
/// date. The candidate test is repeated: the online path or the catch-up pass may have written the row since the
/// scan. Only content wires get here, so this re-runs the decrypt branch and can never re-apply a control message.
private func secutgReopen(_ current: Message, runtime: SecutgAccountRuntime, opened: inout Int) -> PostboxUpdateMessage {
    let stored = secutgStoredMeta(current.secutgMeta)
    guard CatchUp.isRedecryptCandidate(text: current.text, stored: stored) else { return .skip }
    let currentEntities = current.textEntitiesAttribute?.entities ?? []
    guard let transformed = runtime.transformIncoming(
        text: current.text,
        entities: currentEntities,
        chatPeerId: current.id.peerId,
        senderPeerId: current.author?.id,
        messageDate: current.timestamp,
        isOutgoing: !current.flags.contains(.Incoming)
    ) else {
        return .skip
    }
    if transformed.meta.kind == .undecryptable {
        // Still shut. A refused row keeps everything: its ciphertext is what the next key will be handed. An
        // unmarked one gets the verdict the hook would have written, so it stops reading as "not opened yet".
        guard stored == .unmarked else { return .skip }
    } else {
        opened += 1
    }
    return .update(SecutgCatchUp.storeMessage(rewriting: current, with: transformed, currentEntities: currentEntities))
}

/// SECUTG (PLAN.md 3.34.3 rule 1, 3.34.7 item 4): whether a stored control row's verdict was "not yet".
///
/// Three kinds of row wait. An `N1` parked because this group's admin list had not loaded (`retire:pending:…`),
/// an `R1` parked because the notice that would make its signing key trusted has not applied yet
/// (`rekey:<type>:pending`) since 3.34.7 item 4, and — since 3.35.4 — a `G2` parked for the same reason as the
/// `N1` case, the admin list not loaded yet (`groupKey:park:<userId>`). All three are written by exactly one
/// branch of the receive hook, so selecting on the stored detail touches nothing else: an applied notice says
/// `retire:ok:…`, an applied welcome `rekey:welcome:ok[:already_known]`, an applied group key
/// `groupKey:apply:…`, and a refusal carries its own reason in the same place.
///
/// Parsed rather than prefix-matched on the `rekey` side, because there the outcome is the third segment.
private func secutgIsParkedControlRow(_ meta: SecutgTextMetaAttribute?) -> Bool {
    guard let meta = meta, meta.kind == .control, let detail = meta.detail else { return false }
    let parts = detail.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let kind = parts.first else { return false }
    if kind == "retire" { return parts.count > 1 && parts[1] == "pending" }
    if kind == "rekey" { return parts.count > 2 && parts[2] == "pending" }
    if kind == "groupKey" { return parts.count > 1 && parts[1] == G2.Verdict.park.rawValue }
    // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): a `GP1` parked for the admin list, same as `G2`.
    if kind == "groupPw" { return parts.count > 1 && parts[1] == G2.Verdict.park.rawValue }
    return false
}

/// SECUTG (PLAN.md 3.34.3 rule 1, 3.34.7 item 4): re-judges the control messages that were **parked** — an
/// `N1` waiting for this group's admin list, an `R1 welcome` waiting for the notice that makes its signer
/// trusted.
///
/// Parking is the point of those rules. "Not known yet" is a third state, and answering it "the sender is not
/// an admin" silently throws the notice away — which after a long offline stretch is every notice there is,
/// because the history always arrives before the member list. The welcome that overtakes its notice is the
/// same shape of problem, and the one that cost two phones their keys on 2026-09-19. So the processor parks,
/// and something has to come back afterwards and ask again. On Web that is free: it re-derives every control
/// line on each render. Here the verdict is reached once, in the receive hook, and written into the message;
/// this is the ask-again.
///
/// It re-runs the receive hook — the same road, every check included, never a shortcut into the keyring. A row
/// that is still parked is left exactly as it is, so the next pass finds it again. Only the meta attribute is
/// rewritten; a control message keeps its wire text, which is what lets it be re-read like this at all.
///
/// - Returns: how many parked rows reached a verdict.
public func secutgRetryParkedControlRows(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId) -> Signal<Int, NoError> {
    return postbox.transaction { transaction -> Int in
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else { return 0 }

        // Collect first, rewrite after: `withAllMessages` is a read and must not be re-entered by a write.
        var candidates: [MessageId] = []
        transaction.withAllMessages(peerId: peerId, { message in
            if secutgIsParkedControlRow(message.secutgMeta) { candidates.append(message.id) }
            return true
        })
        guard !candidates.isEmpty else { return 0 }

        var decided = 0
        for id in candidates {
            transaction.updateMessage(id, update: { currentMessage in
                guard let transformed = runtime.transformIncoming(
                    text: currentMessage.text,
                    entities: [],
                    chatPeerId: currentMessage.id.peerId,
                    senderPeerId: currentMessage.author?.id,
                    messageDate: currentMessage.timestamp,
                    isOutgoing: !currentMessage.flags.contains(.Incoming)
                ), !secutgIsParkedControlRow(transformed.meta) else {
                    // Still parked — the list is loaded but this sender is not in it yet, the notice this
                    // welcome waits for has not applied, or the read raced. Leave the message exactly as it is,
                    // so the next pass finds it again.
                    return .skip
                }

                var attributes = currentMessage.attributes.filter { !($0 is SecutgTextMetaAttribute) }
                attributes.append(transformed.meta)
                decided += 1

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
                    attributes: attributes,
                    media: currentMessage.media))
            })
        }
        return decided
    }
}
