import Foundation

/// SECUTG-HOOK (fix, mirrors E1): the wire text of a live incoming P2 INVITE this device has not yet
/// accepted or declined, keyed by chat. Purely a UI-accept-flow convenience — not part of
/// `V2Processor.PairingProcessor`'s own transaction state — but the accept button's whole decision of
/// "accept this invite" vs. "start a brand new one" (`SecutgRuntime.swift`'s `startPairing`) depends
/// entirely on this record still being there.
///
/// Before this fix it lived only in an in-memory `[String: String]` on `SecutgAccountRuntime` — never
/// persisted, so an app relaunch between "invite received" and "user taps accept" (a routine gap: the
/// user is reacting to a notification while the app was not running) silently emptied it. The accept
/// tap then fell through to `V2PairingDispatch.startPairing`'s fresh-invite path instead of
/// `acceptInvite`, so BOTH sides ended up having sent an INVITE — the exact "crossed invites, stuck in
/// a mutual loop" symptom this fix closes. Same shape as E1: real UI-facing state that needs to
/// survive a reload was kept only in memory.
public final class V2IncomingInviteStore {
    private var wires: [String: String] = [:]

    public init() { }

    public func get(_ chatId: String) -> String? {
        return wires[chatId]
    }

    public func set(_ chatId: String, wire: String) {
        wires[chatId] = wire
    }

    public func remove(_ chatId: String) {
        wires.removeValue(forKey: chatId)
    }

    // MARK: persistence

    public struct Snapshot: Codable {
        public var wires: [String: String]
    }

    public func toSnapshot() -> Snapshot {
        return Snapshot(wires: wires)
    }

    public static func fromSnapshot(_ snapshot: Snapshot) -> V2IncomingInviteStore {
        let store = V2IncomingInviteStore()
        store.wires = snapshot.wires
        return store
    }
}
