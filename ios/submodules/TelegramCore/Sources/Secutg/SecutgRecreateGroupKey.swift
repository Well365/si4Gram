import Foundation
import Postbox
import SwiftSignalKit

/// SECUTG (PLAN.md 3.32): Telegram's own sense of "admin" for a chat — admin rights, or ownership.
///
/// A different question from `SecutgChatStatus.isAdmin`, and the two are routinely true of different
/// people. `isAdmin` there means "this device holds the group's signing key" — the device that created it,
/// and since PLAN.md 3.33 any device it handed the key to. This one means what the group's own member list
/// means by admin, which is the notion 3.32 needs: after every key-holding device wipes, `isAdmin` is false
/// for everyone left, so anything gated on it is gated on nobody. `RecreateGroupKeyGate` says why at length.
///
/// The test is upstream's own two-branch idiom — `flags.contains(.isCreator) || adminRights != nil` for a
/// `TelegramChannel`, a `role` that is not `.member` for a legacy `TelegramGroup` — the same shape
/// `canManageInvitations` and `canManageGroupCalls` use, and deliberately not a narrower permission: Web
/// asks `adminRights || isOwner` and the five clients have to answer alike. A user, or a peer the postbox
/// has never seen, is not an admin: unknown is never guessed at.
public func secutgIsTelegramGroupAdmin(_ peer: Peer?) -> Bool {
    if let channel = peer as? TelegramChannel {
        return channel.flags.contains(.isCreator) || channel.adminRights != nil
    }
    if let group = peer as? TelegramGroup {
        if case .member = group.role {
            return false
        }
        return true
    }
    return false
}

/// The same answer for a chat the caller has only the id of.
///
/// The menu that asks is built on the main thread out of the secuTG keyring, which is in memory; this one
/// fact lives in the postbox instead, so it cannot be read there. Hence a signal, resolved before the sheet
/// is put up rather than after — an entry that appears a moment late is an entry that is sometimes missing.
public func secutgTelegramGroupAdmin(postbox: Postbox, peerId: PeerId) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction -> Bool in
        return secutgIsTelegramGroupAdmin(transaction.getPeer(peerId))
    }
}
