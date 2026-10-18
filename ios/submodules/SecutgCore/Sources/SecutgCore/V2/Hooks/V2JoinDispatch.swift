import Foundation

/// PLAN.md 3.39.13: the UI-facing entry points of "share this 1v1 chat to my other device by QR" (clone mode),
/// mirroring the shape of `V2PairingDispatch.startPairing` / `unpair` / `rekey` — look the account's `V2Runtime` up,
/// run the coordinator, persist once a real state change is done. Every outcome fails closed to `.notOnV2` for an
/// account with no runtime. Kept in its own file for the same file-size reason `V2PairingLine` is.
///
/// Nothing is ever sent: the showing device writes nothing, the scanning device installs and is done.
extension V2PairingDispatch {
    public enum JoinShareOutcome: Equatable {
        case notOnV2
        /// no current, sendable v2 binding on this chat (`SecutgV2JoinNotPaired`)
        case notPaired
        /// even the current master alone does not fit a QR (`SecutgQuickShareTooLarge`)
        case tooLarge
        case failed(reason: String)
        case shown(V2JoinCoordinator.Share)
    }

    public enum JoinInspectOutcome: Equatable {
        case notOnV2
        case refused(V2JoinCoordinator.ImportRefusal)
        case ok(V2JoinCoordinator.Inspection)
    }

    public enum JoinInstallOutcome: Equatable {
        case notOnV2
        case refused(V2JoinCoordinator.ImportRefusal)
        /// Installed: the chat reads and sends from now on. Nothing to send.
        case installed
    }

    /// Showing device: the code. Writes nothing (3.39.13: 「O 出码时什么都不写」).
    public static func prepareJoinShare(accountKey: String, chatId: String) -> JoinShareOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        switch runtime.join.prepareShare(chatId: chatId) {
        case .notPaired: return .notPaired
        case .tooLarge: return .tooLarge
        case let .failed(reason): return .failed(reason: reason)
        case let .ok(share): return .shown(share)
        }
    }

    /// Scanning device: the manifest, nothing written.
    public static func inspectJoin(accountKey: String, chatId: String, text: String) -> JoinInspectOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        switch runtime.join.inspect(text, chatId: chatId) {
        case let .refused(refusal): return .refused(refusal)
        case let .ok(inspection): return .ok(inspection)
        }
    }

    /// Scanning device: installs the clone binding and every master the code carried, persists.
    public static func installJoin(accountKey: String, chatId: String, text: String) -> JoinInstallOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        switch runtime.join.install(text, chatId: chatId) {
        case let .refused(refusal):
            return .refused(refusal)
        case .ok:
            // SECUTG-HOOK (fix, 2026-10-01 真机): the chat is the showing device's from now on — no cached invite, no
            // transaction of this device's own is left to offer 〔同意配对〕 or 等待对方同意 over the paired state.
            V2PairingDispatch.settleChatAfterClone(runtime, chatId: chatId)
            runtime.persisted.persist()
            return .installed
        }
    }
}
