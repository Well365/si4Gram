import Foundation

/// Whether, and what, to say above the first message of somebody you have never answered (PLAN.md 3.23).
///
/// Pure: every input is a fact the caller already holds, so the whole decision is testable without
/// a store or any Telegram dependency, and iOS and macOS share it. The one thing this deliberately
/// does not do is fetch anything — the common-groups lookup is a request that tells the server who
/// you are scrutinising, and PLAN.md 3.18 says no request leaves the device that the user did not
/// ask for. So the first state is a question.
///
/// **Being in the contacts list is not a reason to stay quiet** (PLAN.md 3.23.3). What this section
/// is actually there to catch is impersonation, and an account dressed up as someone you know is
/// precisely the one that is *not* in your contacts — so "are they in your contacts" is half of the
/// comparison the user is being invited to make, not a gate on making it. When they really are in
/// your contacts, saying so is the other half of that comparison, not a wasted line.
///
/// What keeps this from becoming wallpaper is `hasRepliedTo` — properly, "is this still a new
/// conversation for you", meaning this account has never sent anything in this chat — and it is the
/// only thing that does: in an everyday conversation with somebody you know you have written a
/// thousand times, so nothing appears; the facts are laid out only when an account you have never
/// spoken to turns up. Because it is now the only gate, how the caller works that flag out matters as
/// much as this file does — use `hasEverWritten`, which is where that question is answered.
public enum StrangerNotice {
    /// What the user answered when asked whether to check. `unasked` is the initial state.
    public enum Decision: String, Equatable {
        case unasked
        case declined
        case checked
    }

    public struct Input: Equatable {
        public let isPrivateChat: Bool
        /// Half of what the result says out loud (PLAN.md 3.23.4), never a reason to stay hidden.
        public let isContact: Bool
        public let isBot: Bool
        /// Whether you have ever written in this chat — i.e. NOT a new conversation. Once you have
        /// written, you have made your judgement. Work it out with `hasEverWritten`, never from a single
        /// signal: this is the only gate left.
        public let hasRepliedTo: Bool
        public let decision: Decision
        /// Known only after the check completed; nil while it is still loading.
        public let commonChats: Int?

        public init(isPrivateChat: Bool, isContact: Bool, isBot: Bool, hasRepliedTo: Bool, decision: Decision, commonChats: Int? = nil) {
            self.isPrivateChat = isPrivateChat
            self.isContact = isContact
            self.isBot = isBot
            self.hasRepliedTo = hasRepliedTo
            self.decision = decision
            self.commonChats = commonChats
        }
    }

    /// The four sentences of the PLAN.md 3.23.4 table. Four whole sentences rather than one with two
    /// holes in it: "0 common groups" has to read as "no common groups", and "is / is not in your
    /// contacts" are not one sentence with a word swapped — the two readings do not even carry the
    /// same tone. Each is translated whole.
    ///
    /// **Which of the four applies is decided here and nowhere else.** The clients receive the key,
    /// not the two booleans, because five clients reconstructing the same table five times is five
    /// chances to describe one situation five different ways.
    public enum ResultWording {
        public static let unknownNoGroups = "SecutgStrangerUnknownNoGroups"
        public static let unknownSomeGroups = "SecutgStrangerUnknownSomeGroups"
        public static let knownNoGroups = "SecutgStrangerKnownNoGroups"
        public static let knownSomeGroups = "SecutgStrangerKnownSomeGroups"

        /// `{count}` is substituted into the two `…SomeGroups` sentences; the `…NoGroups` pair carry
        /// no placeholder, which is the whole reason they are separate strings.
        public static func key(isContact: Bool, commonChats: Int) -> String {
            if isContact {
                return commonChats <= 0 ? knownNoGroups : knownSomeGroups
            } else {
                return commonChats <= 0 ? unknownNoGroups : unknownSomeGroups
            }
        }
    }

