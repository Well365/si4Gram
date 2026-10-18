import Foundation

/// SECUTG-HOOK (fix, 2026-09-27 真机): which sentence a P2 (v2 pairing) bubble reads. Every intermediate v2
/// step used to render through `peer-key:-:ok:v2_progress`, which `controlSummary` turns into "" — an EMPTY
/// bubble that looks broken — and every `.failed` P2 through `peer-key:<chat>:<raw reason>`, a line showing
/// a raw reason code. The mapping below is identical to Android's `V2PairingDispatch.Notify` lines.
///
/// `detail` is what `SecutgAccountRuntime.handleP2` stores on the row. Two cases keep the detail shapes they
/// already had (and `controlSummary` already renders): this device's own UNPAIR / CANCEL(user_reset) echo is
/// `unpair:own_echo`, its own ROSTER_COMMIT echo is `v2rekey:own_echo`. Everything else is `v2line:<rawValue>`.
public enum V2PairingLine: String, Equatable, CaseIterable {
    /// own INVITE → `SecutgPairInviteSent`
    case inviteSent = "invite_sent"
    /// own ACCEPT / SELECT / CONFIRM / MERGE / BUSY, a received intermediate step, a received MERGE →
    /// `SecutgV2Handshake`
    case handshake
    /// own READY → `SecutgV2ReadySent`
    case readySent = "ready_sent"
    /// own CANCEL (not a reset), a received CANCEL (not a reset) → `SecutgV2Cancelled`
    case cancelled
    /// a received BUSY → `SecutgV2PeerBusy`
    case peerBusy = "peer_busy"
    /// a refused (`.failed`) or malformed P2 → `SecutgV2Ignored`, never a raw reason code
    case ignored
    /// own UNPAIR, own CANCEL(user_reset) → `unpair:own_echo` (`SecutgUnpaired`)
    case unpairedByYou = "unpaired_by_you"
    /// own ROSTER_COMMIT → `v2rekey:own_echo`
    case rotatedByYou = "rotated_by_you"
    /// another device of this account (its own identity, or this device's V2Q clone) accepted the INVITE this device
    /// was also offered → `SecutgV2SiblingAccepted` (show the code on that device, scan it here)
    case siblingAccepted = "sibling_accepted"

    /// The first `detail` segment of every line that is not one of the two legacy shapes.
    public static let detailKind = "v2line"

    public var detail: String {
        switch self {
        case .unpairedByYou: return "unpair:own_echo"
        case .rotatedByYou: return "v2rekey:own_echo"
        default: return V2PairingLine.detailKind + ":" + rawValue
        }
    }
}

extension V2PairingDispatch {
    /// SECUTG-HOOK (fix, 2026-09-27 真机): the line for this device's OWN P2 coming back (the local copy at send
    /// time, and the server echo). Nothing is processed for an echo — this reads the envelope type only.
    public static func ownEchoLine(_ wire: String) -> V2PairingLine {
        guard let envelope = V2Envelope.parse(prefix: V2Messages.prefix, text: wire) else { return .ignored }
        switch envelope.type {
        case "INVITE": return .inviteSent
        case "READY": return .readySent
        case "UNPAIR": return .unpairedByYou
        case "ROSTER_COMMIT": return .rotatedByYou
        case "CANCEL": return isResetCancel(wire) ? .unpairedByYou : .cancelled
        default: return .handshake // ACCEPT / SELECT / CONFIRM / MERGE / BUSY
        }
    }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): a received P2 that `handleIncoming` answered `.progressed` and that is
    /// neither the step completing the pairing, an UNPAIR / CANCEL(user_reset) nor a ROSTER_COMMIT — the caller
    /// renders those four itself. A plain CANCEL reads as cancelled; anything else is a step of the handshake.
    public static func receivedProgressLine(_ wire: String) -> V2PairingLine {
        guard V2Envelope.parse(prefix: V2Messages.prefix, text: wire)?.type == "CANCEL", !isResetCancel(wire) else { return .handshake }
        return .cancelled
    }

    /// SECUTG-HOOK (fix, 2026-09-27 真机): `handleIncoming`'s `.ignored(reason)`. An `own_echo:` reason is this
    /// device's own message (`ownEchoLine`); a peer's MERGE is a handshake step, a peer's BUSY says they are
    /// in another pairing; anything else (an unknown type) is ignored.
    /// PLAN.md 3.39.6: a `sibling:` reason is a handshake step ANOTHER device of this account sent (an outgoing
    /// message whose actor is not this device's identity for the binding). It reads exactly like this device's own
    /// echo of the same step would — "已向对方发出加密对话邀请" for the account's INVITE, the handshake line for the
    /// rest — since the account, not the device, is what the reader thinks of as "me".
    /// SECUTG-HOOK (fix, 2026-10-01 真机): `sibling_accepted` — another device of this account accepted the invite this
    /// device was offered (`SecutgV2SiblingAccepted`); `invite_closed` — an INVITE this device will not offer again, which
    /// reads as a step of the handshake.
    public static func ignoredLine(reason: String, wire: String) -> V2PairingLine {
        if reason == siblingAcceptedReason { return .siblingAccepted }
        if reason == inviteClosedReason { return .handshake }
        if reason.hasPrefix("own_echo:") || reason.hasPrefix("sibling:") { return ownEchoLine(wire) }
        switch reason {
        case "merge": return .handshake
        case "busy": return .peerBusy
        default: return .ignored
        }
    }

    /// Whether `wire` is a CANCEL whose reason is `user_reset` — the peer's (or this device's) 「一键恢复」.
    public static func isResetCancel(_ wire: String) -> Bool {
        return V2Messages.parseCancel(wire)?.body.reason == "user_reset"
    }
}
