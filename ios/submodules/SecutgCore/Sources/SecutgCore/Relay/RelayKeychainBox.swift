import Foundation
import Security

/// The same sealed-blob-in-Keychain technique `V2KeychainStorage` uses for v2 state, factored out so the relay
/// module's app-level and per-account stores can each get their own independent Keychain service/account and
/// file — a relay wipe must never share a key with, or be confused for, the keyring or v2 state wipe.
///
/// Lives inside `Relay/` (rather than being a third copy of `V2KeychainStorage`'s logic placed centrally)
/// specifically so the whole relay feature stays the single, independent, deletable unit PLAN.md 3.48.0
/// requires — nothing outside this folder depends on it, and nothing in this folder reaches outside it.
final class RelayKeychainBox {
    private let service: String
    private let account: String
    private let fileURL: URL
    private let lock = NSLock()
    private var cachedKey: [UInt8]?

    init(service: String, account: String, fileURL: URL) {
        self.service = service
        self.account = account
        self.fileURL = fileURL
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let blob = try? Data(contentsOf: fileURL), let key = deviceKey(createIfMissing: false),
              let json = SealedBlob.open(blob, key: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: json)
    }

    func save<T: Encodable>(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        guard let json = try? JSONEncoder().encode(value) else {
            NSLog("[secutg] relay store save skipped: encode failed")
            return
        }
        guard let key = deviceKey(createIfMissing: true), let blob = try? SealedBlob.seal(json, key: key) else {
            NSLog("[secutg] relay store save skipped: no device key")
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
            NSLog("[secutg] relay store save failed: \(error)")
        }
    }

    func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        for dataProtection in RelayKeychainBox.keychainVariants {
            SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
        }
        cachedKey = nil
    }

    // MARK: - Keychain plumbing (mirrors V2KeychainStorage)

    #if os(macOS)
    private static let keychainVariants: [Bool] = [true, false]
    #else
    private static let keychainVariants: [Bool] = [false]
    #endif

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if dataProtection, #available(macOS 10.15, *) {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    private func deviceKey(createIfMissing: Bool) -> [UInt8]? {
        if let cachedKey = cachedKey { return cachedKey }
        for dataProtection in RelayKeychainBox.keychainVariants {
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
        for dataProtection in RelayKeychainBox.keychainVariants {
            let fresh = SealedBlob.generateKey()
            var add = baseQuery(dataProtection: dataProtection)
            add[kSecValueData as String] = Data(fresh)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecMissingEntitlement { continue }
            guard addStatus == errSecSuccess else {
                if addStatus != errSecDuplicateItem {
                    NSLog("[secutg] relay store keychain add failed: \(addStatus)")
                }
                continue
            }
            cachedKey = fresh
            return fresh
        }
        NSLog("[secutg] no usable keychain for relay store (missing entitlement)")
        return nil
    }
}
