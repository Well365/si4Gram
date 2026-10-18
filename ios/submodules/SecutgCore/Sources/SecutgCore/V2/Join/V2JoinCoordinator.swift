import Foundation

/// PLAN.md 3.39.13: the two sides of "share this 1v1 chat to my other device by QR" in clone mode, over the stores a
/// `V2Runtime` already owns — the same "one more class over the same stores" shape `V2Roster` and
/// `V2PrivateChatMessaging` use. Mirrors Web A `src/secutg/v2/join/coordinator.ts`.
///
/// Showing device O: `prepareShare` packs the chat's binding — roster, safety code, current and (as many as fit)
/// history masters — together with the device identity O acts under in it, into a V2Q that fits a QR
/// (`V2JoinCapacity`). **Nothing is written**: no pending record, no expiry, no echo to wait for.
///
/// Scanning device N: `inspect` opens the code for the manifest, `install` writes the binding with
/// `ownIdentity` = O's keys, `safetyCode` = the code's, `txnId` = `"clone:" + bindingId`, and every master it carried —
/// N reads history and SENDS from this instant. The peer never hears of it: to the peer N is O.
public final class V2JoinCoordinator {
    /// `txnId` prefix of a binding installed from a clone code — `isCloneBinding`.
    public static let cloneTxnPrefix = "clone:"

    public struct Share: Equatable {
        public let text: String
        public let ecc: V2JoinCapacity.ErrorCorrection
        public let bytes: Int
        /// masters inside the code (current + kept history)
        public let keyCount: Int
        /// history masters that did not fit (0 = everything went in)
        public let historyDropped: Int
        public let expiresMs: Int64
    }

    public enum ShareResult: Equatable {
        case ok(Share)
        /// no current, sendable v2 binding on this chat (`SecutgV2JoinNotPaired`)
        case notPaired
        /// even the current master alone does not fit a QR (`SecutgQuickShareTooLarge`)
        case tooLarge
        /// an internal failure (a key this side holds that does not encode — a programming error, never input)
        case failed(String)
    }

    public enum ImportRefusal: String, Error, Equatable {
        case malformed
        case undecryptable
        case wrongChat = "wrong_chat"
        case expired
        case alreadyPaired = "already_paired"
        case oldVersion = "old_version"

        init(_ error: V2Join.OpenError) {
            switch error {
            case .malformed: self = .malformed
            case .undecryptable: self = .undecryptable
            case .wrongChat: self = .wrongChat
            case .expired: self = .expired
            case .oldVersion: self = .oldVersion
            case .alreadyPaired: self = .alreadyPaired
            }
        }
    }

    public struct Inspection: Equatable {
        public let peerUserId: String
        public let safetyCode: String
        public let epoch: Int
        public let deviceCount: Int
        public let historyCount: Int
        public let expiresMs: Int64
        /// the device code (`XXX-XXX`, 3.25.2) this device will act as in the chat — the showing device's own
        public let deviceCode: String
    }

    public enum InspectResult: Equatable {
        case ok(Inspection)
        case refused(ImportRefusal)
    }

    public enum InstallResult: Equatable {
        case ok(bindingId: String)
        case refused(ImportRefusal)
    }

    private let identity: V2Identity
    private let pairing: V2Processor.PairingProcessor
    private let now: () -> Int64

    public init(identity: V2Identity, pairing: V2Processor.PairingProcessor, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.identity = identity
        self.pairing = pairing
        self.now = now
    }

    /// Whether `binding` came from a clone code (3.39.13) — the bindings 「必改项」 3 can set aside.
    public static func isCloneBinding(_ binding: V2Binding) -> Bool {
        return binding.txnId.hasPrefix(cloneTxnPrefix)
    }

    // MARK: showing side (O)

    /// The code for `chatId`'s current binding. Pure read: nothing on this device changes.
    public func prepareShare(chatId: String) -> ShareResult {
        let bindingStore = pairing.bindingStore, keyStore = pairing.keyStore
        guard let binding = bindingStore.current(chatId), pairing.canSend(chatId) else { return .notPaired }
        guard pairing.tombstoneStore.unpairedFor(binding.bindingId) == nil else { return .notPaired }
        // The identity handed over must be one the roster knows — otherwise the clone could neither send nor open a
        // single future package.
        let own = V2OwnIdentity.identity(for: binding, fallback: identity)
        guard binding.deviceKeys[V2OwnIdentity.ownDeviceId(for: binding, fallback: identity)] != nil else { return .notPaired }
        guard let safetyCode = pairing.safetyCodeForChat(chatId) else { return .notPaired }
        guard let current = keyStore.get(binding.bindingId, binding.epoch)?.master else { return .notPaired }
        guard let seed = V2Suite.ed25519Seed(ofSecretKey: own.secretKey), own.encapsulationSk.count == V2Suite.x25519SkBytes else { return .failed("own identity") }

        var rosterEntries: [V2JoinPayload.RosterEntry] = []
        for deviceId in binding.deviceRoster.sorted() {
            guard let keys = binding.deviceKeys[deviceId] else { return .failed("roster member without keys") }
            let entry = V2JoinPayload.RosterEntry(identityPk: keys.identityPk, encapsulationPk: keys.encapsulationPk)
            guard entry.deviceId == deviceId else { return .failed("roster member whose id is not its key's digest") }
            rosterEntries.append(entry)
        }
        // 3.39.12: masters are positional (e, e-1, e-2, …), so the history that can ride along is the unbroken run of
        // generations below the current one; a gap ends it.
        var history: [String] = []
        var generation = binding.epoch - 1
        while generation >= 1, let master = keyStore.get(binding.bindingId, generation)?.master {
            history.append(Base64Url.encode(master))
            generation -= 1
        }
        let expiresMs = now() + V2JoinText.ttlMs
        let code = V2Join.generateCode()
        let ownPayload = V2JoinPayload.Own(identitySeed: Base64Url.encode(seed), encapsulationSk: Base64Url.encode(own.encapsulationSk))
        let fit: V2JoinCapacity.Fit
        do {
            fit = try V2JoinCapacity.fit(historyNewestFirst: history) { kept in
                let payload = V2JoinPayload.Payload(
                    peerUserId: chatId, bindingId: binding.bindingId, epoch: binding.epoch, safetyCode: safetyCode, roster: rosterEntries,
                    masters: [Base64Url.encode(current)] + kept, own: ownPayload, expiresMs: expiresMs
                )
                guard let text = V2Join.build(payload, code: code) else { throw SecutgCryptoError.invalidKey }
                return text
            }
        } catch {
            return .failed("build failed")
        }
        guard case let .fits(text, ecc, bytes, historyKept, historyDropped) = fit else { return .tooLarge }
        return .ok(Share(text: text, ecc: ecc, bytes: bytes, keyCount: 1 + historyKept, historyDropped: historyDropped, expiresMs: expiresMs))
    }

