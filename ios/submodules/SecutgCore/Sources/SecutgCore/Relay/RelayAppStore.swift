import Foundation

/// Backend for `RelayAppConfig` (PLAN.md 3.48.5: settings, relay list, trust list — app-level, shared by every
/// account on this device, independent of the keyring/v2 state Keychain items). Mirrors `V2Storage`'s shape.
public protocol RelayAppStore: AnyObject {
    func load() -> RelayAppConfig?
    func save(_ config: RelayAppConfig)
    func wipe()
}

public extension RelayAppStore {
    func wipe() { save(.empty) }
}

/// Fast path for tests.
public final class RelayMemoryAppStore: RelayAppStore {
    public private(set) var saved: RelayAppConfig?

    public init(_ initial: RelayAppConfig? = nil) {
        saved = initial
    }

    public func load() -> RelayAppConfig? { return saved }
    public func save(_ config: RelayAppConfig) { saved = config }
    public func wipe() { saved = nil }
}

/// The real backend: a sealed blob under its own Keychain service/account, independent of every other
/// secuTG store (PLAN.md 3.48.0 rule 5 — "自己的存储…不复用已有结构").
public final class RelayKeychainAppStore: RelayAppStore {
    private let box: RelayKeychainBox

    public init(basePath: String) {
        let fileURL = URL(fileURLWithPath: basePath)
            .appendingPathComponent("secutg", isDirectory: true)
            .appendingPathComponent("relay-app.bin")
        self.box = RelayKeychainBox(service: "org.secutg.relay.app", account: "app", fileURL: fileURL)
    }

    public func load() -> RelayAppConfig? { return box.load(RelayAppConfig.self) }
    public func save(_ config: RelayAppConfig) { box.save(config) }
    public func wipe() { box.wipe() }
}
