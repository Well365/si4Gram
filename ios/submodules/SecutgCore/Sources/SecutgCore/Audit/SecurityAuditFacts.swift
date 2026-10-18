import Foundation

/// PLAN.md 3.46: building the audit's input. The runtime reads each chat's raw facts (`ChatFacts`) out of the
/// keyring and the v2 state; this file reduces them to a `SecurityAudit.Chat` with the same precedence the lock
/// menu uses, and assembles the snapshot. Pure; what it receives is already only states, times and counts — no
/// text, no keys. Web reference: `src/secutg/audit/snapshot.ts`.
public enum SecurityAuditFacts {
    /// v1 `KeyRing.Pairing.State` raw values (`invited`, `paired`, `key_changed`, `other_device`).
    public struct V1Pairing: Equatable {
        public let state: String
        public let verified: Bool

        public init(state: String, verified: Bool) {
            self.state = state
            self.verified = verified
        }
    }

    public struct V2Binding: Equatable {
        public let verified: Bool
        public let suspended: Bool
        public let mismatch: Bool
        public let mismatchOverride: Bool
        public let cloned: Bool

        public init(verified: Bool, suspended: Bool, mismatch: Bool, mismatchOverride: Bool, cloned: Bool) {
            self.verified = verified
            self.suspended = suspended
            self.mismatch = mismatch
            self.mismatchOverride = mismatchOverride
            self.cloned = cloned
        }
    }

    public enum V2Transaction: String, Equatable {
        case waiting
        case conflict
    }

    /// The cached incoming v2 INVITE, already judged against the binding (an expired one is left out by the reader).
    public struct V2Invite: Equatable {
        public let isNewerThanBinding: Bool
        public let isUnknownIdentity: Bool

        public init(isNewerThanBinding: Bool, isUnknownIdentity: Bool) {
            self.isNewerThanBinding = isNewerThanBinding
            self.isUnknownIdentity = isUnknownIdentity
        }
    }

    public struct KeyRequiredFacts: Equatable {
        public let isOn: Bool
        /// The switch was turned off while the chat had a key (3.41.1's record of a manual choice).
        public let offHadKey: Bool

        public init(isOn: Bool, offHadKey: Bool) {
            self.isOn = isOn
            self.offHadKey = offHadKey
        }
    }

    public struct ChatFacts: Equatable {
        public let chatId: String
        public let kind: SecurityAudit.ChatKind
        public let hasKey: Bool
        public let v1Pairing: V1Pairing?
        public let v2Binding: V2Binding?
        public let v2Transaction: V2Transaction?
        public let v2Invite: V2Invite?
        public let groupKeyCreatedMs: Int64?
        /// (active, unlocked) of the group password policy (3.38); nil without one.
        public let groupPassword: (active: Bool, unlocked: Bool)?
        public let keyRequired: KeyRequiredFacts?
        public let plaintextOnDisk: Bool

        public init(chatId: String, kind: SecurityAudit.ChatKind, hasKey: Bool, v1Pairing: V1Pairing? = nil,
                    v2Binding: V2Binding? = nil, v2Transaction: V2Transaction? = nil, v2Invite: V2Invite? = nil,
                    groupKeyCreatedMs: Int64? = nil, groupPassword: (active: Bool, unlocked: Bool)? = nil,
                    keyRequired: KeyRequiredFacts? = nil, plaintextOnDisk: Bool = false) {
            self.chatId = chatId
            self.kind = kind
            self.hasKey = hasKey
            self.v1Pairing = v1Pairing
            self.v2Binding = v2Binding
            self.v2Transaction = v2Transaction
            self.v2Invite = v2Invite
            self.groupKeyCreatedMs = groupKeyCreatedMs
            self.groupPassword = groupPassword
            self.keyRequired = keyRequired
            self.plaintextOnDisk = plaintextOnDisk
        }

        public static func == (lhs: ChatFacts, rhs: ChatFacts) -> Bool {
            return lhs.chatId == rhs.chatId && lhs.kind == rhs.kind && lhs.hasKey == rhs.hasKey
                && lhs.v1Pairing == rhs.v1Pairing && lhs.v2Binding == rhs.v2Binding && lhs.v2Transaction == rhs.v2Transaction
                && lhs.v2Invite == rhs.v2Invite && lhs.groupKeyCreatedMs == rhs.groupKeyCreatedMs
                && lhs.groupPassword?.active == rhs.groupPassword?.active && lhs.groupPassword?.unlocked == rhs.groupPassword?.unlocked
                && lhs.keyRequired == rhs.keyRequired && lhs.plaintextOnDisk == rhs.plaintextOnDisk
        }
    }

    private static func v2Pairing(_ binding: V2Binding) -> SecurityAudit.Pairing {
        if binding.mismatch { return binding.mismatchOverride ? .mismatchOverride : .mismatch }
        return binding.suspended ? .suspended : .paired
    }

    private static func v1Pairing(_ pairing: V1Pairing) -> SecurityAudit.Pairing {
        switch pairing.state {
        case KeyRing.Pairing.State.invited.rawValue: return .waiting
        case KeyRing.Pairing.State.otherDevice.rawValue: return .conflict
        default: return .paired
        }
    }

