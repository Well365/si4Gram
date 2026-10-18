import Foundation

/// v1.4 section 29's pair_authorization — the policy that gates AUTO-accept, kept strictly apart from
/// auto-CONTINUE. Ported from `src/secutg/v2/pairing/authorization.ts` and
/// `org.telegram.secutg.v2.pairing.Authorization`.
///
/// Section 29 draws that line explicitly: "auto-continue" is this device resuming an exchange it
/// already, explicitly, took part in — nothing in this file is involved, the pairing processor's own
/// retry/replay handling covers it. "Auto-accept" is producing a FIRST ACCEPT with no tap at all, and
/// that needs a standing grant that existed BEFORE the invite did: "receiving an invite, opening the
/// chat, logging in, or importing history do not themselves constitute authorization". This store is
/// where that grant lives, and the one thing every method here protects is that the grant is checked,
/// never inferred.
public enum V2Authorization {
    public enum Status: Codable {
        case active, consumed, expired, revoked
    }

    public struct Policy: Codable {
        public let policyId: String
        public let localDevice: String
        public let chatId: String
        public let peerUser: String
        /// Ed25519 public key, base64url. The peer's identity key must match exactly.
        public let peerSignPk: String
        public let createdAtMs: Int64
        public let expiresAtMs: Int64

        public init(policyId: String, localDevice: String, chatId: String, peerUser: String, peerSignPk: String, createdAtMs: Int64, expiresAtMs: Int64) {
            self.policyId = policyId
            self.localDevice = localDevice
            self.chatId = chatId
            self.peerUser = peerUser
            self.peerSignPk = peerSignPk
            self.createdAtMs = createdAtMs
            self.expiresAtMs = expiresAtMs
        }
    }

    private final class StoredPolicy {
        let policy: Policy
        var status: Status
        /// Set once, the first time a matching INVITE is found eligible — section 29: "the first time
        /// an eligible transaction is selected, the authorization locks to that txn".
        var lockedTxnId: String?

        init(policy: Policy, status: Status) {
            self.policy = policy
            self.status = status
        }
    }

    public final class AuthorizationStore {
        private var policies: [String: StoredPolicy] = [:]

        public init() { }

        public func register(_ policy: Policy) {
            policies[policy.policyId] = StoredPolicy(policy: policy, status: .active)
        }

        public func revoke(_ policyId: String) {
            policies[policyId]?.status = .revoked
        }

        /// The one read this whole file exists for: is there a standing, unexpired, still-ACTIVE
        /// grant for exactly this (chatId, peerUser, peerSignPk), evaluated at nowMs — never at the
        /// invite's own claimed send time (v1.4 section 28: "the deadline check uses the moment of
        /// THIS processing, not what the message itself claims"). A policy already locked to a
        /// DIFFERENT txnId is not eligible — section 29's "other invites do not auto-consume it".
        ///
        /// Finding one does not consume it; `lockToTxn` is the separate, explicit step that does, so a
        /// caller can check eligibility without side effects.
        public func findEligible(chatId: String, peerUser: String, peerSignPk: String, nowMs: Int64, txnId: String) -> Policy? {
            for stored in policies.values {
                guard stored.status == .active else { continue }
                guard stored.policy.chatId == chatId, stored.policy.peerUser == peerUser, stored.policy.peerSignPk == peerSignPk else { continue }
                guard nowMs < stored.policy.expiresAtMs else { continue }
                if let locked = stored.lockedTxnId, locked != txnId { continue }
                return stored.policy
            }
            return nil
        }

        /// Locks policyId to txnId — the moment section 29 describes as "the first time an eligible
        /// transaction is selected".
        public func lockToTxn(policyId: String, txnId: String) {
            guard let stored = policies[policyId], stored.status == .active, stored.lockedTxnId == nil else { return }
            stored.lockedTxnId = txnId
        }

        /// Section 29: "authorization is invalidated on success or on release". The processor calls
        /// this at every terminal point for txnId (completed, cancelled, unpaired) rather than the
        /// caller having to track which policy a txn consumed.
        public func consumeByTxn(_ txnId: String) {
            for stored in policies.values where stored.lockedTxnId == txnId && stored.status == .active {
                stored.status = .consumed
            }
        }

        /// The exchange it was locked to reached a terminal state. Section 29: "invalidated on
        /// success or release" and "failure or expiry does not auto-unlock to the next invite, the
        /// user must re-authorize" — both directions end the SAME way, consumed, and neither hands
        /// the policy to a different invite.
        public func consume(_ policyId: String) {
            policies[policyId]?.status = .consumed
        }

        public func statusOf(_ policyId: String) -> Status? {
            return policies[policyId]?.status
        }

        // MARK: persistence (Web integration draft 1/4)

        /// `StoredPolicy` is a private class (mutation shape), so persistence goes through this
        /// plain, `Codable` value mirror instead — `pairing/authorization.ts`'s own `StoredPolicy`
        /// (there a plain object) serialises directly; here the class/value split needs one explicit
        /// step each way.
        public struct SerializedPolicy: Codable {
            public let policy: Policy
            public let status: Status
            public let lockedTxnId: String?
        }

        public struct Snapshot: Codable {
            public var policies: [SerializedPolicy]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(policies: policies.values.map {
                SerializedPolicy(policy: $0.policy, status: $0.status, lockedTxnId: $0.lockedTxnId)
            })
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> AuthorizationStore {
            let store = AuthorizationStore()
            for serialized in snapshot.policies {
                let stored = StoredPolicy(policy: serialized.policy, status: serialized.status)
                stored.lockedTxnId = serialized.lockedTxnId
                store.policies[serialized.policy.policyId] = stored
            }
            return store
        }
    }
}
