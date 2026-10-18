import Foundation

/// v1.4 section 33's private-chat roster maintenance — REKEY / ADD_DEVICE / REMOVE_DEVICE
/// (TEST_MATRIX P-43-46). Ported from `src/secutg/v2/pairing/roster.ts` and
/// `org.telegram.secutg.v2.pairing.Roster`.
///
/// A SEPARATE type from a pairing processor on purpose: it operates entirely on an ALREADY INSTALLED
/// `V2Binding`, touches none of the five-step exchange machinery, and — per the Web reference's own
/// file-size convention — its processor.ts was already large enough before this.
///
/// What this file does NOT do, on purpose:
/// - Establish the FIRST binding for a chat, or the first multi-device roster a fresh binding starts
///   with — v1.4 section 31's real-time multi-device ceremony for that needs an account-wide
///   device-registry attestation this codebase does not build. This file only MUTATES a roster the
///   pairing exchange already seeded with its first two members.
/// - Let a device with ZERO prior local binding join via add_device alone. `handleRosterCommit`
///   verifies the issuer against `binding.deviceKeys` — a roster a brand-new device does not have yet.
///   (PLAN.md 3.39.13: this account's own other device gets a chat by CLONING the showing device's
///   binding — `V2JoinCoordinator` — and never appears in any roster; receiving a peer's add_device stays.)
/// - Implement KEY_REQUEST or an explicit refusal message (P-45: "must not recover a new key via
///   KEY_REQUEST"). The refusal is structural: a removed device simply never appears in `packages` on
///   any FUTURE commit.
public enum V2Roster {
    private static let defaultTtlMs: Int64 = 10 * 60 * 1000 // matches P2's own default (v1.4 section 8)

    public enum Kind {
        case installed, alreadyApplied, notForMe
    }

    public struct RosterCommitOutcome {
        public let ok: Bool
        public let kind: Kind?
        public let master: [UInt8]?
        public let reason: String?
        /// PLAN.md 3.39.5: what an `installed` commit did (`rekey` / `add_device` / `remove_device`), so the render
        /// hook can word the line. nil on every other outcome.
        public let commitReason: String?
        /// `add_device` only: the device that joined (its display code derives from `encapsulationPk`).
        public let newDevice: V2Messages.NewDevice?

        static func installed(_ master: [UInt8], commitReason: String, newDevice: V2Messages.NewDevice?) -> RosterCommitOutcome {
            return RosterCommitOutcome(ok: true, kind: .installed, master: master, reason: nil, commitReason: commitReason, newDevice: newDevice)
        }

        static func alreadyApplied() -> RosterCommitOutcome {
            return RosterCommitOutcome(ok: true, kind: .alreadyApplied, master: nil, reason: nil, commitReason: nil, newDevice: nil)
        }

        static func notForMe() -> RosterCommitOutcome {
            return RosterCommitOutcome(ok: true, kind: .notForMe, master: nil, reason: nil, commitReason: nil, newDevice: nil)
        }

        static func fail(_ reason: String) -> RosterCommitOutcome {
            return RosterCommitOutcome(ok: false, kind: nil, master: nil, reason: reason, commitReason: nil, newDevice: nil)
        }
    }

    public struct NewDeviceInput {
        public let deviceId: String
        public let identityPk: [UInt8]
        public let encapsulationPk: [UInt8]

        public init(deviceId: String, identityPk: [UInt8], encapsulationPk: [UInt8]) {
            self.deviceId = deviceId
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }
    }

    /// What `prepareAddDevice` hands back — everything `addDevice` applies.
    struct PreparedAddDevice {
        let wire: String
        let eventId: String
        let bindingId: String
        /// the epoch the commit installs (`current + 1`)
        let epoch: Int
        let master: [UInt8]
        let deviceRoster: [String]
        let deviceKeys: [String: V2Binding.DeviceKeys]
    }

    public final class RosterProcessor {
        private let identity: V2Identity
        private let bindingStore: V2Binding.BindingStore
        private let tombstoneStore: V2Binding.TombstoneStore
        private let keyStore: V2KeyStore.BindingKeyStore
        private let now: () -> Int64

