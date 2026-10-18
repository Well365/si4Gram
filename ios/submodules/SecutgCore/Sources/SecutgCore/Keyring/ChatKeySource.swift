import Foundation

/// How trustworthy the private chat was when a group key went through it (PLAN.md 3.13): `manual` = offline key,
/// `verified` / `unverified` = auto-paired with / without the safety code compared.
public enum OnlineInviteLevel: String, Equatable {
    case manual, verified, unverified
}

/// Where this device's copy of a chat key came from (PLAN.md 3.13): the offline QR code / own creation, or an
/// encrypted `G1` invite received in the private chat with `via` (the admin's user id).
public enum ChatKeySource: Equatable {
    case offline
    case online(via: String, viaLevel: OnlineInviteLevel)

    public var isValid: Bool {
        if case let .online(via, _) = self { return !via.isEmpty }
        return true
    }
}
