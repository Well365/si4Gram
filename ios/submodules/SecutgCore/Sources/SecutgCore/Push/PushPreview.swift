import Foundation

/// PLAN.md 3.42: what a push notification may show of a message that travelled in one of secuTG's wire formats.
///
/// The notification process holds no key and never will (3.42 rule 1: moving the keyring into it means a shared
/// Keychain group and the whole runtime, a wider attack surface for a few more characters in a banner). So the
/// body is **masked**, never decrypted: encrypted content becomes 「🔒 加密消息」 (`SecutgPushEncrypted`), any other
/// protocol line becomes 「🔐 加密聊天的系统消息」 (`SecutgPushControl`), ordinary text is left alone. Title, badge
/// and sound are not this file's business and do not change.
///
/// Recognition reuses the wire classifiers the clients already have — `E1Format`, `V2E2`, `G2`, `V2Dispatch.
/// isProtocolWire`, `GroupInvite` — rather than a second copy of the prefix table (3.42 rule 1). The one thing
/// added on top is a truncation guard: a server may cut a long body short, and a cut-off envelope no longer parses,
/// so a body that merely *starts* like one of the long families (by their own prefix constants) is masked too.
/// The cost is that a person who types "E2: hi" sees a placeholder in the banner and the real words in the app;
/// the alternative was a banner full of ciphertext, which is what this section exists to stop.
///
/// Pure, and byte-identical on the two Apple clients. The strings themselves are the caller's: SecutgCore holds no
/// table, so `mask` takes the two placeholders and returns the finished body.
public enum PushPreview {
    public enum Kind: Equatable {
        /// Ordinary text: shown as it is.
        case plain
        /// E1 / E2 content, or the auto-mode group key travelling sealed in the chat (G2) → `SecutgPushEncrypted`.
        case encryptedContent
        /// Every other protocol line — P2 / N2 / W2 / GP1 / N1 / U1 / R1 / P1 / G1 … → `SecutgPushControl`.
        case controlLine
    }

    /// The kind of ONE message text as it left the sender (no author prefix).
    public static func classify(_ text: String) -> Kind {
        if E1Format.isEncrypted(text) || V2E2.parse(text) != nil || G2.isG2(text) { return .encryptedContent }
        if V2Dispatch.isProtocolWire(text) || GroupInvite.isG1(text) { return .controlLine }
        return truncatedKind(text) ?? .plain
    }

    /// The truncation guard: a body cut short by the server no longer parses, but still starts with the family's
    /// own prefix. Only families whose lines are long enough to be cut, and only through the constants those
    /// families already export — this is not a second prefix table.
    private static func truncatedKind(_ text: String) -> Kind? {
        let families: [(prefix: String, kind: Kind)] = [
            (E1Format.prefix + ":", .encryptedContent),
            (V2E2.prefix + ":", .encryptedContent),
            (V2Messages.prefix + ":", .controlLine),
            (V2GroupMessages.prefix + ":", .controlLine),
            (V2W2.prefix + ":", .controlLine),
            (GroupInvite.prefix, .controlLine),
        ]
        for family in families where text.hasPrefix(family.prefix) && text.utf16.count > family.prefix.utf16.count {
            return family.kind
        }
        return nil
    }

    /// Where the wire text starts inside a notification body, and what kind it is.
    ///
    /// A push body is the text itself in a private chat and `Sender: text` in a group, and a sender's name may
    /// itself contain ": " — so the text is tried from the start of the body and from after every ": " (the first
    /// few), and the first position that is not plain text wins. Everything before it is the part to keep.
    public static func locate(in body: String) -> (kind: Kind, textStart: String.Index)? {
        var candidates: [String.Index] = [body.startIndex]
        var searchFrom = body.startIndex
        while candidates.count <= maxAuthorSeparators, let range = body.range(of: ": ", range: searchFrom ..< body.endIndex) {
            candidates.append(range.upperBound)
            searchFrom = range.upperBound
        }
        for start in candidates {
            let kind = classify(String(body[start...]))
            if kind != .plain { return (kind, start) }
        }
        return nil
    }

    /// How many `Sender: ` separators are tried. A wire family's own text never contains ": ", so a real hit is
    /// always within the first few; the bound only keeps a pathological body cheap.
    private static let maxAuthorSeparators = 8

    /// The notification body to show: `body` itself for ordinary text, otherwise everything before the wire text
    /// (the sender's name in a group) followed by the placeholder for its kind.
    public static func mask(body: String, encrypted: String, control: String) -> String {
        guard let hit = locate(in: body) else { return body }
        let prefix = String(body[..<hit.textStart])
        switch hit.kind {
        case .plain: return body
        case .encryptedContent: return prefix + encrypted
        case .controlLine: return prefix + control
        }
    }
}
