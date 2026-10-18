import Foundation
import Postbox
import SwiftSignalKit
import SecutgCore

/// SECUTG (feature, 2026-09-28, PLAN.md 3.38.2): where a group stands with its password GATE on this device. The
/// gate is the `GP1` policy; it never decides whether a message decrypts.
public enum SecutgGroupPasswordState: Equatable {
    /// No policy, or the admin turned it off.
    case none
    /// Policy on and this run has not been given the password: page, masking, no sending, 3.19 forced.
    case locked
    /// Policy on and this run checked the password against it.
    case unlocked

    public var isGated: Bool { return self == .locked }
    /// The policy is on (the admin menu offers 〔修改〕/〔关闭〕 rather than 〔设置〕).
    public var isActive: Bool { return self == .locked || self == .unlocked }
}

/// SECUTG (PLAN.md 3.38.1): the answer to one password attempt.
public enum SecutgGroupPasswordUnlock: Equatable {
    case unlocked
    /// 「密码不对或数据已损坏」 — every refusal reads the same (3.38).
    case wrong
    case tooMany(seconds: Int64)
    case noRecord
}

/// SECUTG (PLAN.md 3.38.1): the stored-detail value the receive hook writes, and the sealed-text reader returns,
/// for a message of a group whose password this run has not been given. `SecutgUndecryptableLine` draws it as
/// 「🔒 需要群密码」.
public let secutgGroupPasswordLockedDetail = "group_pw_locked"

extension SecutgAccountRuntime {
    static let groupPasswordLimiterStore = SecutgGroupPasswordLimiters()

    var groupPasswordLimiter: GroupPasswordAttemptLimiter {
        return SecutgAccountRuntime.groupPasswordLimiterStore.limiter(for: accountPeerId)
    }

    func groupPasswordState(chat: String) -> SecutgGroupPasswordState {
        guard ring.isGroupPasswordOn(chat) else { return .none }
        return ring.needsGroupPassword(chat) ? .locked : .unlocked
    }

