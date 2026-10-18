import TelegramCore
import TelegramPresentationData
import SecutgCore // SECUTG-HOOK
import MergeLists
import TemporaryCachedPeerDataManager
import AccountContext

public enum ChatMessageEntryContentType {
    case generic
    case largeEmoji
    case animatedEmoji
}

/// SECUTG-HOOK (PLAN.md 3.17 rule 5): what the oldest message of a folded run draws instead of its own
/// undecryptable line, and what that line stands for.
///
/// The anchor is the real message — same id, same date, same sender, same ciphertext underneath (rule 2) — so
/// date grouping, sender grouping and "jump to this message" all keep working on it. Only what is drawn changes,
/// and only while this is attached.
public struct SecutgCollapsedRun: Equatable {
    /// How many messages the line says are behind it, the anchor included. Folding is only acceptable because
    /// this is said: a timeline that silently left them out is exactly what an attacker who can break decryption
    /// would want.
    public let count: Int
    /// The newest message of the run. The collapsed row reports this as the index it stands for, the way an album
    /// row already reports its last member — without it, folding the newest messages of a chat would leave them
    /// unread forever, which is the one way this display switch could reach the unread count rule 5 keeps it away
    /// from.
    public let lastIndex: EngineMessage.Index

    public init(count: Int, lastIndex: EngineMessage.Index) {
        self.count = count
        self.lastIndex = lastIndex
    }
}

public struct ChatMessageEntryAttributes: Equatable {
    public var rank: CachedChannelAdminRank?
    public var isContact: Bool
    public var contentTypeHint: ChatMessageEntryContentType
    public var updatingMedia: ChatUpdatingMessageMedia?
    public var isPlaying: Bool
    public var isCentered: Bool
    public var authorStoryStats: EnginePeerStoryStats?
    public var displayContinueThreadFooter: Bool
    public var pinToTop: Bool
    /// SECUTG-HOOK (PLAN.md 3.17 rule 5): set only on the anchor of a folded run. Compared by `==` like every
    /// other field here, which is what makes the ordinary list merge redraw the row when the run's size changes
    /// or the reader opens it.
    public var secutgCollapsedRun: SecutgCollapsedRun?
    
    public init(rank: CachedChannelAdminRank?, isContact: Bool, contentTypeHint: ChatMessageEntryContentType, updatingMedia: ChatUpdatingMessageMedia?, isPlaying: Bool, isCentered: Bool, authorStoryStats: EnginePeerStoryStats?, displayContinueThreadFooter: Bool, pinToTop: Bool, secutgCollapsedRun: SecutgCollapsedRun? = nil) {
        self.rank = rank
        self.isContact = isContact
        self.contentTypeHint = contentTypeHint
        self.updatingMedia = updatingMedia
        self.isPlaying = isPlaying
        self.isCentered = isCentered
        self.authorStoryStats = authorStoryStats
        self.displayContinueThreadFooter = displayContinueThreadFooter
        self.pinToTop = pinToTop
        self.secutgCollapsedRun = secutgCollapsedRun
    }
    
    public init() {
        self.rank = nil
        self.isContact = false
        self.contentTypeHint = .generic
        self.updatingMedia = nil
        self.isPlaying = false
        self.isCentered = false
        self.authorStoryStats = nil
        self.displayContinueThreadFooter = false
        self.pinToTop = false
        self.secutgCollapsedRun = nil
    }
}

public enum ChatInfoData: Equatable {
    case botInfo(title: String, text: String, photo: TelegramMediaImage?, video: TelegramMediaFile?, peer: EnginePeer?, managedByBot: EnginePeer?)
    case userInfo(peer: EnginePeer, verification: PeerVerification?, registrationDate: String?, phoneCountry: String?, groupsInCommonCount: Int32)
    case newThreadInfo
}

/// SECUTG-HOOK (PLAN.md 3.23): what the stranger notice at the top of a private chat has to say.
///
/// The decision itself — and which of the four sentences of 3.23.4 applies — is
/// `SecutgCore.StrangerNotice.evaluate`, run where the entries are built; this only carries its answer
/// into the list. `Equatable` on the notice itself, so tapping [Check] or [No need] makes the ordinary
/// history merge emit an update (or a delete) instead of leaving the question on screen.
public struct SecutgStrangerNoticeData: Equatable {
    public let peerId: EnginePeer.Id
    public let notice: StrangerNotice.Notice
    /// SECUTG-HOOK (PLAN.md 3.23.7): where the row sits when the chat was re-armed after the peer left the contacts
    /// list — just before the peer's first message after the boundary. nil = the top of the history, 3.23.3's
    /// ordinary place. Part of `==` like everything else here, so the merge moves the row when the anchor moves.
    public let anchor: EngineMessage.Index?

