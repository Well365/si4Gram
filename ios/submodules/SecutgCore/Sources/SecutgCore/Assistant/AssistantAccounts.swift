import Foundation

/// PLAN.md 3.45.2 amendment 2026-10-02: a Mac with several Telegram accounts.
///
/// The interface is switched on per account (the signed line in `enabled`, `SecutgAssistantSwitch`) and capture
/// follows the client's ACTIVE account only. Before this amendment the socket existed only while the active
/// account's switch was on, so a user whose active account was not switched on saw the assistant simply offline,
/// with no hint which account was meant. Now:
/// - `serving`: the active account's switch is on → socket, capture, every op (as before).
/// - `statusOnly`: the active account's switch is off but another account logged in on this Mac has it on (the
///   user did opt in on this Mac) → the socket answers `hello` and `status` only, so the assistant can say which
///   account is active and that it is not switched on; nothing is captured, nothing is queued, and `directory`,
///   `subscribe`, `ack`, `context`, `send`, `read`, `open`, `history`, `folders`, `folder_update` and `media` answer
///   `not_ready`. No message text leaves the client.
/// - `off`: no logged-in account has the switch on (or nobody is signed in) → no socket, as before.
public enum AssistantInterfaceMode: String, Equatable {
    case off
    case statusOnly = "status_only"
    case serving

    public static func decide(hasActiveAccount: Bool, activeAccountEnabled: Bool, anyLoggedInAccountEnabled: Bool) -> AssistantInterfaceMode {
        guard hasActiveAccount else { return .off }
        if activeAccountEnabled { return .serving }
        return anyLoggedInAccountEnabled ? .statusOnly : .off
    }

    /// Whether an op is answered in this mode (everything else answers `not_ready`).
    public func allows(_ op: AssistantOp) -> Bool {
        switch self {
        case .serving: return true
        case .statusOnly: return op == .hello || op == .status
        case .off: return false
        }
    }

    /// The `not_ready` an op gets when this mode does not answer it.
    public static let notServingFailure = AssistantFailure(.notReady, "assistant interface is off for the client's current account")
}

extension AssistantCommand {
    public var op: AssistantOp {
        switch self {
        case .hello: return .hello
        case .status: return .status
        case .directory: return .directory
        case .subscribe: return .subscribe
        case .ack: return .ack
        case .context: return .context
        case .send: return .send
        case .read: return .read
        case .open: return .open
        case .history: return .history
        case .folders: return .folders
        case .folderUpdate: return .folderUpdate
        case .media: return .media
        }
    }
}

/// One row of `status.accounts`: an account logged in on this Mac. `active` = the client's current account (the
/// one whose mentions are captured while its switch is on); `capture_enabled` = that account's own switch
/// (「设置 → secuTG → 助手接口」), whether or not it is the active one.
public struct AssistantAccountEntry: Equatable {
    public let person: AssistantPerson
    public let active: Bool
    public let captureEnabled: Bool

    public init(person: AssistantPerson, active: Bool, captureEnabled: Bool) {
        self.person = person
        self.active = active
        self.captureEnabled = captureEnabled
    }

    public var json: AssistantJSON {
        guard case var .object(fields) = person.json else { return person.json }
        fields["active"] = .bool(active)
        fields["capture_enabled"] = .bool(captureEnabled)
        return .object(fields)
    }

    /// The list as the status reports it: one row per peer id (the first wins), at most one `active` row — the one
    /// whose peer id is `activePeerId` — in the client's own account order.
    public static func list(_ accounts: [(person: AssistantPerson, captureEnabled: Bool)], activePeerId: Int64?) -> [AssistantAccountEntry] {
        var seen = Set<Int64>()
        var rows: [AssistantAccountEntry] = []
        for account in accounts where seen.insert(account.person.peerId).inserted {
            rows.append(AssistantAccountEntry(person: account.person, active: account.person.peerId == activePeerId,
                                              captureEnabled: account.captureEnabled))
        }
        return rows
    }
}