        public init(identity: V2Identity, bindingStore: V2Binding.BindingStore, tombstoneStore: V2Binding.TombstoneStore, keyStore: V2KeyStore.BindingKeyStore, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
            self.identity = identity
            self.bindingStore = bindingStore
            self.tombstoneStore = tombstoneStore
            self.keyStore = keyStore
            self.now = now
        }

        /// PLAN.md 3.39.4 step 6: the identity this device acts under for `binding` — its per-binding one when the
        /// binding was installed from a V2Q, the global one otherwise (`V2OwnIdentity`).
        private func identityFor(_ binding: V2Binding) -> V2Identity {
            return V2OwnIdentity.identity(for: binding, fallback: identity)
        }

        private func envelopeParams(chatId: String, identity: V2Identity) -> V2Messages.EnvelopeParams {
            let nowMs = now()
            return V2Messages.EnvelopeParams(
                eventId: V2Envelope.randomId(), txnId: nil, chatId: chatId, actorUser: identity.userId,
                actorIdentityPk: identity.publicKey, actorIdentitySk: identity.secretKey, parentBinding: nil,
                createdMs: String(nowMs), expiresMs: String(nowMs + V2Roster.defaultTtlMs)
            )
        }

        /// One {deviceId, package: sealFor(that device's encapsulation_pk, master)} per id in roster
        /// that deviceKeys knows.
        private func sealForRoster(roster: [String], deviceKeys: [String: V2Binding.DeviceKeys], master: [UInt8]) -> [V2Messages.DevicePackage]? {
            var packages: [V2Messages.DevicePackage] = []
            for deviceId in roster {
                guard let keys = deviceKeys[deviceId] else { return nil } // roster: no encapsulation key on file
                guard let pk = Base64Url.decode(keys.encapsulationPk), pk.count == V2Suite.x25519PkBytes else { return nil }
                packages.append(V2Messages.DevicePackage(deviceId: deviceId, pkg: Base64Url.encode(V2Suite.sealFor(recipientX25519Pk: pk, bytes: master))))
            }
            return packages
        }

        /// v1.4 section 33: "roster unchanged; re-seal a new master per device; the old master cannot
        /// derive the new one" (P-43).
        public func rekey(_ chatId: String) -> String? {
            guard let binding = bindingStore.current(chatId), tombstoneStore.unpairedFor(binding.bindingId) == nil else { return nil }
            let master = V2Suite.randomBytes(32)
            let epoch = binding.epoch + 1
            guard let packages = sealForRoster(roster: binding.deviceRoster, deviceKeys: binding.deviceKeys, master: master) else { return nil }
            guard let wire = V2Messages.buildRosterCommit(envelopeParams(chatId: chatId, identity: identityFor(binding)), V2Messages.RosterCommitBody(
                reason: "rekey", bindingId: binding.bindingId, epoch: String(epoch), deviceRoster: binding.deviceRoster, packages: packages, newDevice: nil
            )) else { return nil }
            bindingStore.applyRosterCommit(chatId: chatId, epoch: epoch, deviceRoster: binding.deviceRoster, deviceKeys: binding.deviceKeys)
            // The issuer already knows the master (it just generated it) — installed immediately here
            // rather than routed back through handleRosterCommit, which would short-circuit to
            // ALREADY_APPLIED since bindingStore was already advanced above.
            keyStore.installCurrent(bindingId: binding.bindingId, epoch: epoch, master: master)
            return wire
        }

        /// v1.4 section 33/34 (P-44): grows the roster by one device. The new device does NOT inherit
        /// verified.
        public func addDevice(chatId: String, newDevice: NewDeviceInput) -> String? {
            guard let prepared = prepareAddDevice(chatId: chatId, newDevice: newDevice) else { return nil }
            bindingStore.applyRosterCommit(chatId: chatId, epoch: prepared.epoch, deviceRoster: prepared.deviceRoster, deviceKeys: prepared.deviceKeys)
            keyStore.installCurrent(bindingId: prepared.bindingId, epoch: prepared.epoch, master: prepared.master) // see rekey()'s own comment on why
            return prepared.wire
        }