    public enum Notice: Equatable {
        case hidden
        /// Show the "shall I check for common groups?" question row.
        case ask
        /// The check was requested but the count has not arrived yet.
        case checking
        /// Both facts are known. `textKey` is one of `ResultWording`'s four, already chosen; the client
        /// looks it up and fills `{count}` from `commonChats`. Every one of the four states two facts
        /// and hands the judgement straight back, so **none of them may be drawn more loudly than the
        /// others** (PLAN.md 3.23.5): colouring one red would be putting back the conclusion the
        /// wording deliberately refuses to draw — and under this section's current terms the red one
        /// would include "in your contacts, no groups in common", which is not alarming at all.
        case result(textKey: String, commonChats: Int)
    }

    /// Whether this chat is **still a new conversation for you** — the question behind `hasRepliedTo`,
    /// and since 3.23.3 dropped the "hide for contacts" rule, the only reason this block ever goes
    /// away. Precisely: has this account ever sent anything in this chat. The answer returned here is
    /// "yes you have written", so the block hides when it is true.
    ///
    /// **Neither input answers that on its own, and neither may be used alone.**
    ///
    /// - `hasLoadedOutgoingMessage` — "one of the messages currently loaded is mine" — is really a fact
    ///   about scroll position. Page up into old history, jump to a quoted message, or cold-start into
    ///   a screenful of the other side talking, and a conversation you have answered a thousand times
    ///   momentarily looks like a stranger's opening line, with this block on top of it.
    /// - `maxOutgoingReadId` is Telegram's outgoing read watermark, and its meaning is **"how far the
    ///   peer has read your messages"**, not "did you send any". Above zero it does prove you sent
    ///   something — they read it — but it is still zero in the minutes after you reply and before they
    ///   open the chat. Swapping the scan for this one would put the block back up exactly then: just
    ///   after answering a stranger, which is the worst possible moment for it.
    ///
    /// So: **or**. The watermark covers "old conversation, nothing of mine in the loaded window"; the
    /// scan covers "just replied, not read yet", and it always can, because a message you just sent is
    /// necessarily in the loaded window — it is the newest thing in the chat.
    ///
    /// Residual false positive, stated plainly because it is real: you wrote long ago, the peer has
    /// **never** opened the chat since, and the loaded window no longer reaches that message. Then this
    /// says "new conversation" and the block comes back. Narrow, and it fails towards laying the facts
    /// out one extra time rather than withholding them from a real stranger — the safe side.
    ///
    /// A missing watermark (no read state yet, no conversation object) is **no evidence**, so that half
    /// is false and the other half decides. It must never be read as "has replied": that would hide the
    /// block from genuine strangers, which is the failure direction this section cannot afford.
    public static func hasEverWritten(hasLoadedOutgoingMessage: Bool, maxOutgoingReadId: Int32?) -> Bool {
        if hasLoadedOutgoingMessage { return true }
        if let maxOutgoingReadId = maxOutgoingReadId, maxOutgoingReadId > 0 { return true }
        return false
    }

    public static func evaluate(_ input: Input) -> Notice {
        // A group is not somebody writing to you; a bot is its own kind of stranger with its own UI.
        // Note what is NOT here: being a contact. See the type header — that is the thing being
        // reported, and gating on it would hide the notice from exactly the impersonation it exists
        // to expose.
        if !input.isPrivateChat || input.isBot { return .hidden }
        // Replying is the judgement this notice exists to inform. After it, the notice is noise.
        // This is the only gate left, so nothing may be added that weakens it (PLAN.md 3.23.5).
        if input.hasRepliedTo { return .hidden }
        if input.decision == .declined { return .hidden }
        if input.decision == .unasked { return .ask }
        // Checked, but the count has not arrived: never show a zero that merely means "not loaded
        // yet" — that reads as "no overlap at all", the most alarming answer, for every stranger,
        // every time (PLAN.md 3.23.4).
        guard let commonChats = input.commonChats else { return .checking }
        return .result(textKey: ResultWording.key(isContact: input.isContact, commonChats: commonChats),
                       commonChats: commonChats)
    }
}
