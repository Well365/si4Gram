import Foundation

/// Bootstraps v2's runtime — the v2 analog of `SecutgHookRegistry.install` (Web integration draft's
/// `hooks/init.ts` iOS analog). Reuses v1's identity per `V2IdentityBridge`'s own coexistence
/// decision, so v1's identity must already exist (an account that has never announced a v1 identity
/// yields `nil`, same condition `V2IdentityBridge.identity` reports).
///
/// Called from `Account.init` (`TelegramCore/Sources/Account/Account.swift`), right after the
/// existing `SecutgHookRegistry.shared.install(...)` call — unconditionally, with no "is this a
/// fresh install" gate, matching every other v2 startup call site (Web/Android's own unconditional
/// calls). `Account.init` can run more than once per process for the same account (account
/// rebuilds), so this function is idempotent the same way `SecutgHookRegistry.install` already is:
/// see the "already exists" check below.
public enum V2Bootstrap {
    /// Serializes the whole "check registry, maybe build, maybe store" sequence below so two
    /// concurrent callers for the same `accountKey` can never both observe "nothing registered yet"
    /// and each build (and each `set`) their own `V2Runtime` — only one of the two builds would win
    /// the last `V2RuntimeRegistry.set`, silently dropping whichever runtime's in-flight pairing
    /// transaction / dedup state lost the race. `V2RuntimeRegistry` itself only guards each
    /// individual `get`/`set`/`reset`, not this whole read-then-write sequence, so the lock lives
    /// here (the one caller of that sequence), same division of responsibility
    /// `SecutgHookRegistry.install` uses (its own lock, around its own check-then-build-then-store).
    private static let lock = NSLock()

    /// `accountKey` scopes both the `V2RuntimeRegistry` entry and the Keychain/file storage — callers
    /// pass whatever they already use to identify an account (e.g. the account's own v2 `userId`, or
    /// an `accountRecordId`, whichever this device already keys v1's own per-account storage by).
    ///
    /// Idempotent per `accountKey`: a `V2Runtime` already registered for it is returned as-is —
    /// never rebuilt — so a second call within the same process can never silently replace (and
    /// thereby lose the in-flight pairing transaction / dedup state of) a runtime a first call
    /// already installed. Only the very first call for a given `accountKey` in this process actually
    /// constructs a `V2Runtime`.
    ///
    /// Returns `nil` (and clears any previous entry for `accountKey`) when v1 has no identity yet.
    @discardableResult
    public static func initV2Worker(accountKey: String, userId: String, basePath: String, storedIdentity: KeyRing.Identity?) -> V2Runtime? {
        lock.lock(); defer { lock.unlock() }
        if let existing = V2RuntimeRegistry.shared.runtime(for: accountKey) {
            return existing
        }
        guard let identity = V2IdentityBridge.identity(userId: userId, from: storedIdentity) else {
            V2RuntimeRegistry.shared.reset(for: accountKey)
            return nil
        }
        let storage = V2KeychainStorage(accountKey: accountKey, basePath: basePath)
        let persisted = V2PersistedState.load(storage: storage)
        let runtime = V2Runtime(identity: identity, persisted: persisted)
        V2RuntimeRegistry.shared.set(runtime, for: accountKey)
        return runtime
    }
}