        /// `addDevice` without the local effect — builds the e+1 master, seals it to the whole new roster and signs
        /// the `add_device` commit. (PLAN.md 3.39.13 retired the V2Q that used it on its own; private now.)
        private func prepareAddDevice(chatId: String, newDevice: NewDeviceInput) -> PreparedAddDevice? {
            guard let binding = bindingStore.current(chatId), tombstoneStore.unpairedFor(binding.bindingId) == nil else { return nil }
            guard !binding.deviceRoster.contains(newDevice.deviceId) else { return nil } // already a member
            let master = V2Suite.randomBytes(32)
            let epoch = binding.epoch + 1
            var deviceRoster = binding.deviceRoster
            deviceRoster.append(newDevice.deviceId)
            deviceRoster.sort()
            let newDeviceIdentityPk = Base64Url.encode(newDevice.identityPk)
            let newDeviceEncapsulationPk = Base64Url.encode(newDevice.encapsulationPk)
            var deviceKeys = binding.deviceKeys
            deviceKeys[newDevice.deviceId] = V2Binding.DeviceKeys(identityPk: newDeviceIdentityPk, encapsulationPk: newDeviceEncapsulationPk)
            guard let packages = sealForRoster(roster: deviceRoster, deviceKeys: deviceKeys, master: master) else { return nil }
            let params = envelopeParams(chatId: chatId, identity: identityFor(binding))
            guard let wire = V2Messages.buildRosterCommit(params, V2Messages.RosterCommitBody(
                reason: "add_device", bindingId: binding.bindingId, epoch: String(epoch), deviceRoster: deviceRoster, packages: packages,
                newDevice: V2Messages.NewDevice(deviceId: newDevice.deviceId, identityPk: newDeviceIdentityPk, encapsulationPk: newDeviceEncapsulationPk)
            )) else { return nil }
            return PreparedAddDevice(wire: wire, eventId: params.eventId, bindingId: binding.bindingId, epoch: epoch, master: master, deviceRoster: deviceRoster, deviceKeys: deviceKeys)
        }

        /// v1.4 section 33/23 (P-45): shrinks the roster by one device. deviceKeys is deliberately
        /// NOT shrunk.
        public func removeDevice(chatId: String, targetDeviceId: String) -> String? {
            guard let binding = bindingStore.current(chatId), tombstoneStore.unpairedFor(binding.bindingId) == nil else { return nil }
            guard binding.deviceRoster.contains(targetDeviceId) else { return nil }
            let master = V2Suite.randomBytes(32)
            let epoch = binding.epoch + 1
            let deviceRoster = binding.deviceRoster.filter { $0 != targetDeviceId }
            guard let packages = sealForRoster(roster: deviceRoster, deviceKeys: binding.deviceKeys, master: master) else { return nil }
            guard let wire = V2Messages.buildRosterCommit(envelopeParams(chatId: chatId, identity: identityFor(binding)), V2Messages.RosterCommitBody(
                reason: "remove_device", bindingId: binding.bindingId, epoch: String(epoch), deviceRoster: deviceRoster, packages: packages, newDevice: nil
            )) else { return nil }
            bindingStore.applyRosterCommit(chatId: chatId, epoch: epoch, deviceRoster: deviceRoster, deviceKeys: binding.deviceKeys)
            keyStore.installCurrent(bindingId: binding.bindingId, epoch: epoch, master: master)
            return wire
        }

        /// Receives a REKEY/ADD_DEVICE/REMOVE_DEVICE. Verification order matters:
        /// 1. v1.4 section 27/33's "unbind takes priority" (P-46) — checked by the WIRE's OWN claimed
        ///    bindingId, before anything else, since UNPAIR clears bindingStore.current entirely.
        /// 2. a binding must still be CURRENT for this chat.
        /// 3. the actor must be a member of the CURRENT roster BEFORE this commit.
        /// 4. epoch must be exactly current+1 — anything less is a replay (ALREADY_APPLIED), anything
        ///    further ahead is refused rather than guessed at.
        /// 5. only THEN is this device's own package (if any) looked up and unsealed.
        ///
        /// SECUTG-HOOK (fix C0, 2026-09-27): `localChatId` = the chat this device received the commit in
        /// (its own name for the conversation). The envelope's `chat_id` is the SENDER's view, which on a
        /// real 1:1 chat is this device's own user id, so looking the binding up by it never found the
        /// real one. nil keeps the old behaviour (envelope chat id) for callers on a shared chat id.
        public func handleRosterCommit(_ wire: String, localChatId: String? = nil) -> RosterCommitOutcome {
            guard let parsed = V2Messages.parseRosterCommit(wire) else { return .fail("malformed") }
            let chatId = localChatId ?? parsed.envelope.chatId
            guard tombstoneStore.unpairedFor(parsed.body.bindingId) == nil else { return .fail("unpaired") }
            guard let binding = bindingStore.current(chatId) else { return .fail("unknown_binding") }
            guard binding.bindingId == parsed.body.bindingId else { return .fail("wrong_binding") }

            let actorDeviceId = parsed.envelope.actorDevice
            guard let actorKeys = binding.deviceKeys[actorDeviceId], binding.deviceRoster.contains(actorDeviceId) else { return .fail("unauthorized") }
            guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: actorKeys.identityPk) else { return .fail("bad_signature") }

