import Foundation

/// How long a relay item should be kept, in the sender's own terms (PLAN.md 3.48.4): a read-count ceiling and a
/// time ceiling, whichever is reached first ends it — the relay service enforces both independently.
public struct RelayKeepPolicy: Equatable, Codable {
    /// 0 = unlimited.
    public var maxReads: Int
    public var ttlSeconds: Int

    public init(maxReads: Int, ttlSeconds: Int) {
        self.maxReads = maxReads
        self.ttlSeconds = ttlSeconds
    }

    public static let readsPresets = [1, 3, 10, 0]
    public static let ttlPresets = [3600, 86_400, 7 * 86_400, 30 * 86_400]

    /// Defaults: read once, keep for a day (PLAN.md 3.48.4).
    public static let `default` = RelayKeepPolicy(maxReads: 1, ttlSeconds: 86_400)
}

/// When a message should go through the relay without the user picking it explicitly each time (PLAN.md 3.48.4,
/// "什么时候走中转"). `manualOnly` is the default and, when true, the two auto flags are advisory only — the
/// compose path never auto-routes unless the user has explicitly turned at least one of them on.
public struct RelaySendTrigger: Equatable, Codable {
    public var manualOnly: Bool
    public var autoLongText: Bool
    public var autoImageAlways: Bool

    public init(manualOnly: Bool, autoLongText: Bool, autoImageAlways: Bool) {
        self.manualOnly = manualOnly
        self.autoLongText = autoLongText
        self.autoImageAlways = autoImageAlways
    }

    public static let `default` = RelaySendTrigger(manualOnly: true, autoLongText: false, autoImageAlways: false)

    /// PLAN.md 3.48.4: "超过 4096 字的文本自动走".
    public static let longTextThreshold = 4096
}

/// Global relay settings (PLAN.md 3.48.4), app-level (3.48.5) — shared by every account on this device.
/// `enabled == false` is the whole independence rule's anchor: every other field here is inert until it is true.
public struct RelaySettings: Equatable, Codable {
    public var enabled: Bool
    public var trigger: RelaySendTrigger
    public var defaultKeepPolicy: RelayKeepPolicy
    public var encryptContent: Bool
    public var stripExif: Bool
    /// Receiving: show relay cards at all. Independent of `enabled` — a card from a correspondent who has the
    /// feature on should still render for a reader who never turned on *sending*; see `RelayRender`.
    public var showCards: Bool
    public var askUnknownRelay: Bool
    public var allowInsecureOrLAN: Bool

    public init(enabled: Bool, trigger: RelaySendTrigger, defaultKeepPolicy: RelayKeepPolicy, encryptContent: Bool, stripExif: Bool, showCards: Bool, askUnknownRelay: Bool, allowInsecureOrLAN: Bool) {
        self.enabled = enabled
        self.trigger = trigger
        self.defaultKeepPolicy = defaultKeepPolicy
        self.encryptContent = encryptContent
        self.stripExif = stripExif
        self.showCards = showCards
        self.askUnknownRelay = askUnknownRelay
        self.allowInsecureOrLAN = allowInsecureOrLAN
    }

    /// Off; everything else defaulted the way PLAN.md 3.48.4 lists it.
    public static let `default` = RelaySettings(
        enabled: false,
        trigger: .default,
        defaultKeepPolicy: .default,
        encryptContent: true,
        stripExif: true,
        showCards: true,
        askUnknownRelay: true,
        allowInsecureOrLAN: false)
}

/// Per-chat override (PLAN.md 3.48.4, lock menu → 中转).
public enum RelayChatMode: String, Equatable, Codable {
    case followGlobal
    case alwaysOn
    case alwaysOff
}

public struct RelayChatPolicy: Equatable, Codable {
    public var mode: RelayChatMode
    public var keepPolicy: RelayKeepPolicy?
    public var relayId: String?

    public init(mode: RelayChatMode, keepPolicy: RelayKeepPolicy?, relayId: String?) {
        self.mode = mode
        self.keepPolicy = keepPolicy
        self.relayId = relayId
    }

    public static let `default` = RelayChatPolicy(mode: .followGlobal, keepPolicy: nil, relayId: nil)
}

/// Pure decisions the compose path needs; no I/O, so the independence tests can drive them directly.
public enum RelayPolicy {
    /// Whether this chat may use the relay at all right now.
    public static func isEnabled(global: RelaySettings, chat: RelayChatPolicy) -> Bool {
        switch chat.mode {
        case .alwaysOn: return true
        case .alwaysOff: return false
        case .followGlobal: return global.enabled
        }
    }

    /// Whether a message of this shape should be auto-routed through the relay, given the trigger is active.
    /// Manual selection always works regardless of this function's answer; this only covers the "auto" cases.
    public static func shouldAutoRelay(trigger: RelaySendTrigger, textLength: Int, isImage: Bool) -> Bool {
        if trigger.manualOnly { return false }
        if isImage && trigger.autoImageAlways { return true }
        if !isImage && trigger.autoLongText && textLength > RelaySendTrigger.longTextThreshold { return true }
        return false
    }

    /// The keep policy a new send should use: the chat's own policy, else the global default.
    public static func effectiveKeepPolicy(global: RelaySettings, chat: RelayChatPolicy) -> RelayKeepPolicy {
        return chat.keepPolicy ?? global.defaultKeepPolicy
    }
}