    // MARK: scanning side (N)

    private func open(_ text: String, chatId: String) -> Result<V2Join.Opened, ImportRefusal> {
        // A chat this device already has a binding for takes no code (`SecutgV2JoinAlreadyPaired`) — the last of
        // `V2Join.open`'s checks, as on Web.
        let context = V2Join.OpenContext(chatId: chatId, nowMs: now(), hasCurrentBinding: pairing.bindingStore.current(chatId) != nil)
        switch V2Join.open(text, context: context) {
        case let .failure(error):
            return .failure(ImportRefusal(error))
        case let .success(opened):
            // A binding this device already settled (tombstoned, or set aside for a sibling's re-pair) is not
            // re-entered on a code's say-so.
            guard pairing.tombstoneStore.unpairedFor(opened.payload.bindingId) == nil else { return .failure(.alreadyPaired) }
            return .success(opened)
        }
    }

    /// The manifest, before anything is written.
    public func inspect(_ text: String, chatId: String) -> InspectResult {
        switch open(text, chatId: chatId) {
        case let .failure(refusal):
            return .refused(refusal)
        case let .success(opened):
            let payload = opened.payload
            let keys = payload.own.keys()
            return .ok(Inspection(
                peerUserId: payload.peerUserId, safetyCode: payload.safetyCode, epoch: payload.epoch, deviceCount: payload.roster.count,
                historyCount: payload.masters.count - 1, expiresMs: payload.expiresMs,
                deviceCode: V2JoinCoordinator.deviceCode(encapsulationPkB64: Base64Url.encode(keys?.encapsulationPk ?? []), fallback: keys?.deviceId ?? "")
            ))
        }
    }

    /// Re-opens the code — nothing scanned is cached between calls — and installs the clone.
    public func install(_ text: String, chatId: String) -> InstallResult {
        switch open(text, chatId: chatId) {
        case let .failure(refusal):
            return .refused(refusal)
        case let .success(opened):
            let payload = opened.payload
            guard let ownKeys = payload.own.keys() else { return .refused(.malformed) }
            let bindingStore = pairing.bindingStore, keyStore = pairing.keyStore
            var deviceKeys: [String: V2Binding.DeviceKeys] = [:]
            for entry in payload.roster {
                deviceKeys[entry.deviceId] = V2Binding.DeviceKeys(identityPk: entry.identityPk, encapsulationPk: entry.encapsulationPk)
            }
            let ownIdentity = V2OwnIdentity.fromKeys(
                identityPk: ownKeys.identityPk, identitySk: ownKeys.identitySk, encapsulationPk: ownKeys.encapsulationPk, encapsulationSk: ownKeys.encapsulationSk
            )
            bindingStore.install(V2Binding.freshTemplate(
                chatId: chatId, bindingId: payload.bindingId, epoch: payload.epoch, deviceRoster: payload.roster.map { $0.deviceId }.sorted(),
                deviceKeys: deviceKeys, revision: 1, txnId: V2JoinCoordinator.cloneTxnPrefix + payload.bindingId, installedAtMs: now(),
                ownIdentity: ownIdentity, safetyCode: payload.safetyCode
            ))
            for (index, master) in payload.masters.enumerated() where index > 0 {
                keyStore.set(V2KeyStore.Record(bindingId: payload.bindingId, epoch: payload.epochOfMaster(at: index), status: .historical, master: Base64Url.decode(master)))
            }
            keyStore.installCurrent(bindingId: payload.bindingId, epoch: payload.epoch, master: Base64Url.decode(payload.masters[0]) ?? [])
            return .ok(bindingId: payload.bindingId)
        }
    }

    /// PLAN.md 3.25.2's `XXX-XXX` for a device named by its X25519 encapsulation key. `fallback` (a prefix of the
    /// device id) only if the key is somehow not 32 bytes.
    public static func deviceCode(encapsulationPkB64: String, fallback: String) -> String {
        guard let pk = Base64Url.decode(encapsulationPkB64), let derived = try? DeviceIdentity.derive(x25519Pk: pk) else {
            return String(fallback.prefix(7))
        }
        return derived.deviceCode
    }
}
