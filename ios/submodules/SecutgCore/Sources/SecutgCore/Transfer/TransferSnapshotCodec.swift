import Foundation

/// The JSON that travels inside a `K1` container (PLAN.md 3.14). Unlike `SnapshotCodec`, which is free to use
/// whatever shape this client's storage likes, this one is the **cross-client wire format**: the camelCase field
/// names of Web A's `KeyRingSnapshot` and byte arrays wrapped as `{"$b": "<base64url>"}`, so an export written on
/// one client opens on every other. iOS keeps a member's X25519 and Ed25519 keys in two tables while the wire
/// format keeps one object per member, so those two are zipped here.
enum TransferSnapshotCodec {
    // MARK: payload

    static func encodePayload(_ payload: TransferPayload) -> [String: Any] {
        var object: [String: Any] = [
            "v": payload.v,
            "scope": payload.scope.rawValue,
            "createdAt": NSNumber(value: payload.createdAt),
            "device": payload.device,
            "snapshot": encode(payload.snapshot),
        ]
        if let chatIds = payload.chatIds { object["chatIds"] = chatIds }
        return object
    }

    static func decodePayload(_ object: [String: Any]) -> TransferPayload? {
        guard let version = (object["v"] as? NSNumber)?.intValue, version == TransferBundle.version,
              let scope = (object["scope"] as? String).flatMap(TransferScope.init(rawValue:)) else { return nil }
        let snapshot = (object["snapshot"] as? [String: Any]).map(decode) ?? KeyRing.Snapshot()
        return TransferPayload(
            v: version,
            scope: scope,
            chatIds: object["chatIds"] as? [String],
            createdAt: (object["createdAt"] as? NSNumber)?.int64Value ?? 0,
            device: object["device"] as? String ?? "",
            snapshot: snapshot)
    }

    // MARK: snapshot

    static func encode(_ s: KeyRing.Snapshot) -> [String: Any] {
        var object: [String: Any] = [
            "masters": s.masters.keys.sorted().map { id -> [String: Any] in
                return ["masterId": id, "masterKey": bytes(s.masters[id] ?? []),
                        "createdAt": NSNumber(value: s.masterCreatedAt[id] ?? 0)]
            },
            "chatMasters": s.chatMasters,
            "chatKeyLabels": s.chatKeyLabels,
            "chatEncryption": s.chatEncryption,
            "chatAdminPks": s.chatAdminPks.mapValues(bytes),
            "chatAdminSks": s.chatAdminSks.mapValues(bytes),
            "memberPks": encodeMembers(s),
            "chatPairings": s.chatPairings.mapValues(encodePairing),
            "chatRatchets": s.chatRatchets.mapValues { ["label": $0.label, "masters": $0.masters] as [String: Any] },
            "chatKeySources": s.chatKeySources.mapValues(encodeKeySource),
            // PLAN.md 3.34.1: the key's mode travels with the key, so a device that receives the keyring also
            // learns whether each group's key comes to it or has to be fetched in person. Always written, even
            // empty: the comparison view the five clients publish for this format lists it flat and always
            // present, so "omitted because empty" and "written as {}" mean the same thing there.
            "chatKeyModes": s.chatKeyModes.mapValues { $0.rawValue },
            // PLAN.md 3.34.3 rule 3 (2026-09-19): the replay anchor travels with the key. A receiving device
            // that forgot it would re-obey an old notice out of the history and unbind the key just carried
            // over. Always written, even empty, for the same reason `chatKeyModes` above is: the comparison
            // view the five clients publish lists it flat and always present.
            "chatNoticeAts": s.chatNoticeAts.mapValues { NSNumber(value: $0) },
            "groupOnlineInvites": s.groupOnlineInvites.mapValues { $0.mapValues { $0.rawValue } },
            // PLAN.md 3.25.4: device_id → label, travels only when the export dialog's checkbox left it in
            // (KeyRing already empties the table before this runs otherwise)
            "deviceLabels": s.deviceLabels.mapValues { ["label": $0.label, "updatedAt": NSNumber(value: $0.updatedAt)] as [String: Any] },
        ]
        if let xPk = s.identityX25519Pk, let xSk = s.identityX25519Sk,
           let edPk = s.identityEd25519Pk, let edSk = s.identityEd25519Sk {
            object["identity"] = [
                "x25519Pk": bytes(xPk), "x25519Sk": bytes(xSk),
                "ed25519Pk": bytes(edPk), "ed25519Sk": bytes(edSk),
            ]
        }
        return object
    }

