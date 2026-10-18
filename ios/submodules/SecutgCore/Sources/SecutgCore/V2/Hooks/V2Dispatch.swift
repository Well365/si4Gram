import Foundation

/// The real send/receive surface v1's `SecutgAccountRuntime.prepareOutgoing`/`transformIncoming`
/// call into FIRST, before falling through to their own existing v1 logic unchanged (Web integration
/// draft's `hooks/dispatch.ts` iOS analog). v1/v2 coexistence decision: a chat is "on v2" purely by
/// DATA, never by a global switch — `prepareOutgoingText` checks whether `V2PersistedState` already
/// holds a current v2 binding/group state for this exact `chatId`; if not, it reports `.notOnV2` and
/// the caller's existing v1 path runs exactly as it did before this file existed. Since nothing in
/// this codebase yet BOOTSTRAPS a v2 pairing/group from the real UI (`V2Bootstrap.initV2Worker` is
/// not called from any real app-startup path in this slice), every existing chat stays on v1 today —
/// this dispatcher is additive and inert until v2 pairing actually produces a binding, never a
/// retroactive reinterpretation of existing v1 chats.
///
/// Scoped to E2 business ciphertext only, the direct analog of v1's `E1Codec` (`E1:`) — NOT v2's
/// control-message families (P2/N2/W2). Those need their own render surface, wired separately once
/// there is a real UI trigger to hang it on; encoding one now, with no caller, would be exactly the
/// kind of "pin a shape nothing has settled yet" risk `V2Processor`'s own module doc already warns
/// against for the section 31 ceremony.
public enum V2OutgoingDispatch: Equatable {
    case notOnV2
    case sent(wire: String)
    case failed(reason: String)
}

public enum V2IncomingDispatch: Equatable {
    case notV2
    case decrypted(text: String)
    case failed(reason: String)
}

public enum V2Dispatch {
    /// Send-side. `chatId` starting with `-` (Telegram's own convention, matching
    /// `SharedChatId`/`V2GroupMessaging`) is a group; the runtime's two messaging classes are tried
    /// in that order, matching how v1's own hooks never need the caller to say which. Only ever
    /// called for plain text with no entities (`V2DataProcessor` takes plaintext bytes only, no
    /// entities yet) — the caller is responsible for that scoping, the same way the Web reference's
    /// `hooks/outgoing.ts` gates its own call site.
    public static func prepareOutgoingText(accountKey: String, chatId: String, text: String) -> V2OutgoingDispatch {
        // SECUTG-HOOK (fix, 2026-09-27): a protocol wire is never business text. Checked before any
        // group/binding lookup because a bound chat used to wrap EVERYTHING in E2 — including this
        // app's own `P2:` control wires (ROSTER_COMMIT from 换新密钥, ACCEPT/SELECT/CONFIRM/READY when
        // re-pairing a bound chat) and v1's R1/P1/U1/N1/G2. The peer then decrypted it as a chat message
        // and never processed it; for rekey the sender had already moved to the new epoch, so the peer
        // was left on `missing_key` for good. `.notOnV2` hands it back to the caller's own passthrough.
        if isProtocolWire(text) { return .notOnV2 }
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        let plaintext = V2Suite.utf8(text)
        if chatId.hasPrefix("-") {
            guard runtime.persisted.groupStateStore.current(chatId) != nil else { return .notOnV2 }
            let outcome = runtime.groupMessaging.send(chatId, plaintext: plaintext)
            guard outcome.ok, let wire = outcome.wire else { return .failed(reason: outcome.reason ?? "unknown") }
            // SECUTG-HOOK (fix E1): persist once this real send finishes — matching every other real
            // dispatch entry point in this file and in `V2PairingDispatch`.
            runtime.persisted.persist()
            return .sent(wire: wire)
        }
        guard runtime.persisted.bindingStore.current(chatId) != nil else { return .notOnV2 }
        let outcome = runtime.privateMessaging.send(chatId, plaintext: plaintext)
        guard outcome.ok, let wire = outcome.wire else { return .failed(reason: outcome.reason ?? "unknown") }
        runtime.persisted.persist()
        return .sent(wire: wire)
    }

