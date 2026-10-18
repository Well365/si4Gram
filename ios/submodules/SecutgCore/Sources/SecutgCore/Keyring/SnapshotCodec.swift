import Foundation

/// JSON (de)serialisation of a keyring snapshot: bytes as base64url strings. The app encrypts the
/// resulting blob with a Keychain-held key before writing it to disk.
public enum SnapshotCodec {
    public static func encode(_ s: KeyRing.Snapshot) -> Data {
        var object: [String: Any] = [
            "v": ChannelKeyMigration.snapshotVersion,
            "masters": s.masters.mapValues(Base64Url.encode),
            "chat_masters": s.chatMasters,
            "chat_key_labels": s.chatKeyLabels,
            "chat_encryption": s.chatEncryption,
            "chat_admin_pks": s.chatAdminPks.mapValues(Base64Url.encode),
            "chat_admin_sks": s.chatAdminSks.mapValues(Base64Url.encode),
            "member_pks": s.memberPks.mapValues { $0.mapValues(Base64Url.encode) },
            "member_ed_pks": s.memberEdPks.mapValues { $0.mapValues(Base64Url.encode) },
            "chat_pairings": s.chatPairings.mapValues(encodePairing),
            "master_created_at": s.masterCreatedAt.mapValues { NSNumber(value: $0) },
            "chat_ratchets": s.chatRatchets.mapValues { ["label": $0.label, "masters": $0.masters] as [String: Any] },
            "chat_key_sources": s.chatKeySources.mapValues(encodeKeySource),
            // PLAN.md 3.34.1: how this generation of the chat's key reaches members; absent reads as `manual`
            "chat_key_modes": s.chatKeyModes.mapValues { $0.rawValue },
            // PLAN.md 3.34.3 rule 3 (2026-09-19): the `at` of the last retire notice obeyed, per chat
            "chat_notice_ats": s.chatNoticeAts.mapValues { NSNumber(value: $0) },
            "group_online_invites": s.groupOnlineInvites.mapValues { $0.mapValues { $0.rawValue } },
            // PLAN.md 3.25.3/3.25.4: device_id → user-written label, snapshot top level (not per-chat)
            "device_labels": s.deviceLabels.mapValues { ["label": $0.label, "updated_at": NSNumber(value: $0.updatedAt)] as [String: Any] },
            // PLAN.md 3.19: a preference, not a secret — it rides along with the ring so it survives a reinstall
            "local_ciphertext": s.localCiphertext,
            // PLAN.md 3.16 / 3.22: emergency-wipe preferences. Preferences, not secrets; kept with the ring.
            "wipe_needs_confirmation": s.wipeNeedsConfirmation,
            "wipe_custom_phrase": s.wipeCustomPhrase,
            "wipe_listens_to_phrase": s.wipeListensToPhrase,
            "wipe_resets_authorizations": s.wipeResetsAuthorizations,
            // PLAN.md 3.0: chat keys the channel-key migration refused to claim. Sorted so the blob is stable.
            "chat_encryption_lost": s.encryptionLost.sorted(),
            // PLAN.md 3.38.1: the locked group records (the `pw=` head exactly as it went on the wire) and the
            // masters bound per chat. Absent in older snapshots, which decode to empty tables.
            "chat_group_passwords": s.chatGroupPasswords.mapValues(encodeGroupPassword),
            "chat_master_history": s.chatMasterHistory,
            // PLAN.md 3.38.2: the group-password policy exactly as `GP1` carried it, plus its `at`. Absent in
            // older snapshots, which decode to "no policy anywhere".
            "chat_group_pw_policies": s.chatGroupPasswordPolicies.mapValues(encodePolicy),
        ]
        if let xPk = s.identityX25519Pk, let xSk = s.identityX25519Sk, let edPk = s.identityEd25519Pk, let edSk = s.identityEd25519Sk {
            object["identity"] = ["x_pk": Base64Url.encode(xPk), "x_sk": Base64Url.encode(xSk), "ed_pk": Base64Url.encode(edPk), "ed_sk": Base64Url.encode(edSk)]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// nil when the blob is not ours; malformed entries are dropped by `KeyRing.sanitize` later.
    public static func decode(_ data: Data) -> KeyRing.Snapshot? {
        return decodeWithReport(data)?.snapshot
    }

    /// PLAN.md 3.0: decode, and say what the channel-key migration did on the way in.
    ///
    /// The version field used to be written and then ignored, which meant a blob carrying string-concatenated
    /// channel keys was indistinguishable from a current one — the very thing a version number exists to
    /// prevent. It is now read: anything below `ChannelKeyMigration.snapshotVersion` goes through the
    /// migration before it is handed back, and anything at or above it is taken as already migrated. A blob
    /// from a *newer* build is decoded field by field as usual (the schema only ever grows) and is not
    /// migrated, because re-running an old migration over a newer file is how good data gets mangled.
    public static func decodeWithReport(_ data: Data) -> (snapshot: KeyRing.Snapshot, migration: ChannelKeyMigration.Report)? {
        guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? 1
        var s = KeyRing.Snapshot()
        s.masters = bytesMap(object["masters"])
        s.chatMasters = (object["chat_masters"] as? [String: String]) ?? [:]
        s.chatKeyLabels = (object["chat_key_labels"] as? [String: String]) ?? [:]
        s.chatEncryption = (object["chat_encryption"] as? [String: Bool]) ?? [:]
        // PLAN.md 3.19: anything but an explicit `false` means encrypted chats stay sealed on disk
        s.localCiphertext = (object["local_ciphertext"] as? Bool) != false
        // PLAN.md 3.16 / 3.22 wipe preferences; snapshots written before them decode to the defaults.
        // The three booleans default on: anything but an explicit `false` keeps the safe default.
        s.wipeNeedsConfirmation = (object["wipe_needs_confirmation"] as? Bool) != false
        s.wipeListensToPhrase = (object["wipe_listens_to_phrase"] as? Bool) != false
        s.wipeResetsAuthorizations = (object["wipe_resets_authorizations"] as? Bool) != false
        s.wipeCustomPhrase = (object["wipe_custom_phrase"] as? String) ?? ""
        s.chatAdminPks = bytesMap(object["chat_admin_pks"])
        s.chatAdminSks = bytesMap(object["chat_admin_sks"])
        if let members = object["member_ed_pks"] as? [String: Any] {
            for (chat, value) in members { s.memberEdPks[chat] = bytesMap(value) }
        }
        if let members = object["member_pks"] as? [String: Any] {
            for (chat, value) in members { s.memberPks[chat] = bytesMap(value) }
        }
        if let pairings = object["chat_pairings"] as? [String: [String: Any]] {
            for (chatId, raw) in pairings {
                if let pairing = decodePairing(raw) { s.chatPairings[chatId] = pairing }
            }
        }
        // PLAN.md 3.25.7 rule 2: absent in an old snapshot, decodes to an empty table — not an error
        if let labels = object["device_labels"] as? [String: [String: Any]] {
            for (deviceId, raw) in labels {
                guard let label = raw["label"] as? String, let updatedAt = raw["updated_at"] as? NSNumber else { continue }
                s.deviceLabels[deviceId] = KeyRing.DeviceLabel(label: label, updatedAt: updatedAt.int64Value)
            }
        }
        if let created = object["master_created_at"] as? [String: Any] {
            for (id, value) in created { if let n = value as? NSNumber { s.masterCreatedAt[id] = n.int64Value } }
        }
        if let ratchets = object["chat_ratchets"] as? [String: [String: Any]] {
            for (chatId, raw) in ratchets {
                guard let label = raw["label"] as? String, let masters = raw["masters"] as? [String: String] else { continue }
                s.chatRatchets[chatId] = KeyRing.Ratchet(label: label, masters: masters)
            }
        }
        // PLAN.md 3.13 provenance; snapshots written before it simply decode without it
        if let sources = object["chat_key_sources"] as? [String: [String: Any]] {
            for (chatId, raw) in sources {
                if let source = decodeKeySource(raw) { s.chatKeySources[chatId] = source }
            }
        }
        // PLAN.md 3.34.1; snapshots written before it decode without it, and an unrecognised mode is dropped
        // rather than guessed at — every reader falls back to `manual`, the half that asks a person.
        if let modes = object["chat_key_modes"] as? [String: String] {
            s.chatKeyModes = modes.compactMapValues(Rekey.KeyMode.init(rawValue:))
        }
        // PLAN.md 3.34.3 rule 3; a snapshot written before it decodes without the table, which reads as
        // "no notice obeyed yet" everywhere — the first notice this device meets then applies.
        if let ats = object["chat_notice_ats"] as? [String: NSNumber] {
            s.chatNoticeAts = ats.mapValues { $0.int64Value }
        }
        if let invites = object["group_online_invites"] as? [String: [String: String]] {
            for (chatId, members) in invites {
                s.groupOnlineInvites[chatId] = members.compactMapValues(OnlineInviteLevel.init(rawValue:))
            }
        }
        if let identity = object["identity"] as? [String: String] {
            s.identityX25519Pk = identity["x_pk"].flatMap(Base64Url.decode)
            s.identityX25519Sk = identity["x_sk"].flatMap(Base64Url.decode)
            s.identityEd25519Pk = identity["ed_pk"].flatMap(Base64Url.decode)
            s.identityEd25519Sk = identity["ed_sk"].flatMap(Base64Url.decode)
        }
        s.encryptionLost = Set((object["chat_encryption_lost"] as? [String]) ?? [])
        if let records = object["chat_group_passwords"] as? [String: [String: Any]] {
            s.chatGroupPasswords = records.compactMapValues(decodeGroupPassword)
        }
        s.chatMasterHistory = (object["chat_master_history"] as? [String: [String]]) ?? [:]
        if let policies = object["chat_group_pw_policies"] as? [String: [String: Any]] {
            s.chatGroupPasswordPolicies = policies.compactMapValues(decodePolicy)
        }
        guard version < ChannelKeyMigration.snapshotVersion else { return (s, ChannelKeyMigration.Report()) }
        let migrated = ChannelKeyMigration.apply(to: s)
        return (migrated.snapshot, migrated.report)
    }

    private static func encodeGroupPassword(_ r: GroupPasswordRecord) -> [String: Any] {
        return ["pw": GroupPassword.buildLockedHead(r.fields), "at": NSNumber(value: r.at), "active": r.active,
                "superseded": r.superseded]
    }

    private static func encodePolicy(_ p: GroupPasswordPolicy) -> [String: Any] {
        return ["policy": GroupPassword.buildPolicyPayload(p.payload), "at": NSNumber(value: p.at)]
    }

    private static func decodePolicy(_ raw: [String: Any]) -> GroupPasswordPolicy? {
        guard let text = raw["policy"] as? String, let payload = GroupPassword.parsePolicyPayload(text),
              let at = raw["at"] as? NSNumber else { return nil }
        return GroupPasswordPolicy(payload: payload, at: at.int64Value)
    }

    private static func decodeGroupPassword(_ raw: [String: Any]) -> GroupPasswordRecord? {
        guard let head = raw["pw"] as? String, let fields = GroupPassword.parseLockedHead(head),
              let at = raw["at"] as? NSNumber else { return nil }
        return GroupPasswordRecord(fields: fields, at: at.int64Value, active: (raw["active"] as? Bool) ?? true,
                                   superseded: (raw["superseded"] as? Bool) ?? false)
    }

    private static func encodePairing(_ p: KeyRing.Pairing) -> [String: Any] {
        var out: [String: Any] = ["peer_id": p.peerId, "state": p.state.rawValue, "verified": p.verified]
        if let startedAt = p.startedAt { out["started_at"] = NSNumber(value: startedAt) }
        if let pairedAt = p.pairedAt { out["paired_at"] = NSNumber(value: pairedAt) }
        // PLAN.md 3.25.3: all three optional, so an older snapshot simply omits them
        if let ownDeviceId = p.ownDeviceId { out["own_device_id"] = ownDeviceId }
        if let peerDeviceId = p.peerDeviceId { out["peer_device_id"] = peerDeviceId }
        if let peerSeenDeviceIds = p.peerSeenDeviceIds { out["peer_seen_device_ids"] = peerSeenDeviceIds }
        return out
    }

    /// Snapshots written before the timestamps (or the PLAN.md 3.25 device fields) existed simply decode
    /// without them (PLAN.md 3.25.7 rule 2).
    private static func decodePairing(_ raw: [String: Any]) -> KeyRing.Pairing? {
        guard let peerId = raw["peer_id"] as? String, let state = (raw["state"] as? String).flatMap(KeyRing.Pairing.State.init) else { return nil }
        return KeyRing.Pairing(
            peerId: peerId, state: state, verified: raw["verified"] as? Bool ?? false,
            startedAt: (raw["started_at"] as? NSNumber)?.int64Value, pairedAt: (raw["paired_at"] as? NSNumber)?.int64Value,
            ownDeviceId: raw["own_device_id"] as? String, peerDeviceId: raw["peer_device_id"] as? String,
            peerSeenDeviceIds: raw["peer_seen_device_ids"] as? [String])
    }

    private static func encodeKeySource(_ source: ChatKeySource) -> [String: Any] {
        switch source {
        case .offline: return ["source": "offline"]
        case let .online(via, viaLevel): return ["source": "online", "via": via, "via_level": viaLevel.rawValue]
        }
    }

    private static func decodeKeySource(_ raw: [String: Any]) -> ChatKeySource? {
        switch raw["source"] as? String {
        case "offline": return .offline
        case "online":
            guard let via = raw["via"] as? String, let level = (raw["via_level"] as? String).flatMap(OnlineInviteLevel.init) else { return nil }
            return .online(via: via, viaLevel: level)
        default: return nil
        }
    }

    private static func bytesMap(_ any: Any?) -> [String: [UInt8]] {
        guard let map = any as? [String: String] else { return [:] }
        var out = [String: [UInt8]]()
        for (k, v) in map { if let bytes = Base64Url.decode(v) { out[k] = bytes } }
        return out
    }
}