    /// v2 binding first, then a v2 transaction, then v1 — the same precedence the lock menu uses.
    public static func assemble(_ facts: ChatFacts) -> SecurityAudit.Chat {
        let pairing: SecurityAudit.Pairing
        if let binding = facts.v2Binding {
            pairing = v2Pairing(binding)
        } else if let transaction = facts.v2Transaction {
            pairing = transaction == .waiting ? .waiting : .conflict
        } else if let v1 = facts.v1Pairing {
            pairing = v1Pairing(v1)
        } else {
            pairing = .none
        }
        let verified = facts.v2Binding.map { $0.verified } ?? (facts.v1Pairing?.verified ?? false)
        // An invite older than the binding is history re-rendering, not an offer
        let liveInvite = facts.v2Invite.flatMap { invite in (facts.v2Binding == nil || invite.isNewerThanBinding) ? invite : nil }
        let keyChangedInvite = (facts.v2Binding != nil && (liveInvite?.isUnknownIdentity ?? false))
            || facts.v1Pairing?.state == KeyRing.Pairing.State.keyChanged.rawValue
        let keyRequired: Bool?
        if let record = facts.keyRequired, record.isOn || record.offHadKey || facts.hasKey {
            keyRequired = record.isOn
        } else {
            keyRequired = nil
        }
        return SecurityAudit.Chat(
            chatId: facts.chatId,
            kind: facts.kind,
            pairing: pairing,
            verified: verified,
            inviteReceived: liveInvite != nil && !keyChangedInvite,
            keyChangedInvite: keyChangedInvite,
            hasKey: facts.hasKey,
            groupKeyCreatedMs: facts.kind == .group ? facts.groupKeyCreatedMs : nil,
            groupPasswordActive: facts.groupPassword?.active ?? false,
            groupPasswordUnlocked: facts.groupPassword?.unlocked ?? false,
            keyRequired: keyRequired,
            plaintextOnDisk: facts.plaintextOnDisk,
            cloned: facts.v2Binding?.cloned ?? false)
    }

    /// Everything that lives next to the keyring (the runtime's half).
    public struct RuntimePart: Equatable {
        public let chats: [ChatFacts]
        public let localCiphertext: Bool
        public let wipePhraseSet: Bool
        public let wipeListens: Bool
        public let lastKeyChangeMs: Int64?

        public init(chats: [ChatFacts], localCiphertext: Bool, wipePhraseSet: Bool, wipeListens: Bool, lastKeyChangeMs: Int64?) {
            self.chats = chats
            self.localCiphertext = localCiphertext
            self.wipePhraseSet = wipePhraseSet
            self.wipeListens = wipeListens
            self.lastKeyChangeMs = lastKeyChangeMs
        }

        /// What a device with no keyring loaded yet reports: valid, and quiet.
        public static let empty = RuntimePart(chats: [], localCiphertext: true, wipePhraseSet: false, wipeListens: true, lastKeyChangeMs: nil)
    }

    /// What the app adds.
    public struct AppPart: Equatable {
        public let groupKeyMaxAgeDays: Int
        public let apiCredentialSource: ApiCredentialRules.Source
        public let netGateEnabled: Bool
        public let lastBackupMs: Int64?
        public let ownVersion: String?
        public let newestPeerVersion: String?
        public let assistant: SecurityAudit.Assistant?
        /// PLAN.md 3.46.2: read from Telegram by the UI when the page opens; `.unknown` before that (or on failure).
        public let account: SecurityAudit.Account

        public init(groupKeyMaxAgeDays: Int, apiCredentialSource: ApiCredentialRules.Source, netGateEnabled: Bool,
                    lastBackupMs: Int64?, ownVersion: String?, newestPeerVersion: String?, assistant: SecurityAudit.Assistant?,
                    account: SecurityAudit.Account = .unknown) {
            self.groupKeyMaxAgeDays = groupKeyMaxAgeDays
            self.apiCredentialSource = apiCredentialSource
            self.netGateEnabled = netGateEnabled
            self.lastBackupMs = lastBackupMs
            self.ownVersion = ownVersion
            self.newestPeerVersion = newestPeerVersion
            self.assistant = assistant
            self.account = account
        }
    }

    public static func snapshot(runtime: RuntimePart, app: AppPart) -> SecurityAudit.Snapshot {
        return SecurityAudit.Snapshot(
            chats: runtime.chats.map(assemble),
            settings: SecurityAudit.Settings(groupKeyMaxAgeDays: app.groupKeyMaxAgeDays, localCiphertext: runtime.localCiphertext,
                                             wipePhraseSet: runtime.wipePhraseSet, wipeListens: runtime.wipeListens,
                                             netGateEnabled: app.netGateEnabled, apiCredentialSource: app.apiCredentialSource),
            lastBackupMs: app.lastBackupMs,
            lastKeyChangeMs: runtime.lastKeyChangeMs,
            ownVersion: app.ownVersion,
            newestPeerSeen: app.newestPeerVersion,
            assistant: app.assistant,
            account: app.account)
    }
}
