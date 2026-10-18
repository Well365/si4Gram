import Foundation

/// The one spelling of a conversation id that every secuTG client has to agree on (PLAN.md 3.0).
///
/// It is not a display id and not Telegram's own `PeerId`: it is the string that keys a chat inside the
/// keyring snapshot, travels in a `G1` group invite, and — since 3.21 — gets encoded into the watermark
/// payload as `chat_id`. A client that spells it differently archives keys under names the others cannot
/// find, and stamps screenshots with a conversation id that points somewhere else.
///
/// ```
/// user            <id>
/// basic group    -<id>
/// channel / supergroup   -(id + 10^12)
/// ```
///
/// **The channel form is arithmetic, not string concatenation.** iOS, macOS and Windows all used to glue
/// the literal prefix `"-100"` in front of the bare id, which agrees with the arithmetic only while the
/// bare id is exactly ten digits long. Most channels alive today are ten-digit, which is why the bug
/// stayed invisible; a bare id of `1` gives `"-1001"` the string way and `"-1000000000001"` everywhere
/// else. The vector block `shared_chat_id_format` in `Tests/SecutgCoreTests/Vectors/watermark.json`
/// pins exactly that case, and every client asserts its own chat-key function against it.
public enum SharedChatId {
    /// Matches `shared_chat_id_format.channel_id_base` in the shared vectors.
    public static let channelBase: Int64 = 1_000_000_000_000

    public enum Kind: String, Equatable {
        case user
        case basicGroup = "basic_group"
        /// Channels and supergroups share one namespace and one encoding.
        case channel
    }

    /// The shared chat id for a bare Telegram id of the given kind. `bareId` is the positive id as
    /// Telegram states it, with no sign and no prefix.
    public static func encode(kind: Kind, bareId: Int64) -> Int64 {
        switch kind {
        case .user: return bareId
        case .basicGroup: return -bareId
        // &+ so a hostile id near Int64.max traps nothing on the message path; such an id cannot exist.
        case .channel: return -(bareId &+ channelBase)
        }
    }

    public static func encodeString(kind: Kind, bareId: Int64) -> String {
        return "\(encode(kind: kind, bareId: bareId))"
    }

    /// The inverse. Returns nil for a value that is not a well-formed chat id (a zero bare id).
    public static func decode(_ value: Int64) -> (kind: Kind, bareId: Int64)? {
        if value <= -channelBase {
            let bare = -value - channelBase
            return bare > 0 ? (.channel, bare) : nil
        }
        if value < 0 { return (.basicGroup, -value) }
        return value > 0 ? (.user, value) : nil
    }

    public static func decode(_ text: String) -> (kind: Kind, bareId: Int64)? {
        guard let value = Int64(text) else { return nil }
        return decode(value)
    }
}