    /// SECUTG-HOOK (fix 2026-10-07, PLAN.md 3.0 fail closed): the pure decision both clients' send
    /// entry points (`SecutgRuntime.prepareOutgoing`, iOS and macOS) must make — extracted here
    /// because neither copy of that function has a test target of its own (`TelegramCore` has none).
    /// Real-device bug: a message carrying auto-detected entities (a `@mention` or `#hashtag`) used to
    /// skip v2 entirely at the call site (`if entities.isEmpty`) and fall through to v1's own
    /// `isChatEncrypted` check, which is false for a v2-only chat — the message went out in the CLEAR.
    /// `entities` must never gate whether v2 is even asked: v2's wire carries plain text only, so
    /// entities are dropped (auto-detectable ones are re-detected by the receiving client from the
    /// plain text; explicit formatting is lost) — never a reason to send plaintext. Defence in depth:
    /// a chat with a live v2 binding/group state that still answers `.notOnV2` for non-protocol text
    /// (`isOnV2` and `prepareOutgoingText` disagreeing) fails closed rather than falling through to a
    /// caller's v1 passthrough.
    public static func prepareOutgoingTextFailClosed(accountKey: String, chatId: String, text: String) -> V2OutgoingDispatch {
        guard !text.isEmpty else { return .notOnV2 }
        let result = prepareOutgoingText(accountKey: accountKey, chatId: chatId, text: text)
        guard case .notOnV2 = result else { return result }
        if isOnV2(accountKey: accountKey, chatId: chatId), !isProtocolWire(text) {
            return .failed(reason: "v2_bound_but_not_claimed")
        }
        return .notOnV2
    }

    private static let e2Prefix = "E2:"


    /// SECUTG-HOOK (fix, 2026-09-27): every wire family that must travel exactly as built, never inside an
    /// E2 envelope — v2's own P2/E2/N2/W2, v1's E1 ciphertext, and (via `Rekey.isControlMessage`) v1's
    /// R1/P1/U1/N1/G2 control lines. Judged by STRUCTURE, never by prefix alone (review finding): a user
    /// who types "E1: hi" or "P2: …" into an encrypted chat is writing text, and a prefix test would have
    /// sent those words in the clear.
    public static func isProtocolWire(_ text: String) -> Bool {
        return isP2Wire(text)
            || V2E2.parse(text) != nil
            || V2Envelope.parse(prefix: V2GroupMessages.prefix, text: text) != nil
            || V2W2.parseW2(text) != nil
            || E1Format.isEncrypted(text)
            || Rekey.isControlMessage(text)
    }

    /// A structurally valid P2 envelope (signature not checked).
    public static func isP2Wire(_ text: String) -> Bool {
        return V2Envelope.parse(prefix: V2Messages.prefix, text: text) != nil
    }

    /// Render-side. Anything not starting with `E2:` is not this dispatcher's concern — v1's own
    /// `E1Format.isEncrypted`/`E1:` check and everything else runs exactly as before.
    public static func decryptIncomingText(accountKey: String, chatId: String, wireText: String) -> V2IncomingDispatch {
        return decrypt(accountKey: accountKey, chatId: chatId, wireText: wireText, persistAfter: true)
    }

    // MARK: PLAN.md 3.44 — a v2 row the database holds as its envelope (3.19 extended to v2)

    /// The same receive function again, for a row the database holds as its `E2:` wire and a render funnel has
    /// to open — after a restart, when the session's plaintext cache is empty, or after the cache evicted it.
    /// Opening the same E2 twice is idempotent: the data key is a pure function of persisted state (master,
    /// binding / state hash, sender device), and `V2DataProcessor`'s replay index answers a wire this process has
    /// already opened with the very same plaintext (`"duplicate"`) rather than refusing it, so nothing here needs
    /// a way around the replay guard and the guard keeps its full strength for genuinely incoming traffic. The
    /// one difference from `decryptIncomingText` is that nothing is persisted afterwards: a draw is not an event.
    public static func openStoredText(accountKey: String, chatId: String, wireText: String) -> V2IncomingDispatch {
        return decrypt(accountKey: accountKey, chatId: chatId, wireText: wireText, persistAfter: false)
    }

