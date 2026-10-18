import Foundation

/// v1.4 section 18 step 6: "merges historical material in one transaction; the currently-trusted
/// binding and group state are never overwritten by an old backup" plus step 7's "send eligibility
/// needs a separate restoration" — the piece `V2K2`'s own module doc named as deliberately deferred:
/// `V2K2.validateForImport` only flags what is SAFE to merge, it never writes anything. This file is
/// that write. Ported from `src/secutg/v2/backup/merge.ts` and `org.telegram.secutg.v2.backup.Merge`.
///
/// Every record this file installs lands as HISTORICAL, NEVER CURRENT. Only the caller's own real
/// send-eligibility path (an actual REKEY, an actual roster confirmation) can ever mark something
/// CURRENT.
public enum V2Merge {
    public enum SkipReason {
        /// Local state already holds this generation as CURRENT or HISTORICAL, with DIFFERENT key
        /// material.
        case conflictsWithCurrentState
        /// The record's own master field failed to decode — malformed input, never written.
        case malformedMaster
        /// A scopeKind=group record with no stateHash — cannot be re-keyed into GroupKeyStore at all.
        case missingStateHash
    }

    public struct Skipped {
        public let record: V2K2.KeyRecord
        public let reason: SkipReason
    }

    public struct Outcome {
        public let installed: [V2K2.KeyRecord]
        public let alreadyPresent: [V2K2.KeyRecord]
        public let skipped: [Skipped]
    }

    /// Merges records that `V2K2.validateForImport` already accepted (internally conflict-free) into
    /// the local stores. Each record is evaluated independently against local state — no record is
    /// ever partially written, it is either fully installed or fully skipped.
    public static func mergeValidatedRecords(_ records: [V2K2.KeyRecord], bindingKeyStore: V2KeyStore.BindingKeyStore, groupKeyStore: V2GroupKeyStore) -> Outcome {
        var installed: [V2K2.KeyRecord] = []
        var alreadyPresent: [V2K2.KeyRecord] = []
        var skipped: [Skipped] = []

        for record in records {
            if record.scopeKind == "group", record.stateHash == nil {
                skipped.append(Skipped(record: record, reason: .missingStateHash))
                continue
            }
            guard let master = Base64Url.decode(record.master) else {
                skipped.append(Skipped(record: record, reason: .malformedMaster))
                continue
            }

            var existingMaster: [UInt8]? = nil
            if record.scopeKind == "private" {
                existingMaster = bindingKeyStore.get(record.bindingOrGenesisId, record.epoch)?.master
            } else if let stateHash = record.stateHash {
                existingMaster = groupKeyStore.get(record.bindingOrGenesisId, stateHash)?.master
            }

            if let existingMaster = existingMaster {
                if existingMaster == master {
                    alreadyPresent.append(record)
                } else {
                    skipped.append(Skipped(record: record, reason: .conflictsWithCurrentState))
                }
                continue
            }

            if record.scopeKind == "private" {
                bindingKeyStore.set(V2KeyStore.Record(bindingId: record.bindingOrGenesisId, epoch: record.epoch, status: .historical, master: master))
            } else if let stateHash = record.stateHash {
                groupKeyStore.set(V2GroupKeyStore.KeyRecord(groupId: record.bindingOrGenesisId, stateHash: stateHash, epoch: record.epoch, status: .historical, master: master))
            }
            installed.append(record)
        }

        return Outcome(installed: installed, alreadyPresent: alreadyPresent, skipped: skipped)
    }
}