    /// Malformed entries are simply dropped; `KeyRing.sanitize` runs again on the merge side.
    static func decode(_ object: [String: Any]) -> KeyRing.Snapshot {
        var s = KeyRing.Snapshot()
        for record in (object["masters"] as? [[String: Any]]) ?? [] {
            guard let masterId = record["masterId"] as? String, let key = decodeBytes(record["masterKey"]) else { continue }
            s.masters[masterId] = key
            s.masterCreatedAt[masterId] = (record["createdAt"] as? NSNumber)?.int64Value ?? 0
        }
        s.chatMasters = (object["chatMasters"] as? [String: String]) ?? [:]
        s.chatKeyLabels = (object["chatKeyLabels"] as? [String: String]) ?? [:]
        s.chatEncryption = (object["chatEncryption"] as? [String: Bool]) ?? [:]
        s.chatAdminPks = bytesMap(object["chatAdminPks"])
        s.chatAdminSks = bytesMap(object["chatAdminSks"])
        if let members = object["memberPks"] as? [String: [String: Any]] {
            for (chatId, perUser) in members {
                var xs = [String: [UInt8]]()
                var eds = [String: [UInt8]]()
                for (userId, raw) in perUser {
                    guard let keys = raw as? [String: Any] else { continue }
                    if let x = decodeBytes(keys["x25519Pk"]) { xs[userId] = x }
                    if let ed = decodeBytes(keys["ed25519Pk"]) { eds[userId] = ed }
                }
                if !xs.isEmpty { s.memberPks[chatId] = xs }
                if !eds.isEmpty { s.memberEdPks[chatId] = eds }
            }
        }
        if let pairings = object["chatPairings"] as? [String: [String: Any]] {
            for (chatId, raw) in pairings {
                if let pairing = decodePairing(raw) { s.chatPairings[chatId] = pairing }
            }
        }
        if let labels = object["deviceLabels"] as? [String: [String: Any]] {
            for (deviceId, raw) in labels {
                guard let label = raw["label"] as? String, let updatedAt = raw["updatedAt"] as? NSNumber else { continue }
                s.deviceLabels[deviceId] = KeyRing.DeviceLabel(label: label, updatedAt: updatedAt.int64Value)
            }
        }
        if let ratchets = object["chatRatchets"] as? [String: [String: Any]] {
            for (chatId, raw) in ratchets {
                guard let label = raw["label"] as? String, let masters = raw["masters"] as? [String: String] else { continue }
                s.chatRatchets[chatId] = KeyRing.Ratchet(label: label, masters: masters)
            }
        }
        // An export from a build older than 3.34 carries none, and every reader falls back to `manual` — the
        // half that sends the user to a person rather than leaving them waiting for a key nobody will send.
        if let modes = object["chatKeyModes"] as? [String: String] {
            s.chatKeyModes = modes.compactMapValues(Rekey.KeyMode.init(rawValue:))
        }
        // An export from a build older than the 2026-09-19 amendment carries no anchors, which reads as
        // "nothing obeyed yet" — and `mergeSnapshot` takes the later of the two anyway.
        if let ats = object["chatNoticeAts"] as? [String: NSNumber] {
            s.chatNoticeAts = ats.mapValues { $0.int64Value }
        }
        if let sources = object["chatKeySources"] as? [String: [String: Any]] {
            for (chatId, raw) in sources {
                if let source = decodeKeySource(raw) { s.chatKeySources[chatId] = source }
            }
        }
        if let invites = object["groupOnlineInvites"] as? [String: [String: String]] {
            for (chatId, members) in invites {
                s.groupOnlineInvites[chatId] = members.compactMapValues(OnlineInviteLevel.init(rawValue:))
            }
        }
        if let identity = object["identity"] as? [String: Any] {
            s.identityX25519Pk = decodeBytes(identity["x25519Pk"])
            s.identityX25519Sk = decodeBytes(identity["x25519Sk"])
            s.identityEd25519Pk = decodeBytes(identity["ed25519Pk"])
            s.identityEd25519Sk = decodeBytes(identity["ed25519Sk"])
        }
        return s
    }