    private static func decrypt(accountKey: String, chatId: String, wireText: String, persistAfter: Bool) -> V2IncomingDispatch {
        guard wireText.hasPrefix(e2Prefix) else { return .notV2 }
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .failed(reason: "v2_not_ready") }

        let isGroup = chatId.hasPrefix("-")
        // SECUTG-HOOK (fix C0, 2026-09-27): a private chat's binding is looked up under THIS device's own
        // chat id (`chatId` here), never the header's — that is the sender's view of the chat.
        let outcome = isGroup ? runtime.groupMessaging.receive(wireText) : runtime.privateMessaging.receive(wireText, localChatId: chatId)
        guard outcome.ok, let plaintext = outcome.plaintext else { return .failed(reason: outcome.reason ?? "unknown") }
        guard let text = V2Suite.fromUtf8(plaintext) else { return .failed(reason: "malformed_utf8") }
        // SECUTG-HOOK (fix E1): persist once this real receive finishes — see `prepareOutgoingText`'s
        // own note above. Today's dedup/outbox bookkeeping this touches is out of persistence scope
        // (`V2PersistedState`'s own doc), so this call is a currently-harmless no-op save; it is here
        // so the wiring is already in place the moment that bookkeeping grows a snapshot of its own.
        if persistAfter { runtime.persisted.persist() }
        return .decrypted(text: text)
    }

    /// PLAN.md 3.44 rule 1: is this chat on v2 by DATA — a current binding for a private chat, a current group
    /// state for a group (a chat id starting with `-`)? The same test `prepareOutgoingText` makes before it claims
    /// a message, so the chats whose rows are sealed as `E2:` are exactly the chats that send `E2:`.
    public static func isOnV2(accountKey: String, chatId: String) -> Bool {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return false }
        if chatId.hasPrefix("-") { return runtime.persisted.groupStateStore.current(chatId) != nil }
        return runtime.persisted.bindingStore.current(chatId) != nil
    }

    /// PLAN.md 3.44 rule 1: does a v2 chat keep only the envelope on this disk? PLAN.md 3.19's switch
    /// (`localCiphertext`, on unless the user turned it off) and the chat being on v2 — the v2 counterpart of
    /// `KeyRing.keepsCiphertextLocally`, which only ever knows v1's own chat flag. A chat that is not on v2 answers
    /// false here whatever the switch says: its rows are v1's business, or nobody's.
    public static func keepsCiphertextLocally(accountKey: String, chatId: String, localCiphertext: Bool) -> Bool {
        return localCiphertext && isOnV2(accountKey: accountKey, chatId: chatId)
    }

    /// PLAN.md 3.44 rule 2 / 3.17 rule 1: which of the three 3.17 situations a v2 refusal is, in the vocabulary
    /// the notice already reads (`DecryptResult.Reason` raw values plus `not_ready`), so a sealed v2 row whose
    /// binding is gone draws the same line as a v1 row whose key is gone — never the reason code, never base64.
    /// - the runtime is not up yet → `not_ready` (「正在解锁…」, a moment)
    /// - the wire itself is not to be trusted — its signature, its ciphertext, a sender the generation never
    ///   admitted → `auth_failed`; its shape → `malformed` (both 「可能被改动过」)
    /// - anything else — no binding, no state, no key for that generation, a sender device not yet known →
    ///   `unknown_key` (「本机没有对应密钥」)
    public static func storedFailureDetail(reason: String) -> String {
        switch reason {
        case "v2_not_ready":
            return "not_ready"
        case "bad_signature", "decrypt_failed", "sender_not_in_roster":
            return DecryptResult.Reason.authFailed.rawValue
        case "malformed", "malformed_utf8", "malformed_sender_key", "malformed_binding", "malformed_state":
            return DecryptResult.Reason.malformed.rawValue
        default:
            return DecryptResult.Reason.unknownKey.rawValue
        }
    }
}
