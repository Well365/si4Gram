import Foundation

/// The four connection states every Telegram client already distinguishes. On iOS and macOS they are
/// `TelegramCore.AccountNetworkState`, which is `Network.connectionStatus` with `AccountStateManager.isUpdating`
/// (the getDifference that follows every connect) folded into `.updating`, the same three-state
/// "connecting / updating / online" line the chat list title shows. PLAN.md 3.37 rule 3: use the client's own
/// "online" state and nothing home-made.
public enum NetGateConnection: Equatable {
    case waitingForNetwork
    case connecting
    case updating
    case online
}

/// What the overlay says while it covers the app (PLAN.md 3.37 rule 2).
public enum NetGatePhase: Equatable {
    /// `SecutgNetGateConnecting`
    case connecting
    /// `SecutgNetGateSyncing`
    case syncing
}

/// PLAN.md 3.37, the online gate: nothing of a logged-in account is shown until it is online **and** has
/// finished syncing, so a remote wipe that is waiting on the server (3.22) always runs before anything is
/// on screen. Its only job is against "switch on airplane mode first, then read the local cache". It is not
/// encryption and does not protect against copying the database off a jailbroken device.
///
/// Pure value: the clients feed it the current connection state and a monotonic clock, and read back
/// whether to cover, which phase text to show, and when to ask again. Every update returns a new value.
///
/// Rules:
/// - logged in, never online since the last cover: covered (rule 3);
/// - `.online`, and only `.online`, lifts it (`.updating` is "connected but not synced yet");
/// - once lifted, it covers again only after the state has been **continuously** non-online for
///   `recoverAfterSeconds` (rule 4: 15 s, so a brief flap does not flash the screen), and then waits for
///   `.online` again;
/// - logged out never covers (the login flow has no content, rule 1).
public struct NetGatePolicy: Equatable {
    /// PLAN.md 3.37 rule 4 (用户选定).
    public static let recoverAfterSeconds: Double = 15.0

    public let isAuthorized: Bool
    public let connection: NetGateConnection
    /// Has been `.online` since the last time the gate went up.
    public let isLifted: Bool
    /// While lifted: when the current run of non-online states began. Nil while online.
    public let offlineSince: Double?

    /// A freshly logged-in (or freshly switched-to) account: covered until it has been online once.
    public init(isAuthorized: Bool = true) {
        self.init(isAuthorized: isAuthorized, connection: .connecting, isLifted: false, offlineSince: nil)
    }

    private init(isAuthorized: Bool, connection: NetGateConnection, isLifted: Bool, offlineSince: Double?) {
        self.isAuthorized = isAuthorized
        self.connection = connection
        self.isLifted = isLifted
        self.offlineSince = offlineSince
    }

    public var isCovered: Bool {
        return self.isAuthorized && !self.isLifted
    }

    /// Only meaningful while `isCovered`.
    public var phase: NetGatePhase {
        switch self.connection {
        case .waitingForNetwork, .connecting:
            return .connecting
        case .updating, .online:
            return .syncing
        }
    }

    /// While lifted and not online: the moment the gate will cover again unless `.online` comes back first.
    /// The client schedules a timer for it and calls `advanced(to:)` when it fires.
    public var recoverDeadline: Double? {
        guard self.isAuthorized, self.isLifted, let offlineSince = self.offlineSince else {
            return nil
        }
        return offlineSince + NetGatePolicy.recoverAfterSeconds
    }

    /// Logging out drops everything; logging (back) in starts covered.
    public func with(isAuthorized: Bool) -> NetGatePolicy {
        if isAuthorized == self.isAuthorized {
            return self
        }
        return NetGatePolicy(isAuthorized: isAuthorized)
    }

    /// A new connection state observed at `now` (seconds on a monotonic clock).
    public func with(connection: NetGateConnection, now: Double) -> NetGatePolicy {
        let next: NetGatePolicy
        if connection == .online {
            next = NetGatePolicy(isAuthorized: self.isAuthorized, connection: connection, isLifted: true, offlineSince: nil)
        } else if self.isLifted {
            next = NetGatePolicy(isAuthorized: self.isAuthorized, connection: connection, isLifted: true, offlineSince: self.offlineSince ?? now)
        } else {
            next = NetGatePolicy(isAuthorized: self.isAuthorized, connection: connection, isLifted: false, offlineSince: nil)
        }
        return next.advanced(to: now)
    }

    /// Re-evaluates the 15-second rule at `now` without a new connection state (timer, app back in front).
    public func advanced(to now: Double) -> NetGatePolicy {
        guard self.isLifted, let offlineSince = self.offlineSince else {
            return self
        }
        // A clock that went backwards cannot prove the outage was short: fail towards covering.
        let elapsed = now - offlineSince
        if elapsed >= NetGatePolicy.recoverAfterSeconds || elapsed < 0.0 {
            return NetGatePolicy(isAuthorized: self.isAuthorized, connection: self.connection, isLifted: false, offlineSince: nil)
        }
        return self
    }
}