            guard let epoch = Int(parsed.body.epoch) else { return .fail("malformed") }
            guard epoch > 0 else { return .fail("malformed") }
            if epoch <= binding.epoch { return .alreadyApplied() }
            guard epoch == binding.epoch + 1 else { return .fail("epoch_gap") }

            if let consistency = checkReasonConsistency(binding: binding, body: parsed.body) { return .fail(consistency) }

            // PLAN.md 3.39.4 step 5 / 3.39.13: a device that installed its binding from a V2Q looks for — and opens —
            // its package under the per-binding identity the code gave it, never the global one. For a clone that is
            // the showing device's own identity, so a REKEY either of them issues opens on the other too.
            let ownDeviceId = V2OwnIdentity.ownDeviceId(for: binding, fallback: identity)
            let ownIdentity = identityFor(binding)
            let ownPackage = parsed.body.packages.first { $0.deviceId == ownDeviceId }
            let deviceKeys = nextDeviceKeys(binding: binding, body: parsed.body)
            guard let ownPackage = ownPackage else {
                // P-45: this device is not in the new roster. Nothing installs.
                return .notForMe()
            }
            guard let sealed = Base64Url.decode(ownPackage.pkg) else { return .fail("malformed") }
            guard let master = V2Suite.openSealed(recipientPk: ownIdentity.encapsulationPk, recipientSk: ownIdentity.encapsulationSk, sealed: sealed), master.count == 32 else {
                return .fail("bad_package")
            }

            bindingStore.applyRosterCommit(chatId: chatId, epoch: epoch, deviceRoster: parsed.body.deviceRoster, deviceKeys: deviceKeys)
            keyStore.installCurrent(bindingId: binding.bindingId, epoch: epoch, master: master)
            return .installed(master, commitReason: parsed.body.reason, newDevice: parsed.body.newDevice)
        }

        /// reason-specific shape checks that go beyond what parseRosterCommit alone can validate
        /// context-free.
        private func checkReasonConsistency(binding: V2Binding, body: V2Messages.RosterCommitBody) -> String? {
            if body.reason == "rekey", body.deviceRoster.count != binding.deviceRoster.count { return "roster_mismatch" }
            if body.reason == "add_device" {
                guard let newDevice = body.newDevice else { return "malformed" }
                if binding.deviceRoster.contains(newDevice.deviceId) { return "already_member" }
                guard let claimedPk = Base64Url.decode(newDevice.identityPk), Base64Url.encode(V2Suite.sha256(claimedPk)) == newDevice.deviceId else {
                    return "bad_device_id"
                }
                if body.deviceRoster.count != binding.deviceRoster.count + 1 { return "roster_mismatch" }
            }
            if body.reason == "remove_device", body.deviceRoster.count != binding.deviceRoster.count - 1 { return "roster_mismatch" }
            return nil
        }

        /// The roster's device->keys directory AFTER this commit — grown for add_device, unchanged
        /// otherwise.
        private func nextDeviceKeys(binding: V2Binding, body: V2Messages.RosterCommitBody) -> [String: V2Binding.DeviceKeys] {
            guard body.reason == "add_device", let newDevice = body.newDevice else { return binding.deviceKeys }
            var out = binding.deviceKeys
            out[newDevice.deviceId] = V2Binding.DeviceKeys(identityPk: newDevice.identityPk, encapsulationPk: newDevice.encapsulationPk)
            return out
        }
    }
}
