import Foundation

/// PLAN.md 3.14.1, import side (2026-09-28 decision): Saved Messages is the one chat a quick share rebinds outright.
///
/// Every device makes its own Saved Messages key the first time it sees the account (3.20), so a second device
/// always *has* a binding by the time the user scans the first one's QR — and it is usually the newer of the two,
/// which the ordinary 3.14 "never roll a newer binding back" rule would keep. Then the two devices keep writing
/// Saved Messages under different keys and neither reads the other, which is the very thing the QR was scanned to
/// fix. So for Saved Messages the scanned key becomes the sending key, and the local one stays in the keyring as a
/// read-only history key: nothing this device wrote before becomes unreadable. Groups keep the normal merge.
extension QuickShare {
    /// The binding a quick-share import forces, or nil when the payload is not exactly Saved Messages.
    public static func savedMessagesTakeover(_ payload: TransferPayload, savedChatId: String) -> (masterId: String, label: String?)? {
        guard payload.scope == .chat, payload.chatIds == [savedChatId],
              let masterId = payload.snapshot.chatMasters[savedChatId], payload.snapshot.masters[masterId] != nil else { return nil }
        return (masterId, payload.snapshot.chatKeyLabels[savedChatId])
    }
}

extension KeyRing {
    /// The ordinary 3.14 merge (never an identity: a quick share carries none), then the Saved Messages takeover of
    /// `QuickShare.savedMessagesTakeover`. The replaced master is left in `masters` and in the chat's
    /// `chatMasterHistory`, so it keeps opening what it encrypted.
    @discardableResult
    public func mergeQuickShare(_ payload: TransferPayload, savedChatId: String) -> KeyRingMergeResult {
        var result = mergeSnapshot(payload.snapshot, replaceIdentity: false)
        guard let takeover = QuickShare.savedMessagesTakeover(payload, savedChatId: savedChatId),
              chatMasterId(savedChatId) != takeover.masterId else { return result }
        do {
            try setChatMaster(chatId: savedChatId, masterId: takeover.masterId, label: takeover.label)
        } catch {
            // the master did not survive sanitising: leave the local binding exactly as the merge left it
            return result
        }
        setChatEncryption(chatId: savedChatId, enabled: true)
        result.skippedChats.removeAll { $0 == savedChatId }
        if !result.boundChats.contains(savedChatId) { result.boundChats.append(savedChatId) }
        return result
    }
}