    public func groupPasswordState(chatPeerId: PeerId) -> SecutgGroupPasswordState {
        guard chatPeerId.namespace == Namespaces.Peer.CloudGroup || chatPeerId.namespace == Namespaces.Peer.CloudChannel else {
            return .none
        }
        return groupPasswordState(chat: SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// PLAN.md 3.38.2 上锁: the full-screen password page goes up, previews / notifications / sealed rows are
    /// masked, sending is refused.
    public func needsGroupPassword(chatPeerId: PeerId) -> Bool {
        return groupPasswordState(chatPeerId: chatPeerId).isGated
    }

    /// LEGACY (3.38.1): a locked record from the retired `pw=1` `G2` is on file and not opened in this run, so the
    /// history it wraps cannot be read yet. Offers 〔解锁〕 in the menu; it does not gate the chat.
    public func needsLegacyGroupPassword(chatPeerId: PeerId) -> Bool {
        guard chatPeerId.namespace == Namespaces.Peer.CloudGroup || chatPeerId.namespace == Namespaces.Peer.CloudChannel else {
            return false
        }
        return ring.needsLegacyGroupPassword(SecutgAccountRuntime.chatKey(chatPeerId))
    }

    /// PLAN.md 3.38.2 解锁 (the policy while it locks the group, else a legacy record). Runs Argon2id (64 MiB): call
    /// it OFF the main thread. On success the group's waiting rows are swept through `keysChanged` (3.17) — a
    /// legacy unlock brings masters; a policy unlock brings none but the sweep is harmless.
    /// `legacy`: the menu's 〔解锁〕 for a 3.38.1 locked record — tried against that record even while the policy
    /// also locks the group.
    public func unlockGroupPassword(chatPeerId: PeerId, password: String, legacy: Bool = false) -> SecutgGroupPasswordUnlock {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        let result = legacy
            ? GroupPasswordSession.unlockLegacy(ring: ring, limiter: groupPasswordLimiter, chatId: chat, password: password)
            : GroupPasswordSession.unlock(ring: ring, limiter: groupPasswordLimiter, chatId: chat, password: password)
        switch result {
        case .unlocked:
            keysChanged.putNext(chatPeerId)
            groupPasswordChanged.putNext(chatPeerId) // SECUTG-HOOK (fix, 2026-09-29, review H1): the gate came down
            return .unlocked
        case .wrong:
            return .wrong
        case let .tooMany(seconds):
            return .tooMany(seconds: seconds)
        case .noRecord:
            return .noRecord
        }
    }

    /// PLAN.md 3.38.2 〔设置群密码〕/〔修改群密码〕: ONE `GP1` on (fresh salt). No rebuild, no `N1`, no `G2`.
    /// Argon2id: OFF the main thread. The caller sends `broadcast`, dropping the local cache first when
    /// `turnedOn` (the admin's device adopts it too).
    public func setGroupPassword(chatPeerId: PeerId, password: String) throws -> GroupPasswordSession.PolicyBuilt {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        return try GroupPasswordSession.setPassword(ring: ring, chatId: chat, ownUserId: ownUserId, password: password,
                                                    at: Int64(Date().timeIntervalSince1970))
    }

    /// PLAN.md 3.38.2 〔关闭群密码〕: ONE `GP1` off. The keys are untouched.
    public func disableGroupPassword(chatPeerId: PeerId) throws -> GroupPasswordSession.PolicyBuilt {
        let chat = SecutgAccountRuntime.chatKey(chatPeerId)
        return try GroupPasswordSession.disablePassword(ring: ring, chatId: chat, ownUserId: ownUserId,
                                                        at: Int64(Date().timeIntervalSince1970))
    }

    /// 3.19 reader for a sealed row that knows which chat it is in. PLAN.md 3.38.2: while the group is locked the
    /// row reads 「需要群密码」 WITHOUT being opened (masking, not crypto — the key is right here); a legacy record
    /// not yet opened explains a row that really cannot be opened.
    public func openSealed(wire: String, chatPeerId: PeerId) -> Opened {
        if needsGroupPassword(chatPeerId: chatPeerId) { return .locked(detail: secutgGroupPasswordLockedDetail) }
        // PLAN.md 3.44: the chat goes along — a v2 row's binding is filed under this device's own name for the chat.
        let opened = openSealed(wire: wire, chat: SecutgAccountRuntime.chatKey(chatPeerId))
        if case .locked = opened, needsLegacyGroupPassword(chatPeerId: chatPeerId) {
            return .locked(detail: secutgGroupPasswordLockedDetail)
        }
        return opened
    }

    /// Render-side mask (chat list preview, in-app banner): the sentence to show instead of the message, or nil
    /// when the chat is not gated.
    public static func groupPasswordMaskedPreview(accountPeerId: PeerId, chatPeerId: PeerId) -> String? {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId),
              runtime.needsGroupPassword(chatPeerId: chatPeerId) else { return nil }
        return SecutgL10n.string("SecutgGroupPwLockedPreview")
    }
}

/// One attempt limiter per account, kept outside the runtime so the runtime's stored layout is untouched.
final class SecutgGroupPasswordLimiters {
    private let lock = NSLock()
    private var limiters: [PeerId: GroupPasswordAttemptLimiter] = [:]

    func limiter(for accountPeerId: PeerId) -> GroupPasswordAttemptLimiter {
        lock.lock(); defer { lock.unlock() }
        if let existing = limiters[accountPeerId] { return existing }
        let created = GroupPasswordAttemptLimiter()
        limiters[accountPeerId] = created
        return created
    }
}

/// SECUTG (PLAN.md 3.38.2, first adoption of an "on" policy; was 3.38.1 member rule 2): drop this group's LOCAL message cache so the history is fetched from the
/// server again, as ciphertext. Local only — `Transaction.clearHistory` never talks to the server (the server-side
/// delete is a separate, explicit operation this never calls) — followed by the same whole-range hole
/// `AccountViewTracker` adds for a peer it has to re-fetch, so the history view loads it back.
public func secutgDropLocalHistory(postbox: Postbox, peerId: PeerId) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil,
                                 namespaces: .just(Set([Namespaces.Message.Cloud])), forEachMedia: nil)
        transaction.addHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere,
                            range: 1 ... (Int32.max - 1))
    }
    |> ignoreValues
}

/// SECUTG (PLAN.md 3.38.1 member rule 4): after an unlock, every row of the group stored sealed (3.19) is laid out
/// again so it reads its words from the key that just arrived. Same in-place, same-content write as
/// `secutgRefreshMessage`: only the stable version moves.
public func secutgRefreshSealedRows(postbox: Postbox, peerId: PeerId) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        var ids: [MessageId] = []
        transaction.withAllMessages(peerId: peerId, { message in
            if message.secutgMeta?.kind == .sealed { ids.append(message.id) }
            return true
        })
        for id in ids {
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
    }
    |> ignoreValues
}