    public init(peerId: EnginePeer.Id, notice: StrangerNotice.Notice, anchor: EngineMessage.Index? = nil) {
        self.peerId = peerId
        self.notice = notice
        self.anchor = anchor
    }
}

/// SECUTG-HOOK (PLAN.md 3.24): what the encryption guide at the top of a private chat has to draw.
///
/// The decision itself is `SecutgCore.OnboardCard.evaluate`, run where the entries are built; this only
/// carries its answer into the list. It is `Equatable` on every field that changes the drawing, which is
/// what makes the normal history merge produce an update item when the pairing moves or the user taps a
/// button, instead of leaving a stale card on screen.
public struct SecutgOnboardCardData: Equatable {
    public let peerId: EnginePeer.Id
    public let peerName: String
    public let form: OnboardCard.Form
    public let isCompact: Bool
    /// The user tapped "start an encrypted chat" and the two roads are showing (PLAN.md 3.24.4)
    public let isOpened: Bool

    public init(peerId: EnginePeer.Id, peerName: String, form: OnboardCard.Form, isCompact: Bool, isOpened: Bool) {
        self.peerId = peerId
        self.peerName = peerName
        self.form = form
        self.isCompact = isCompact
        self.isOpened = isOpened
    }
}

public enum ChatHistoryEntry: Identifiable, Comparable {
    case MessageEntry(EngineRawMessage, ChatPresentationData, Bool, EngineMessageHistoryEntryLocation?, ChatHistoryMessageSelection, ChatMessageEntryAttributes)
    case MessageGroupEntry(Int64, [(EngineRawMessage, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, EngineMessageHistoryEntryLocation?)], ChatPresentationData)
    case UnreadEntry(EngineMessage.Index, ChatPresentationData)
    case ReplyCountEntry(EngineMessage.Index, Bool, Int, ChatPresentationData)
    case ChatInfoEntry(ChatInfoData, ChatPresentationData)
    /// SECUTG-HOOK (PLAN.md 3.23): the stranger notice, one row below the chat-info block and above both
    /// the encryption guide and the first message. A row of its own rather than another `ChatInfoData`,
    /// because `ChatInfoEntry` is a mutually exclusive chain — one of bot info / user info / new thread —
    /// and this has to coexist with it (3.23.3, last line).
    case SecutgStrangerEntry(SecutgStrangerNoticeData, ChatPresentationData)
    /// SECUTG-HOOK (PLAN.md 3.24): the encryption guide, one row below the chat-info block and above the
    /// first message. A row of its own rather than another `ChatInfoData`, because `ChatInfoEntry` is a
    /// mutually exclusive chain — one of bot info / user info / new thread — and this has to coexist with it.
    case SecutgOnboardEntry(SecutgOnboardCardData, ChatPresentationData)
    
    public var stableId: UInt64 {
        switch self {
        case let .MessageEntry(message, _, _, _, _, attributes):
            let type: UInt64
            switch attributes.contentTypeHint {
            case .generic:
                type = 2
            case .largeEmoji:
                type = 3
            case .animatedEmoji:
                type = 4
            }
            return UInt64(message.stableId) | ((type << 40))
        case let .MessageGroupEntry(groupInfo, _, _):
            return UInt64(bitPattern: groupInfo) | ((UInt64(2) << 40))
        case .UnreadEntry:
            return UInt64(4) << 40
        case .ReplyCountEntry:
            return UInt64(5) << 40
        case let .ChatInfoEntry(infoData, _):
            switch infoData {
            case .newThreadInfo:
                return UInt64(7) << 40
            default:
                return UInt64(6) << 40
            }   
        // SECUTG-HOOK: these three tags are what put the two secutg rows below the chat-info block and in
        // a fixed order relative to each other. All of them sit at `absoluteLowerBound()`, so `<` falls
        // through to the tag (PLAN.md 3.24.3 rule 1).
        //
        // Stranger before guide, always, whatever state either is in (PLAN.md 3.23.2 / 3.24.2): "who is
        // this person" is the question that has to be answered before "do you want to encrypt with them"
        // is even a sensible one to ask. The order is fixed here rather than decided per state, so it
        // cannot quietly invert when one of the two changes shape.
        case .SecutgStrangerEntry:
            return UInt64(8) << 40
        case .SecutgOnboardEntry:
            return UInt64(9) << 40
        }
    }
    
