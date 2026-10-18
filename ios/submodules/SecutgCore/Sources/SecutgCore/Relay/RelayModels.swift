import Foundation

/// A relay the user configured (PLAN.md 3.48.4, 我的中转). The token, when present, never leaves the device.
public struct RelayEndpoint: Equatable, Codable, Identifiable {
    public var id: String
    public var urlString: String
    public var token: String?
    public var isDefault: Bool
    public var label: String?

    public init(id: String = UUID().uuidString, urlString: String, token: String?, isDefault: Bool, label: String? = nil) {
        self.id = id
        self.urlString = urlString
        self.token = token
        self.isDefault = isDefault
        self.label = label
    }
}

/// A relay host the user has already accepted (PLAN.md 3.48.4, 信任的中转 / 未知中转先问我).
public struct RelayTrustedHost: Equatable, Codable {
    public var urlString: String
    public var trustedAtMs: Int64

    public init(urlString: String, trustedAtMs: Int64) {
        self.urlString = urlString
        self.trustedAtMs = trustedAtMs
    }
}

/// App-level relay configuration as a whole (PLAN.md 3.48.5): settings, the relay list, and the trust list —
/// everything that is NOT scoped to one Telegram account.
public struct RelayAppConfig: Equatable, Codable {
    public var settings: RelaySettings
    public var relays: [RelayEndpoint]
    public var trustedHosts: [RelayTrustedHost]

    public init(settings: RelaySettings, relays: [RelayEndpoint], trustedHosts: [RelayTrustedHost]) {
        self.settings = settings
        self.relays = relays
        self.trustedHosts = trustedHosts
    }

    public static let empty = RelayAppConfig(settings: .default, relays: [], trustedHosts: [])

    public func isTrusted(urlString: String) -> Bool {
        return trustedHosts.contains { $0.urlString == urlString }
    }

    public func trusting(urlString: String, atMs: Int64) -> RelayAppConfig {
        if isTrusted(urlString: urlString) { return self }
        var copy = self
        copy.trustedHosts.append(RelayTrustedHost(urlString: urlString, trustedAtMs: atMs))
        return copy
    }

    public var defaultRelay: RelayEndpoint? {
        return relays.first(where: { $0.isDefault }) ?? relays.first
    }
}

/// Something this account sent through a relay (PLAN.md 3.48.4 「我发出的中转内容」, 3.48.5 per-account).
public struct RelaySentItem: Equatable, Codable, Identifiable {
    public var id: String // the relay item id
    public var chatId: String
    public var messageId: Int64
    public var relayURL: String
    public var deleteToken: String?
    public var contentType: RelayContentType
    public var keepPolicy: RelayKeepPolicy
    public var createdAtMs: Int64
    public var revoked: Bool
    /// PLAN.md 3.48.7 §4: the withdraw-on-delete DELETE failed and should be retried from the list.
    public var pendingRevokeRetry: Bool

    public init(id: String, chatId: String, messageId: Int64, relayURL: String, deleteToken: String?, contentType: RelayContentType, keepPolicy: RelayKeepPolicy, createdAtMs: Int64, revoked: Bool = false, pendingRevokeRetry: Bool = false) {
        self.id = id
        self.chatId = chatId
        self.messageId = messageId
        self.relayURL = relayURL
        self.deleteToken = deleteToken
        self.contentType = contentType
        self.keepPolicy = keepPolicy
        self.createdAtMs = createdAtMs
        self.revoked = revoked
        self.pendingRevokeRetry = pendingRevokeRetry
    }
}

/// Which side produced a local copy (PLAN.md 3.48.7).
public enum RelayLocalCopyDirection: String, Equatable, Codable {
    case sent
    case received
}

/// The decrypted content, fetched (or produced, if we are the sender) once and kept on this device for as long
/// as the `L1:` message itself exists locally (PLAN.md 3.48.7). Keyed by chat + message id by the store, not by
/// this type.
public struct RelayLocalCopy: Equatable, Codable {
    public var chatId: String
    public var messageId: Int64
    public var contentType: RelayContentType
    public var mime: String
    public var text: String?
    public var imageData: Data?
    public var savedAtMs: Int64
    public var direction: RelayLocalCopyDirection

    public init(chatId: String, messageId: Int64, contentType: RelayContentType, mime: String, text: String?, imageData: Data?, savedAtMs: Int64, direction: RelayLocalCopyDirection) {
        self.chatId = chatId
        self.messageId = messageId
        self.contentType = contentType
        self.mime = mime
        self.text = text
        self.imageData = imageData
        self.savedAtMs = savedAtMs
        self.direction = direction
    }

    /// The composite key the store indexes by.
    public static func key(chatId: String, messageId: Int64) -> String {
        return "\(chatId)#\(messageId)"
    }

    public var key: String { return RelayLocalCopy.key(chatId: chatId, messageId: messageId) }
}
