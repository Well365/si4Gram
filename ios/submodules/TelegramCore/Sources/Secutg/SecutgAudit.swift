import Foundation
import SecutgCore

/// SECUTG (PLAN.md 3.46 安全体检): the keyring / v2 half of the check-up snapshot for this account, read by the
/// shared `SecurityAuditReader` in SecutgCore. States, times and counts only — no message text, no key material —
/// and the caller neither stores nor logs it.
///
/// `plaintextOnDisk` is reported false for every chat: the message store keeps no per-chat record of whether rows
/// older than the 3.19 switch are still readable, and finding out would mean reading message text, which the
/// check-up must never do. Check 5 still reports the switch itself.
extension SecutgAccountRuntime {
    public func auditRuntimePart() -> SecurityAuditFacts.RuntimePart {
        return SecurityAuditReader.runtimePart(ring: ring, v2: V2RuntimeRegistry.shared.runtime(for: ownUserId), ownUserId: ownUserId)
    }
}
