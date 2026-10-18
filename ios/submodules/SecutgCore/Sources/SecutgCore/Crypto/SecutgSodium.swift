import Clibsodium
import Foundation

/// libsodium bootstrap. `sodium_init` is idempotent; every entry point calls `ensureReady()`.
public enum SecutgSodium {
    private static let initialised: Bool = sodium_init() >= 0

    /// Returns false only when libsodium itself refused to initialise (never expected).
    @discardableResult
    public static func ensureReady() -> Bool {
        return initialised
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        ensureReady()
        var out = [UInt8](repeating: 0, count: count)
        randombytes_buf(&out, count)
        return out
    }

    public static var versionString: String {
        return String(cString: sodium_version_string())
    }
}

public enum SecutgCryptoError: Error, Equatable {
    case invalidKeyId
    case invalidKey
    case plaintextTooLong(wireChars: Int)
    case sodiumFailure(String)
}
