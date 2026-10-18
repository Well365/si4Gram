import Foundation

/// What a message whose text begins with `L1:` should look like, decided once with no I/O so the render hook
/// (PLAN.md 3.48.0 hook ②) can stay a thin wrapper: classify, then draw. Any text that is NOT an `L1:` reference
/// never reaches this type at all — the hook checks `RelayL1.isReference` first and falls back to the ordinary
/// renderer immediately, which is what keeps "no L1: message → identical to before" true regardless of settings.
public enum RelayCardState: Equatable {
    /// PLAN.md 3.48.7: the content already lives on this device — render it as itself, not as a card.
    case localCopy(RelayLocalCopy)
    case invalid(reasonCode: String)
    case receivingOff
    case unknownRelay(host: RelayHost, ref: RelayL1Reference)
    case insecureOrLAN(host: RelayHost, ref: RelayL1Reference)
    case ready(host: RelayHost, ref: RelayL1Reference)
}

public enum RelayRender {
    /// `localCopy` is a lookup the caller already did for this exact chat + message id (PLAN.md 3.48.7 — once
    /// saved, the local copy wins over everything else, including an expired/revoked/unreachable relay).
    ///
    /// `showCards` gates receiving independently of the global send switch (PLAN.md 3.48.4's receiving section
    /// has its own default): a correspondent who has relay sending on can still send `L1:` into a chat with a
    /// reader who never turned sending on, and that reader's own "show relay cards" choice is what should decide
    /// whether they see a card or plain "relay content" text — not whether they personally send that way.
    public static func classify(text: String, localCopy: RelayLocalCopy?, showCards: Bool, askUnknownRelay: Bool, allowInsecureOrLAN: Bool, isTrusted: (String) -> Bool) -> RelayCardState? {
        guard RelayL1.isReference(text) else { return nil }
        if let localCopy = localCopy { return .localCopy(localCopy) }

        switch RelayL1.parse(text) {
        case .failure(let error):
            return .invalid(reasonCode: error.reasonCode)
        case .success(let ref):
            guard let host = RelayHost.classify(ref.relayURL) else { return .invalid(reasonCode: "field:u") }
            guard showCards else { return .receivingOff }
            if (!host.isSecure || host.isLAN) && !allowInsecureOrLAN {
                return .insecureOrLAN(host: host, ref: ref)
            }
            if askUnknownRelay && !isTrusted(host.urlString) {
                return .unknownRelay(host: host, ref: ref)
            }
            return .ready(host: host, ref: ref)
        }
    }
}