    public var index: EngineMessage.Index {
        switch self {
        case let .MessageEntry(message, _, _, _, _, _):
            return message.index
        case let .MessageGroupEntry(_, messages, _):
            return messages[messages.count - 1].0.index
        case let .UnreadEntry(index, _):
            return index
        case let .ReplyCountEntry(index, _, _, _):
            return index
        case let .ChatInfoEntry(infoData, _):
            switch infoData {
            case .newThreadInfo:
                return EngineMessage.Index.absoluteUpperBound()
            default:
                return EngineMessage.Index.absoluteLowerBound()
            }
        case let .SecutgStrangerEntry(data, _): // SECUTG-HOOK: above every message, below the chat-info block — or, re-armed (PLAN.md 3.23.7), just before the peer's first message after the boundary
            return data.anchor ?? EngineMessage.Index.absoluteLowerBound()
        case .SecutgOnboardEntry: // SECUTG-HOOK: above every message, below the chat-info block
            return EngineMessage.Index.absoluteLowerBound()
        }
    }
    
    public var firstIndex: EngineMessage.Index {
        switch self {
            case let .MessageEntry(message, _, _, _, _, _):
                return message.index
            case let .MessageGroupEntry(_, messages, _):
                return messages[0].0.index
            case let .UnreadEntry(index, _):
                return index
            case let .ReplyCountEntry(index, _, _, _):
                return index
            case let .ChatInfoEntry(infoData, _):
                switch infoData {
                case .newThreadInfo:
                    return EngineMessage.Index.absoluteUpperBound()
                default:
                    return EngineMessage.Index.absoluteLowerBound()
                }
            case let .SecutgStrangerEntry(data, _): // SECUTG-HOOK (PLAN.md 3.23.7: `anchor` when re-armed)
                return data.anchor ?? EngineMessage.Index.absoluteLowerBound()
            case .SecutgOnboardEntry: // SECUTG-HOOK
                return EngineMessage.Index.absoluteLowerBound()
        }
    }
    
    public var timestamp: Int32? {
        switch self {
        case let .MessageEntry(message, _, _, _, _, _):
            return message.timestamp
        case let .MessageGroupEntry(_, messages, _):
            return messages[0].0.timestamp
        default:
            return nil
        }
    }

