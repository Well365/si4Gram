import Foundation

/// What the deletion hook (PLAN.md 3.48.0 hook ⑦ / 3.48.7 §3-4) should do for one message that just left the
/// local message store, worked out with no I/O so the actual Postbox-observation glue in the app layer can stay
/// a thin, error-swallowing wrapper around this.
public struct RelayRevokeRequest: Equatable {
    public let itemId: String
    public let relayURL: String
    public let deleteToken: String
}

public struct RelayDeletionPlan: Equatable {
    /// Always true for any `L1:` message that is leaving — the local copy's lifetime follows the message's.
    public let removeLocalCopy: Bool
    /// Set only for the sender's own outgoing relay message, when a delete token is on file and the item was
    /// not already revoked: ask the relay to forget it too, so a reader who has not fetched it yet cannot.
    public let revoke: RelayRevokeRequest?

    public static let none = RelayDeletionPlan(removeLocalCopy: false, revoke: nil)
}

public enum RelayDeletion {
    /// `text` is the message's text at the moment of removal; `sentItem` is this chat+message's sent-item
    /// record, if this device sent it through a relay (nil for a received relay message, or a non-relay one).
    public static func plan(text: String, sentItem: RelaySentItem?) -> RelayDeletionPlan {
        guard RelayL1.isReference(text) else { return .none }
        guard let sentItem = sentItem, !sentItem.revoked, let token = sentItem.deleteToken else {
            return RelayDeletionPlan(removeLocalCopy: true, revoke: nil)
        }
        return RelayDeletionPlan(removeLocalCopy: true, revoke: RelayRevokeRequest(itemId: sentItem.id, relayURL: sentItem.relayURL, deleteToken: token))
    }
}