    // MARK: pieces

    /// One object per member, as Web A's `MemberKeys`; a member without both keys would be dropped by the
    /// other clients' validation, so it is left out here too.
    private static func encodeMembers(_ s: KeyRing.Snapshot) -> [String: Any] {
        var out = [String: Any]()
        for chatId in Set(s.memberPks.keys).union(s.memberEdPks.keys) {
            var perUser = [String: Any]()
            for (userId, x) in s.memberPks[chatId] ?? [:] {
                guard let ed = s.memberEdPks[chatId]?[userId] else { continue }
                perUser[userId] = ["x25519Pk": bytes(x), "ed25519Pk": bytes(ed)]
            }
            if !perUser.isEmpty { out[chatId] = perUser }
        }
        return out
    }

    private static func encodePairing(_ p: KeyRing.Pairing) -> [String: Any] {
        var out: [String: Any] = ["peerId": p.peerId, "state": p.state.rawValue, "verified": p.verified]
        if let startedAt = p.startedAt { out["startedAt"] = NSNumber(value: startedAt) }
        if let pairedAt = p.pairedAt { out["pairedAt"] = NSNumber(value: pairedAt) }
        // PLAN.md 3.25.3: all three optional, matching Web A's `ChatPairing` field names verbatim
        if let ownDeviceId = p.ownDeviceId { out["ownDeviceId"] = ownDeviceId }
        if let peerDeviceId = p.peerDeviceId { out["peerDeviceId"] = peerDeviceId }
        if let peerSeenDeviceIds = p.peerSeenDeviceIds { out["peerSeenDeviceIds"] = peerSeenDeviceIds }
        return out
    }

    private static func decodePairing(_ raw: [String: Any]) -> KeyRing.Pairing? {
        guard let peerId = raw["peerId"] as? String,
              let state = (raw["state"] as? String).flatMap(KeyRing.Pairing.State.init) else { return nil }
        return KeyRing.Pairing(
            peerId: peerId, state: state, verified: raw["verified"] as? Bool ?? false,
            startedAt: (raw["startedAt"] as? NSNumber)?.int64Value, pairedAt: (raw["pairedAt"] as? NSNumber)?.int64Value,
            ownDeviceId: raw["ownDeviceId"] as? String, peerDeviceId: raw["peerDeviceId"] as? String,
            peerSeenDeviceIds: raw["peerSeenDeviceIds"] as? [String])
    }

    private static func encodeKeySource(_ source: ChatKeySource) -> [String: Any] {
        switch source {
        case .offline: return ["source": "offline"]
        case let .online(via, viaLevel): return ["source": "online", "via": via, "viaLevel": viaLevel.rawValue]
        }
    }

    private static func decodeKeySource(_ raw: [String: Any]) -> ChatKeySource? {
        switch raw["source"] as? String {
        case "offline": return .offline
        case "online":
            guard let via = raw["via"] as? String,
                  let level = (raw["viaLevel"] as? String).flatMap(OnlineInviteLevel.init) else { return nil }
            return .online(via: via, viaLevel: level)
        default: return nil
        }
    }

    // MARK: `{"$b": "<base64url>"}`

    private static func bytes(_ value: [UInt8]) -> [String: String] {
        return ["$b": Base64Url.encode(value)]
    }

    private static func decodeBytes(_ any: Any?) -> [UInt8]? {
        guard let wrapper = any as? [String: Any], let text = wrapper["$b"] as? String else { return nil }
        return Base64Url.decode(text)
    }

    private static func bytesMap(_ any: Any?) -> [String: [UInt8]] {
        guard let map = any as? [String: Any] else { return [:] }
        var out = [String: [UInt8]]()
        for (key, value) in map { if let decoded = decodeBytes(value) { out[key] = decoded } }
        return out
    }
}
