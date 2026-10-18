import Foundation
import Security

/// v2 state persistence: the same sealed-blob technique `SecutgKeyRingStorage`
/// (`submodules/TelegramCore/Sources/Secutg/SecutgKeyRingStorage.swift`) already uses for v1's
/// keyring — a JSON snapshot sealed with a random 32-byte key that lives in the Keychain (one entry
/// per account), the sealed blob written to disk — but writing to an INDEPENDENT Keychain service/
/// account and an INDEPENDENT file: v2 state must never share v1's `keyring.bin`, so a wipe or a
/// migration of one can never accidentally touch the other.
///
/// This copy lives in `SecutgCore` (rather than beside `SecutgKeyRingStorage` in
/// `TelegramCore/Sources/Secutg`) specifically so `swift test` can exercise a real Keychain+file
/// round trip without the app target, matching how `KeyRingStorage`'s own sealing primitive
/// (`SealedBlob`) already lives in `SecutgCore/Crypto`. The only reason v1's concrete Keychain
/// wrapper sits in the runtime layer instead is that nothing in this package needed it there before
/// now; importing `Security` does not violate this package's "pure Swift + libsodium" boundary
/// (`Security` is a system framework on every platform this package targets, exactly like
/// `Foundation`), and it keeps this file testable the same way `SealedBlobTests`/`KeyRingTests`
/// already are.
///
/// Any read failure yields no snapshot (`V2PersistedState.load` then starts every store empty),
/// mirroring `SecutgKeyRingStorage.load`'s "never crash the receive hook" contract; any write
/// failure is logged, never thrown.
public final class V2KeychainStorage: V2Storage {
    private static let service = "org.secutg.v2state"
    private let keychainAccount: String
    private let fileURL: URL
    private let lock = NSLock()
    private var cachedKey: [UInt8]?

    public init(accountKey: String, basePath: String) {
        self.keychainAccount = "v2state-\(accountKey)"
        self.fileURL = URL(fileURLWithPath: basePath)
            .appendingPathComponent("secutg", isDirectory: true)
            .appendingPathComponent("v2-state.bin")
    }

    public func load() -> V2PersistedState.Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let blob = try? Data(contentsOf: fileURL), let key = deviceKey(createIfMissing: false),
              let json = SealedBlob.open(blob, key: key) else { return nil }
        return try? JSONDecoder().decode(V2PersistedState.Snapshot.self, from: json)
    }

    public func save(_ snapshot: V2PersistedState.Snapshot) {
        lock.lock(); defer { lock.unlock() }
        guard let json = try? JSONEncoder().encode(snapshot) else {
            NSLog("[secutg] v2 state save skipped: encode failed")
            return
        }
        guard let key = deviceKey(createIfMissing: true), let blob = try? SealedBlob.seal(json, key: key) else {
            NSLog("[secutg] v2 state save skipped: no device key")
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
            NSLog("[secutg] v2 state save failed: \(error)")
        }
    }

    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        for dataProtection in V2KeychainStorage.keychainVariants {
            SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
        }
        cachedKey = nil
    }

    /// macOS: the data-protection keychain needs an application-identifier entitlement; unsigned /
    /// ad-hoc development builds fall back to the legacy login keychain so keys still persist. Two
    /// passes rather than "decide per variant as we go" (which `SecutgKeyRingStorage.deviceKey`
    /// does, and which this file inherited on a first pass too): a variant that reports
    /// "not found" for a READ is not the same as a variant this device cannot use at all, and a
    /// read-only call (`createIfMissing: false`) must keep checking every remaining variant before
    /// concluding there is truly no key anywhere — otherwise a key written under the legacy-keychain
    /// fallback is never found again by a later `load()`, which tries the data-protection variant
    /// first and stops there. Only once every variant has been checked for an EXISTING key does a
    /// write (when `createIfMissing`) start, trying each variant in order and keeping the first one
    /// that actually accepts the write.
    private func deviceKey(createIfMissing: Bool) -> [UInt8]? {
        if let cachedKey = cachedKey { return cachedKey }
        for dataProtection in V2KeychainStorage.keychainVariants {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, data.count == SealedBlob.keyBytes {
                cachedKey = [UInt8](data)
                return cachedKey
            }
        }
        guard createIfMissing else { return nil }
        for dataProtection in V2KeychainStorage.keychainVariants {
            let fresh = SealedBlob.generateKey()
            var add = baseQuery(dataProtection: dataProtection)
            add[kSecValueData as String] = Data(fresh)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecMissingEntitlement { continue }
            guard addStatus == errSecSuccess else {
                if addStatus == errSecDuplicateItem {
                    // A duplicate means an item exists that this build could not read back above (macOS
                    // legacy keychain binds the item to the code signature; every re-signed dev build
                    // hits this until the user clicks "Always Allow"). Never adopt a fresh key in that
                    // case: it would silently reseal and wipe the persisted state.
                    NSLog("[secutg] v2 state keychain device key exists but is not readable by this build; state stays locked, not reset")
                } else {
                    NSLog("[secutg] v2 state keychain add failed: \(addStatus)")
                }
                continue
            }
            cachedKey = fresh
            return fresh
        }
        NSLog("[secutg] no usable keychain for v2 state (missing entitlement)")
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
            kSecAttrService as String: V2KeychainStorage.service,
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
