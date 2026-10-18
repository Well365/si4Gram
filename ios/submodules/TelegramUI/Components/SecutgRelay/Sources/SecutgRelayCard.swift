import Foundation
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// The render-hook and tap-handler glue for an `L1:` message (PLAN.md 3.48.0 hook ②, 3.48.7). Builds on
/// `RelayRender`/`RelayReceive`/`RelayDeletion` from `SecutgCore`; the only things this file adds are "how to
/// find this message's resolved plaintext" and "how to fetch, decrypt and save a reference" — both of which
/// need `TelegramCore` types `RelayRender` itself must not depend on.
public enum SecutgRelayCard {
    /// A short line this component can render in place of a message's raw text, with whether a tap on the
    /// message should run `resolve`/`fetch` again (a finished state like `.invalid`/`.receivingOff`/an already
    /// fetched image still offers a tap — the first to re-open the saved image, the others for no real action).
    public struct CardLine: Equatable {
        public let text: String
        public let isInteractive: Bool
    }

    // MARK: - What the message already is, no network

    /// The plaintext this message would show if the relay card were not drawn — i.e. exactly what the existing
    /// E1/E2/plaintext rendering already resolved it to, so a relay check never has to re-implement decryption.
    /// nil when the plaintext cannot be known right now (undecryptable / locked / a control or invite message,
    /// none of which can ever be an `L1:` reference in the first place).
    public static func resolvedText(message: Message, accountPeerId: PeerId) -> String? {
        guard let meta = message.secutgMeta else { return message.text }
        switch meta.kind {
        case .decrypted, .plaintext:
            return message.text
        case .sealed:
            if case let .opened(text, _)? = SecutgSealedText.render(message: message, accountPeerId: accountPeerId) {
                return text
            }
            return nil
        case .undecryptable, .control, .groupInvite:
            return nil
        }
    }

    /// Cheap existence check for the context-menu hook (PLAN.md 3.48.0 hook ⑥): true only for this account's
    /// own outgoing relay message, regardless of whether it classifies as a drawable card right now.
    public static func isOwnRelayMessage(context: AccountContext, message: Message) -> Bool {
        guard !message.flags.contains(.Incoming) else { return false }
        guard let text = resolvedText(message: message, accountPeerId: context.account.peerId) else { return false }
        return RelayL1.isReference(text)
    }

    public static func sentItem(context: AccountContext, message: Message) -> RelaySentItem? {
        let state = SecutgRelayRuntime.shared.accountState(context: context)
        return state.sentItem(chatId: SecutgRelayRuntime.chatKey(message.id.peerId), messageId: Int64(message.id.id))
    }

    /// The render hook's one call: nil means "this is not an `L1:` message at all — render it exactly as
    /// before" (PLAN.md 3.48.0 rule 3). Anything else is this component's own line.
    public static func cardLine(context: AccountContext, message: Message) -> CardLine? {
        guard let resolved = resolvedText(message: message, accountPeerId: context.account.peerId) else { return nil }
        guard let state = classify(context: context, message: message, resolvedText: resolved) else { return nil }
        return line(for: state)
    }

    private static func classify(context: AccountContext, message: Message, resolvedText: String) -> RelayCardState? {
        guard RelayL1.isReference(resolvedText) else { return nil }
        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
        let localCopy = accountState.localCopy(chatId: SecutgRelayRuntime.chatKey(message.id.peerId), messageId: Int64(message.id.id))
        let appConfig = SecutgRelayRuntime.shared.appState.current
        return RelayRender.classify(
            text: resolvedText, localCopy: localCopy, showCards: appConfig.settings.showCards,
            askUnknownRelay: appConfig.settings.askUnknownRelay, allowInsecureOrLAN: appConfig.settings.allowInsecureOrLAN,
            isTrusted: { appConfig.isTrusted(urlString: $0) })
    }

    /// SECUTG-HOOK (PLAN.md 3.48.7 gap e): the decoded local-copy image bytes for a message, if (and only if)
    /// this message currently classifies as an already-saved local IMAGE copy. No network, no new state — this
    /// just exposes what `line(for:)`'s own `.localCopy`/`.image` branch already has, for
    /// `ChatMessageTextBubbleContentNode`'s inline-image rendering hook. Anything else (a text local copy, not
    /// fetched yet, invalid, receiving off, an unknown/untrusted relay still waiting on confirmation, …) is nil,
    /// which that hook treats as "draw the existing text-only card line, unchanged".
    public static func localImageData(context: AccountContext, message: Message) -> Data? {
        guard let resolved = resolvedText(message: message, accountPeerId: context.account.peerId),
              let state = classify(context: context, message: message, resolvedText: resolved) else { return nil }
        guard case let .localCopy(copy) = state, copy.contentType == .image else { return nil }
        return copy.imageData
    }

