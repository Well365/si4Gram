import Foundation

/// What a pasted or opened blob of text actually is (PLAN.md 3.6 / 3.14).
///
/// Two import dialogs take free text: the offline one wants a `secutg://key?…` payload, the
/// keyring-transfer one wants a `K1:` container. They look nothing alike, but their titles read almost
/// the same, so pasting one into the other is the mistake a user actually makes — and today the only
/// answer is a generic "not a valid payload" that points nowhere.
///
/// Classification is pulled out here, as a pure function with no UI attached, for one reason: unless
/// every client agrees on what a given text *is*, they cannot possibly agree on what to say about it.
/// This is the function the cross-client `k1` vectors pin down.
public enum ImportTextKind: String, Equatable {
    case k1
    case keyPayload
    case unknown
}

public enum ImportText {
    /// Never throws and never guesses beyond what the two formats actually promise: `K1:` decides on the
    /// prefix alone (whether the container opens is the transfer code's business, not this function's),
    /// while a key payload has to parse into a real 32-byte master before it counts as one.
    public static func classify(_ text: String) -> ImportTextKind {
        if TransferBundle.isTransferBundle(text) { return .k1 }
        if KeyPayload.parse(text) != nil { return .keyPayload }
        return .unknown
    }
}
