import Foundation
import Postbox

/// SECUTG: attached by the receive hook so the UI can draw the lock badge / render control messages as
/// system lines. Persisted with the message like every other attribute.
public final class SecutgTextMetaAttribute: MessageAttribute, Equatable {
    public enum Kind: Int32 {
        case decrypted = 0
        case undecryptable = 1
        case control = 2
        /// A decrypted `G1` group invite (PLAN.md 3.13), rendered as a card; details in `invite`
        case groupInvite = 3
        /// Plain text from others received while this chat's encryption is on (PLAN.md 3.13 "not encrypted" marker)
        case plaintext = 4
        /// PLAN.md 3.19: opened when it arrived, then written back to the database as the envelope it came out of.
        /// The stored text is the `E1:` wire — or, PLAN.md 3.44, v2's `E2:` wire (`keyId` "v2"); the words live in
        /// this session's `SecutgPlaintextCache` and are read back out of it — or out of the keyring / the v2
        /// binding again — when the message is drawn. Distinct from `.undecryptable`, which means the opposite: this
        /// device tried and could not open it.
        case sealed = 5
    }

    /// What the invite card needs. `ok` false = malformed / not from the private-chat peer; `isOwn` = our own echo,
    /// shown as a plain "invite sent" line. `via` is the user id of the sender (the admin), the only one whose chat
    /// level vouches for the key.
    public struct GroupInvite: Equatable {
        public let ok: Bool
        public let isOwn: Bool
        public let groupChatId: String?
        public let title: String?
        public let keyPayload: String?
        /// master_id the payload resolves to, so the card can ask the live keyring whether this very invite
        /// has been used. A pure function of the key, so it never has to be imported to be known.
        public let masterId: String?
        public let via: String?

        public init(ok: Bool, isOwn: Bool, groupChatId: String?, title: String?, keyPayload: String?, masterId: String? = nil, via: String?) {
            self.ok = ok
            self.isOwn = isOwn
            self.groupChatId = groupChatId
            self.title = title
            self.keyPayload = keyPayload
            self.masterId = masterId
            self.via = via
        }
    }

    public let kind: Kind
    public let keyId: String?
    /// decrypt failure reason (`unknown_key`, `auth_failed`, …) or control outcome (`rekey:rotate:ok`, `peer-key:200:ok`)
    public let detail: String?
    public let invite: GroupInvite?
    /// SECUTG-HOOK (PLAN.md 3.17 rule 6): the `E1:` envelope this message's words came out of, kept **whatever the
    /// 3.19 setting says**, and only for `.decrypted` — where the stored text is the words rather than the envelope.
    ///
    /// Two different questions used to be answered by one fact. "May the reader see base64 by default?" (rule 1,
    /// no) and "may this disk hold the words?" (3.19, its own setting) were both decided by which of the two the
    /// stored text happened to be, so turning 3.19 off threw the envelope away at the door and rule 6 quietly
    /// stopped working for every message that opened — no error, no empty dialog, just a menu entry that is never
    /// drawn. They are now separate: what goes on the disk is still `SecutgPersist.storedForm` asking the setting,
    /// and the envelope is kept regardless.
    ///
    /// Keeping it costs disk and not secrecy. It is the exact thing the server already holds; it is what 3.19
    /// stores *instead of* the words when it is on — so this field is nil in that case and adds nothing at all —
    /// and when 3.19 is off the words are lying beside it anyway, which is the easier thing for anyone who has the
    /// database to read.
    public let wire: String?

    public var associatedPeerIds: [PeerId] { return [] }

    public init(kind: Kind, keyId: String?, detail: String?, invite: GroupInvite? = nil, wire: String? = nil) {
        self.kind = kind
        self.keyId = keyId
        self.detail = detail
        self.invite = invite
        self.wire = wire
    }

    /// Attributes written before the invite fields existed decode with `invite == nil`; ones written before
    /// the master id was carried decode with `masterId == nil`, which simply keeps the card actionable; ones
    /// written before the envelope was kept decode with `wire == nil`, and the 3.17 rule 6 entry is then simply
    /// absent on those older messages rather than wrong.
    required public init(decoder: PostboxDecoder) {
        self.kind = Kind(rawValue: decoder.decodeInt32ForKey("k", orElse: 1)) ?? .undecryptable
        self.keyId = decoder.decodeOptionalStringForKey("id")
        self.detail = decoder.decodeOptionalStringForKey("d")
        self.wire = decoder.decodeOptionalStringForKey("w")
        if let ok = decoder.decodeOptionalInt32ForKey("iok") {
            self.invite = GroupInvite(
                ok: ok != 0, isOwn: decoder.decodeInt32ForKey("iown", orElse: 0) != 0,
                groupChatId: decoder.decodeOptionalStringForKey("ig"), title: decoder.decodeOptionalStringForKey("it"),
                keyPayload: decoder.decodeOptionalStringForKey("ip"), masterId: decoder.decodeOptionalStringForKey("im"),
                via: decoder.decodeOptionalStringForKey("iv"))
        } else {
            self.invite = nil
        }
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.kind.rawValue, forKey: "k")
        if let keyId = self.keyId { encoder.encodeString(keyId, forKey: "id") } else { encoder.encodeNil(forKey: "id") }
        if let detail = self.detail { encoder.encodeString(detail, forKey: "d") } else { encoder.encodeNil(forKey: "d") }
        if let wire = self.wire { encoder.encodeString(wire, forKey: "w") } else { encoder.encodeNil(forKey: "w") }
        guard let invite = self.invite else { return }
        encoder.encodeInt32(invite.ok ? 1 : 0, forKey: "iok")
        encoder.encodeInt32(invite.isOwn ? 1 : 0, forKey: "iown")
        for (key, value) in [("ig", invite.groupChatId), ("it", invite.title), ("ip", invite.keyPayload), ("im", invite.masterId), ("iv", invite.via)] {
            if let value = value { encoder.encodeString(value, forKey: key) } else { encoder.encodeNil(forKey: key) }
        }
    }

    public static func == (lhs: SecutgTextMetaAttribute, rhs: SecutgTextMetaAttribute) -> Bool {
        return lhs.kind == rhs.kind && lhs.keyId == rhs.keyId && lhs.detail == rhs.detail && lhs.invite == rhs.invite
            && lhs.wire == rhs.wire
    }
}

public extension Message {
    var secutgMeta: SecutgTextMetaAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? SecutgTextMetaAttribute { return attribute }
        }
        return nil
    }
}
