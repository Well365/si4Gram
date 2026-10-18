import Foundation

/// Whether, and in which shape, to show the encryption onboarding card at the top of a private
/// chat's message flow (PLAN.md 3.24).
///
/// This is **a second renderer of the PLAN.md 3.7 pairing state, not a second implementation of it**
/// (3.24.7 rule 3). Nothing here sends anything, nothing here decides anything about pairing: the
/// 120-second race, `key_changed` and `other_device` are all settled by 3.7, and this file only
/// turns the result into a shape the card can draw. Keeping it pure is what lets all six shapes be
/// tested without a store, a network or any Telegram dependency — which is also why iOS and macOS
/// share this file byte for byte, and why the other three clients can port the table below line by
/// line.
///
/// The six shapes of 3.24.1 / 3.24.5 are the five `Form` values plus `isCompact: true`, which is the
/// sixth (`compact`). Compact is deliberately *not* a form of its own: it is a collapsed rendering
/// of whichever form is underneath, so one tap on it opens that form rather than some separate
/// reduced card. That is what keeps "every shape has a way out" (3.24.5 rule 4) true for the
/// collapsed state too, without designing a button set for `compact` at all.
public enum OnboardCard {
    /// How long an invitation with no answer keeps saying "waiting" before it says "they have not
    /// accepted" (PLAN.md 3.24.5 rule 2). Seven days, identical on all five clients.
    ///
    /// Purely local wall-clock bookkeeping about *wording*. The `invited` protocol state itself never
    /// expires — a `P1` arriving on day 30 still completes the pairing (3.7 rule 3) — so nothing in
    /// this file or its callers may clear `pairing` when this elapses.
    ///
    /// Why not minutes: the peer may not open this chat for days. Declaring failure after a few
    /// minutes would report a pairing that was still going to succeed as failed, over and over.
    public static let pairingInviteStaleDays: Int64 = 7

    private static let secondsPerDay: Int64 = 86_400

    /// The five substantive shapes; `compact` is these collapsed, see the type header.
    public enum Form: String, Equatable {
        case offer
        case incoming
        case waiting
        case stale
        case moved
    }

    public struct Input: Equatable {
        /// A user chat (`Namespaces.Peer.CloudUser`) that is not this account's own Saved Messages
        public let isPrivateChat: Bool
        public let isBot: Bool
        /// Telegram's own service account, 777000
        public let isServiceAccount: Bool
        /// This chat already has a master key: manual pairing, an import, or a carried-over keyring
        public let hasKey: Bool
        /// The chat's pairing record; nil means no pairing was ever started here
        public let pairingState: KeyRing.Pairing.State?
        /// The peer registered a public key in this chat — they invited us first (PLAN.md 3.7 step 2)
        public let hasPeerKey: Bool
        /// Unix SECONDS: when this device sent its own `P1` (`KeyRing.Pairing.startedAt`). Absent
        /// means we cannot time the invitation.
        public let startedAt: Int64?
        /// Unix SECONDS
        public let nowSeconds: Int64
        public let memory: OnboardMemory
        /// PLAN.md 3.24.3 rule 2: the 3.23 stranger block is on screen, in any of its states. Callers
        /// must get this by asking `StrangerNotice.evaluate` rather than re-deriving the conditions,
        /// so the two blocks can never disagree about whether 3.23 is showing.
        public let isStrangerNoticeVisible: Bool
        /// PLAN.md 3.25.5.3: the richer "paired on your other device" block occupies this same slot in
        /// the message flow. **Only clients whose take-over notice is an inline block in the stream
        /// ever set this.** On iOS and macOS the take-over notice is a dialog
        /// (`SecutgHandoffDialogs`) which does not occupy the message flow at all, so there is nothing
        /// for `moved` to collide with and this stays false — see the `other_device` branch below.
        public let isHandoffNoticeVisible: Bool

        public init(isPrivateChat: Bool, isBot: Bool, isServiceAccount: Bool, hasKey: Bool,
                    pairingState: KeyRing.Pairing.State? = nil, hasPeerKey: Bool, startedAt: Int64? = nil,
                    nowSeconds: Int64, memory: OnboardMemory, isStrangerNoticeVisible: Bool,
                    isHandoffNoticeVisible: Bool = false) {
            self.isPrivateChat = isPrivateChat
            self.isBot = isBot
            self.isServiceAccount = isServiceAccount
            self.hasKey = hasKey
            self.pairingState = pairingState
            self.hasPeerKey = hasPeerKey
            self.startedAt = startedAt
            self.nowSeconds = nowSeconds
            self.memory = memory
            self.isStrangerNoticeVisible = isStrangerNoticeVisible
            self.isHandoffNoticeVisible = isHandoffNoticeVisible
        }
    }

    public enum Shape: Equatable {
        case hidden
        case card(form: Form, isCompact: Bool)
    }

    public static func evaluate(_ input: Input) -> Shape {
        // Groups get their key from an admin (PLAN.md 3.13), so there are no two roads to choose
        // between and no card; bots, 777000 and Saved Messages have no second person to pair with.
        if !input.isPrivateChat || input.isBot || input.isServiceAccount { return .hidden }
        // Asked twice, or told never: the entry lives on in the lock menu and nowhere else (3.24.8)
        if input.memory == .never { return .hidden }

        // Already encrypted, by either road — the card only exists for the window before that.
        if input.pairingState == .paired { return .hidden }
        // A changed key is a warning, and a warning must not be buried under an invitation to
        // encrypt (3.24.1): this one shape stays hidden even though the chat is, at this moment, not
        // encrypting. Judged BEFORE `hasKey` so it is a rule of its own rather than a side effect of
        // whether a key happens to still be around.
        if input.pairingState == .keyChanged { return .hidden }
        if input.hasKey { return .hidden }

        let isCompact = input.memory.ignoredCount >= 1 || input.isStrangerNoticeVisible
        func card(_ form: Form) -> Shape { return .card(form: form, isCompact: isCompact) }

        if input.pairingState == .otherDevice {
            // PLAN.md 3.25.5.3 ships a block for exactly this state that also names the winning
            // device and offers the same re-pair action. On a client where that notice is an inline
            // block in the message flow, two stacked blocks would say one thing twice, so it wins
            // while it is up and this card takes over once it is dismissed — the way out survives
            // either way (3.24.5 rule 4). On iOS and macOS that notice is a dialog and never takes
            // this slot, so `isHandoffNoticeVisible` is left false there and `moved` simply renders.
            return input.isHandoffNoticeVisible ? .hidden : card(.moved)
        }

        if input.pairingState == .invited {
            // Without a start time we cannot honestly say how long it has been, and "they have not
            // accepted" is a claim; `waiting` is not. When in doubt, make the weaker claim.
            let isStale: Bool
            if let startedAt = input.startedAt {
                isStale = input.nowSeconds - startedAt >= pairingInviteStaleDays * secondsPerDay
            } else {
                isStale = false
            }
            return card(isStale ? .stale : .waiting)
        }

        // They went first. Note what is deliberately *not* consulted here: whether the peer has
        // secuTG installed. There is no way to find that out that does not either ask the server or
        // put something in the chat first (3.24.1 rule 3), so every eligible private chat is treated
        // alike.
        if input.hasPeerKey { return card(.incoming) }

        return card(.offer)
    }
}