    private static func line(for state: RelayCardState) -> CardLine {
        switch state {
        case .localCopy(let copy):
            switch copy.contentType {
            case .text: return CardLine(text: copy.text ?? "", isInteractive: false)
            case .image: return CardLine(text: SecutgL10n.string("SecutgRelayCardImage", ["size": byteSize(copy.imageData?.count ?? 0)]), isInteractive: true)
            }
        case .invalid: return CardLine(text: SecutgL10n.string("SecutgRelayInvalid"), isInteractive: false)
        case .receivingOff: return CardLine(text: SecutgL10n.string("SecutgRelayReceiveOff"), isInteractive: false)
        case .unknownRelay(let host, _): return CardLine(text: SecutgL10n.string("SecutgRelayCardUnknown", ["host": host.host]), isInteractive: true)
        case .insecureOrLAN: return CardLine(text: SecutgL10n.string("SecutgRelayCardBlocked"), isInteractive: false)
        case .ready(let host, let ref):
            let kindLine = ref.contentType == .text
                ? SecutgL10n.string("SecutgRelayCardText", ["size": byteSize(ref.sizeBytes)])
                : SecutgL10n.string("SecutgRelayCardImage", ["size": byteSize(ref.sizeBytes)])
            let fromLine = SecutgL10n.string("SecutgRelayCardFrom", ["host": host.host])
            return CardLine(text: "\(kindLine) · \(fromLine) · \(SecutgL10n.string("SecutgRelayCardOpen"))", isInteractive: true)
        }
    }

    // MARK: - Tap flow (network only happens from here)

    public enum TapStep {
        /// Already on this device; `imageData` nil for text.
        case localReady(text: String?, imageData: Data?)
        case invalid
        case receivingOff
        case insecureOrLANBlocked
        /// Caller should confirm with the user (unknown relay, and/or "can only be read N times") before
        /// calling `proceed`. `isUnknownRelay` / `limitedReads` say which disclosures apply; both may be true.
        case needsConfirmation(host: RelayHost, isUnknownRelay: Bool, limitedReads: Int, trustHost: Bool, proceed: (_ trustThisHost: Bool) -> Void)
        case fetching
        case fetchFailed(String)
        case gone
    }

    /// First call for a tap: resolves to either an immediate result or a confirmation the caller must show.
    public static func beginTap(context: AccountContext, message: Message, completion: @escaping (TapStep) -> Void) {
        guard let resolved = resolvedText(message: message, accountPeerId: context.account.peerId),
              let state = classify(context: context, message: message, resolvedText: resolved) else {
            completion(.invalid)
            return
        }
        switch state {
        case .localCopy(let copy):
            completion(.localReady(text: copy.text, imageData: copy.imageData))
        case .invalid:
            completion(.invalid)
        case .receivingOff:
            completion(.receivingOff)
        case .insecureOrLAN:
            completion(.insecureOrLANBlocked)
        case .unknownRelay(let host, let ref):
            completion(.needsConfirmation(host: host, isUnknownRelay: true, limitedReads: ref.maxReads, trustHost: false, proceed: { trust in
                fetch(context: context, message: message, host: host, ref: ref, trustHost: trust, completion: completion)
            }))
        case .ready(let host, let ref):
            if ref.maxReads > 0 {
                completion(.needsConfirmation(host: host, isUnknownRelay: false, limitedReads: ref.maxReads, trustHost: false, proceed: { _ in
                    fetch(context: context, message: message, host: host, ref: ref, trustHost: false, completion: completion)
                }))
            } else {
                fetch(context: context, message: message, host: host, ref: ref, trustHost: false, completion: completion)
            }
        }
    }

    private static func fetch(context: AccountContext, message: Message, host: RelayHost, ref: RelayL1Reference, trustHost: Bool, completion: @escaping (TapStep) -> Void) {
        completion(.fetching)
        if trustHost {
            SecutgRelayRuntime.shared.appState.update { $0 = $0.trusting(urlString: host.urlString, atMs: Int64(Date().timeIntervalSince1970 * 1000)) }
        }
        SecutgRelayRuntime.shared.client.get(baseURL: host.urlString, id: ref.id, expectedPlaintextBytes: ref.sizeBytes, isEncrypted: ref.contentKey != nil) { result in
            switch result {
            case .failure(.http(404, _, _)):
                DispatchQueue.main.async { completion(.gone) }
            case .failure(.decode):
                // PLAN.md review HIGH-2: a response whose final length didn't match this reference's own `n`
                // is corrupted/truncated/tampered — the same user-facing outcome as a decrypt failure below,
                // reusing its existing string rather than inventing a new one.
                DispatchQueue.main.async { completion(.fetchFailed(SecutgL10n.string("SecutgRelayDecryptFailed"))) }
            case .failure(let error):
                DispatchQueue.main.async { completion(.fetchFailed("\(error)")) }
            case .success(let body):
                guard let plaintext = RelayReceive.open(ref: ref, fetchedBody: body) else {
                    DispatchQueue.main.async { completion(.fetchFailed(SecutgL10n.string("SecutgRelayDecryptFailed"))) }
                    return
                }
                let accountState = SecutgRelayRuntime.shared.accountState(context: context)
                let chatKey = SecutgRelayRuntime.chatKey(message.id.peerId)
                switch ref.contentType {
                case .text:
                    let text = String(decoding: plaintext, as: UTF8.self)
                    accountState.saveLocalCopy(RelayLocalCopy(chatId: chatKey, messageId: Int64(message.id.id), contentType: .text, mime: ref.mime, text: text, imageData: nil, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000), direction: .received))
                    DispatchQueue.main.async { completion(.localReady(text: text, imageData: nil)) }
                case .image:
                    accountState.saveLocalCopy(RelayLocalCopy(chatId: chatKey, messageId: Int64(message.id.id), contentType: .image, mime: ref.mime, text: nil, imageData: plaintext, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000), direction: .received))
                    DispatchQueue.main.async { completion(.localReady(text: nil, imageData: plaintext)) }
                }
            }
        }
    }

    private static func byteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}
