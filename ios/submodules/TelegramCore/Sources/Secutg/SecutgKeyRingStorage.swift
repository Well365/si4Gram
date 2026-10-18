import Foundation
import Security
import SecutgCore

/// Keyring persistence: the JSON snapshot is sealed with a random 32-byte key that lives in the Keychain
/// (one entry per account), and the sealed blob is written to `<account basePath>/secutg/keyring.bin`.
/// Any read failure yields an empty ring — the receive hook must never crash.
final class SecutgKeyRingStorage: KeyRingStorage {
    private static let service = "org.secutg.keyring"
    private let keychainAccount: String
    private let fileURL: URL
    private let lock = NSLock()
    private var cachedKey: [UInt8]?

    init(accountKey: String, basePath: String) {
        self.keychainAccount = "keyring-\(accountKey)"
        self.fileURL = URL(fileURLWithPath: basePath).appendingPathComponent("secutg", isDirectory: true).appendingPathComponent("keyring.bin")
    }

    func load() -> KeyRing.Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let blob = try? Data(contentsOf: fileURL), let key = deviceKey(createIfMissing: false),
              let json = SealedBlob.open(blob, key: key) else { return nil }
        guard let decoded = SnapshotCodec.decodeWithReport(json) else { return nil }
        // PLAN.md 3.0: say what the channel-key migration did. Nothing is force-written here — the decision is
        // a pure function of the same blob, so an unwritten migration simply happens again identically on the
        // next load, and the file becomes version 2 the next time the keyring saves for any other reason.
        if decoded.migration.changed {
            NSLog("[secutg] keyring channel-key migration: moved \(decoded.migration.renamed.count), left ambiguous \(decoded.migration.ambiguous.count), conflicts \(decoded.migration.conflicts.count)")
        }
        return decoded.snapshot
    }

    func save(_ snapshot: KeyRing.Snapshot) {
        lock.lock(); defer { lock.unlock() }
        guard let key = deviceKey(createIfMissing: true), let blob = try? SealedBlob.seal(SnapshotCodec.encode(snapshot), key: key) else {
            NSLog("[secutg] keyring save skipped: no device key")
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try blob.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try blob.write(to: fileURL, options: [.atomic])
            #endif
        } catch {
            NSLog("[secutg] keyring save failed: \(error)")
        }
    }

    // SECUTG-HOOK (PLAN.md 3.16 item 1): the emergency wipe destroys the keyring by deleting the
    // sealed blob outright, rather than resealing an empty snapshot. The Keychain device key is
    // removed too, so the file — if any copy of it lingered in a backup — cannot be reopened.
    func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        for dataProtection in SecutgKeyRingStorage.keychainVariants {
            SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
        }
        cachedKey = nil
    }

    // SECUTG-HOOK: bug fix — a load() must scan every keychain variant for an existing key before
    // giving up. The previous version returned nil as soon as the FIRST variant reported "not found,"
    // even when a later variant held the real key (e.g. a key written under the legacy-keychain
    // fallback on an earlier unsigned build becomes permanently unreadable once a later build's
    // signature grants the data-protection-keychain entitlement and that variant is tried first).
    // Found and root-caused while adding an equivalent, correctly-scanning V2 keychain store
    // (SecutgCore/V2/Persist/V2KeychainStorage.swift) — this file has the same variants/ordering bug.
    private func deviceKey(createIfMissing: Bool) -> [UInt8]? {
        if let cachedKey = cachedKey { return cachedKey }
        // macOS: the data-protection keychain needs an application-identifier entitlement; unsigned /
        // ad-hoc development builds fall back to the legacy login keychain so keys still persist.
        for dataProtection in SecutgKeyRingStorage.keychainVariants {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, data.count == SealedBlob.keyBytes {
                cachedKey = [UInt8](data)
                return cachedKey
            }
            // errSecMissingEntitlement or errSecItemNotFound: this variant has nothing usable — keep
            // scanning the remaining variants instead of giving up on the first miss.
        }
        guard createIfMissing else { return nil }
        for dataProtection in SecutgKeyRingStorage.keychainVariants {
            var probeQuery = baseQuery(dataProtection: dataProtection)
            probeQuery[kSecReturnData as String] = true
            probeQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(probeQuery as CFDictionary, nil)
            if status == errSecMissingEntitlement { continue }
            let fresh = SealedBlob.generateKey()
            var add = baseQuery(dataProtection: dataProtection)
            add[kSecValueData as String] = Data(fresh)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecMissingEntitlement { continue }
            // A duplicate means an item exists that this build could not read (macOS legacy keychain binds the
            // item to the code signature; every re-signed dev build hits this until the user clicks "Always Allow").
            // Never adopt a fresh key in that case: it would silently reseal and wipe the persisted keyring.
            guard addStatus == errSecSuccess else {
                if addStatus == errSecDuplicateItem {
                    NSLog("[secutg] keychain device key exists but is not readable by this build (read status \(status)); keyring stays locked, not reset")
                } else {
                    NSLog("[secutg] keychain add failed: \(addStatus)")
                }
                return nil
            }
            cachedKey = fresh
            return fresh
        }
        NSLog("[secutg] no usable keychain (missing entitlement)")
        return nil
    }

    #if os(macOS)
    private static let keychainVariants: [Bool] = [true, false]
    #else
    private static let keychainVariants: [Bool] = [false]
    #endif

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecutgKeyRingStorage.service,
            kSecAttrAccount as String: keychainAccount,
        ]
        #if os(macOS)
        if dataProtection, #available(macOS 10.15, *) {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}