    public static func ==(lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        switch lhs {
            case let .MessageEntry(lhsMessage, lhsPresentationData, lhsRead, _, lhsSelection, lhsAttributes):
                switch rhs {
                    case let .MessageEntry(rhsMessage, rhsPresentationData, rhsRead, _, rhsSelection, rhsAttributes) where lhsMessage.index == rhsMessage.index && lhsMessage.flags == rhsMessage.flags && lhsRead == rhsRead:
                        if lhsPresentationData !== rhsPresentationData {
                            return false
                        }
                        if lhsMessage.stableVersion != rhsMessage.stableVersion {
                            return false
                        }
                        
                        if lhsMessage.peers.count != rhsMessage.peers.count {
                            return false
                        }
                        for (id, peer) in lhsMessage.peers {
                            if let otherPeer = rhsMessage.peers[id] {
                                if !peer.isEqual(otherPeer) {
                                    return false
                                }
                            }
                        }
                        
                        if lhsMessage.media.count != rhsMessage.media.count {
                            return false
                        }
                        for i in 0 ..< lhsMessage.media.count {
                            if !lhsMessage.media[i].isEqual(to: rhsMessage.media[i]) {
                                return false
                            }
                        }
                        if lhsMessage.associatedMessages.count != rhsMessage.associatedMessages.count {
                            return false
                        }
                        if !lhsMessage.associatedMessages.isEmpty {
                            for (id, message) in lhsMessage.associatedMessages {
                                if let otherMessage = rhsMessage.associatedMessages[id] {
                                    if otherMessage.stableVersion != message.stableVersion {
                                        return false
                                    }
                                }
                            }
                        }
                        if lhsMessage.associatedStories.count != rhsMessage.associatedStories.count {
                            return false
                        }
                        if !lhsMessage.associatedStories.isEmpty {
                            for (id, story) in lhsMessage.associatedStories {
                                if let otherStory = rhsMessage.associatedStories[id] {
                                    if story != otherStory {
                                        return false
                                    }
                                } else {
                                    return false
                                }
                            }
                        }
                        if lhsSelection != rhsSelection {
                            return false
                        }
                        if lhsAttributes != rhsAttributes {
                            return false
                        }
                        return true
                    default:
                        return false
                }
            case let .MessageGroupEntry(lhsGroupInfo, lhsMessages, lhsPresentationData):
                if case let .MessageGroupEntry(rhsGroupInfo, rhsMessages, rhsPresentationData) = rhs, lhsGroupInfo == rhsGroupInfo, lhsPresentationData === rhsPresentationData, lhsMessages.count == rhsMessages.count {
                    for i in 0 ..< lhsMessages.count {
                        let (lhsMessage, lhsRead, lhsSelection, lhsAttributes, lhsLocation) = lhsMessages[i]
                        let (rhsMessage, rhsRead, rhsSelection, rhsAttributes, rhsLocation) = rhsMessages[i]
                        
                        if lhsMessage.id != rhsMessage.id {
                            return false
                        }
                        if lhsMessage.timestamp != rhsMessage.timestamp {
                            return false
                        }
                        if lhsMessage.flags != rhsMessage.flags {
                            return false
                        }
                        if lhsRead != rhsRead {
                            return false
                        }
                        if lhsSelection != rhsSelection {
                            return false
                        }
                        if lhsPresentationData !== rhsPresentationData {
                            return false
                        }
                        if lhsMessage.stableVersion != rhsMessage.stableVersion {
                            return false
                        }
                        if lhsMessage.media.count != rhsMessage.media.count {
                            return false
                        }
                        for i in 0 ..< lhsMessage.media.count {
                            if !lhsMessage.media[i].isEqual(to: rhsMessage.media[i]) {
                                return false
                            }
                        }
                        if lhsMessage.associatedMessages.count != rhsMessage.associatedMessages.count {
                            return false
                        }
                        if !lhsMessage.associatedMessages.isEmpty {
                            for (id, message) in lhsMessage.associatedMessages {
                                if let otherMessage = rhsMessage.associatedMessages[id] {
                                    if otherMessage.stableVersion != message.stableVersion {
                                        return false
                                    }
                                }
                            }
                        }
                        if lhsMessage.associatedStories.count != rhsMessage.associatedStories.count {
                            return false
                        }
                        if !lhsMessage.associatedStories.isEmpty {
                            for (id, story) in lhsMessage.associatedStories {
                                if let otherStory = rhsMessage.associatedStories[id] {
                                    if story != otherStory {
                                        return false
                                    }
                                } else {
                                    return false
                                }
                            }
                        }
                        if lhsAttributes != rhsAttributes {
                            return false
                        }
                        if lhsLocation != rhsLocation {
                            return false
                        }
                    }
                    
                    return true
                } else {
                    return false
                }
            case let .UnreadEntry(lhsIndex, lhsPresentationData):
                if case let .UnreadEntry(rhsIndex, rhsPresentationData) = rhs, lhsIndex == rhsIndex, lhsPresentationData === rhsPresentationData {
                    return true
                } else {
                    return false
                }
            case let .ReplyCountEntry(lhsIndex, lhsIsComments, lhsCount, lhsPresentationData):
                if case let .ReplyCountEntry(rhsIndex, rhsIsComments, rhsCount, rhsPresentationData) = rhs, lhsIndex == rhsIndex, lhsIsComments == rhsIsComments, lhsCount == rhsCount, lhsPresentationData === rhsPresentationData {
                    return true
                } else {
                    return false
                }
            case let .ChatInfoEntry(lhsData, lhsPresentationData):
                if case let .ChatInfoEntry(rhsData, rhsPresentationData) = rhs, lhsData == rhsData, lhsPresentationData === rhsPresentationData {
                    return true
                } else {
                    return false
                }
            // SECUTG-HOOK: comparing the drawn state, not just the chat, is what makes the merge emit an
            // update item when the block moves from its question to its answer — otherwise a row that
            // should now read "checking" would keep asking until some message happened to arrive.
            case let .SecutgStrangerEntry(lhsData, lhsPresentationData):
                if case let .SecutgStrangerEntry(rhsData, rhsPresentationData) = rhs, lhsData == rhsData, lhsPresentationData === rhsPresentationData {
                    return true
                } else {
                    return false
                }
            // SECUTG-HOOK: comparing the drawn state, not just the chat, is what makes the merge emit an
            // update item when the card's shape changes — otherwise a card that should now read "waiting"
            // would keep saying "not encrypted yet" until some message happened to arrive.
            case let .SecutgOnboardEntry(lhsData, lhsPresentationData):
                if case let .SecutgOnboardEntry(rhsData, rhsPresentationData) = rhs, lhsData == rhsData, lhsPresentationData === rhsPresentationData {
                    return true
                } else {
                    return false
                }
        }
    }
    
    public static func <(lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        let lhsIndex = lhs.index
        let rhsIndex = rhs.index
        if lhsIndex == rhsIndex {
            return lhs.stableId < rhs.stableId
        } else {
            return lhsIndex < rhsIndex
        }
    }
}
