import Foundation

/// Per-account relay state (PLAN.md 3.48.5): "what I sent through relays" plus the local copies PLAN.md 3.48.7
/// adds — both destroyed on 3.16 emergency wipe and 3.46.2 forced-logout wipe for that account only, never on
/// an ordinary sign-out.
public struct RelayAccountSnapshot: Codable, Equatable {
    public var sentItems: [RelaySentItem]
    public var localCopies: [String: RelayLocalCopy]
    public var chatPolicies: [String: RelayChatPolicy]

    public init(sentItems: [RelaySentItem] = [], localCopies: [String: RelayLocalCopy] = [:], chatPolicies: [String: RelayChatPolicy] = [:]) {
        self.sentItems = sentItems
        self.localCopies = localCopies
        self.chatPolicies = chatPolicies
    }

    public static let empty = RelayAccountSnapshot()
}

public protocol RelayAccountStore: AnyObject {
    func load() -> RelayAccountSnapshot?
    func save(_ snapshot: RelayAccountSnapshot)
    func wipe()
}

public extension RelayAccountStore {
    func wipe() { save(.empty) }
}

public final class RelayMemoryAccountStore: RelayAccountStore {
    public private(set) var saved: RelayAccountSnapshot?

    public init(_ initial: RelayAccountSnapshot? = nil) {
        saved = initial
    }

    public func load() -> RelayAccountSnapshot? { return saved }
    public func save(_ snapshot: RelayAccountSnapshot) { saved = snapshot }
    public func wipe() { saved = nil }
}

public final class RelayKeychainAccountStore: RelayAccountStore {
    private let box: RelayKeychainBox

    /// `accountKey` must already be unique per Telegram account (the same key the app layer uses for
    /// `V2KeychainStorage`/`SecutgLocalPrefs`), so each account's relay history is wiped independently.
    public init(accountKey: String, basePath: String) {
        let fileURL = URL(fileURLWithPath: basePath)
            .appendingPathComponent("secutg", isDirectory: true)
            .appendingPathComponent("relay-account-\(accountKey).bin")
        self.box = RelayKeychainBox(service: "org.secutg.relay.account", account: accountKey, fileURL: fileURL)
    }

    public func load() -> RelayAccountSnapshot? { return box.load(RelayAccountSnapshot.self) }
    public func save(_ snapshot: RelayAccountSnapshot) { box.save(snapshot) }
    public func wipe() { box.wipe() }
}
