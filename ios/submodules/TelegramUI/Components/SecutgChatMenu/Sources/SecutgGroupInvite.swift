import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import LocalizedPeerData
import SecutgCore

/// SECUTG: the encrypted group invite of PLAN.md 3.13 (Web A `inviteOnline` / `inviteOnlineConfirm` modals and
/// `SecutgGroupInviteLine`). Admin side: pick a member, the group key goes as a `G1` text through the encrypted
/// private chat with them (the A1 hook encrypts it). Member side: the card in the private chat imports the key,
/// registers our public key in the group and turns encryption on.
public enum SecutgGroupInvite {
    private static let maxPickerRows = 12

    // MARK: admin: online invite picker

    /// Lists the group's members with the level of the private chat each one has with us; a tap sends the invite.
    public static func presentPicker(context: AccountContext, groupPeerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let _ = (combineLatest(participants(context: context, groupPeerId: groupPeerId), context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: groupPeerId)))
        |> deliverOnMainQueue).startStandalone(next: { [weak controller] members, group in
            guard let controller else { return }
            let presentation = context.sharedContext.currentPresentationData.with { $0 }
            let groupTitle = group?.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) ?? ""
            guard let members else {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgMembersNotLoaded"))
                return
            }
            let candidates = members.filter { $0.id != context.account.peerId }
            guard !candidates.isEmpty else {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgNoMembers"))
                return
            }
            let sheet = UIAlertController(title: SecutgL10n.string("SecutgInviteOnlineTitle"), message: SecutgL10n.string("SecutgInviteOnlineHint"), preferredStyle: .alert)
            for member in candidates.prefix(maxPickerRows) {
                let name = member.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder)
                let level = runtime.privateChatLevel(userPeerId: member.id)
                sheet.addAction(UIAlertAction(title: "\(name) — \(levelLabel(level))", style: .default, handler: { [weak controller] _ in
                    guard let controller else { return }
                    send(context: context, groupPeerId: groupPeerId, groupTitle: groupTitle, member: member.id, name: name, level: level, force: false, controller: controller)
                }))
            }
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(sheet, over: controller)
        })
    }

    // MARK: admin: a member's public key that arrived offline (PLAN.md 3.13 rule 5)

    /// 〔登记成员公钥…〕: the offline counterpart of "the member announces their key in the group". A member who
    /// took the group key off a QR code has no encrypted private chat with the admin to announce through, and
    /// until their public key sits on the admin's device a welcome / reset cannot address them at all
    /// (`RekeyError.unknownMember`) — so the admin reads their `P1:` text off the same offline channel the key
    /// went out on and enters it here. The offline channel is what vouches for the sender, exactly as it does
    /// for the key itself. Same action, same place in the list and same strings as Web's `registerPeer`
    /// (`src/secutg/ui/actions.ts`, the `members` list).
    ///
    /// Two dialogs where Web has one with a live preview, because a `UIAlertController` cannot re-render while
    /// it is up: step 1 takes the text, step 2 says whose key it turned out to be and only then writes anything.
    /// That is the shape the keyring import in `SecutgTransfer` already uses on this client, for the same reason,
    /// and the shape macOS landed on for this very action (`NSAlert` has the same limitation).
    public static func presentRegisterPeer(context: AccountContext, groupPeerId: PeerId, controller: ViewController) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        SecutgChatMenu.syncLanguage(context: context)
        let input = UIAlertController(title: SecutgL10n.string("SecutgRegisterPeer"), message: SecutgL10n.string("SecutgRegisterPeerHint"), preferredStyle: .alert)
        input.addTextField { field in
            field.placeholder = SecutgL10n.string("SecutgRegisterPeerLabel")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let pasted = UIPasteboard.general.string, pasted.hasPrefix("P1:") { field.text = pasted }
        }
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default, handler: { [weak input, weak controller] _ in
            guard let controller else { return }
            let payload = (input?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            inspectRegisterPeer(context: context, groupPeerId: groupPeerId, payload: payload, controller: controller)
        }))
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(input, over: controller)
    }

    /// Parsed and checked here as well as in the runtime, because the "is this person even in this chat" question
    /// needs a user id, and the only user id worth asking it about is the one the signature covers. The two
    /// reasons are the codes `RekeyProcessor` writes into a control message's own `detail`, so a P1 turned down
    /// here and a P1 turned down on arrival say the same word.
    private static func inspectRegisterPeer(context: AccountContext, groupPeerId: PeerId, payload: String, controller: ViewController) {
        guard let p1 = Rekey.parseP1(payload) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "malformed"]))
            return
        }
        guard Rekey.verifyP1(p1, senderId: p1.userId) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "bad_signature"]))
            return
        }
        // A P1 naming anything but a user id is malformed here whatever it would mean elsewhere: the round-trip
        // is what guarantees the peer handed to the runtime below is the very id the signature was made over.
        guard let userPeerId = SecutgAccountRuntime.peerId(chatKey: p1.userId),
              userPeerId.namespace == Namespaces.Peer.CloudUser,
              SecutgAccountRuntime.userId(userPeerId) == p1.userId else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "malformed"]))
            return
        }
        let _ = (combineLatest(
            participants(context: context, groupPeerId: groupPeerId),
            context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: userPeerId))
        ) |> deliverOnMainQueue).startStandalone(next: { [weak controller] members, peer in
            guard let controller else { return }
            confirmRegisterPeer(
                context: context, groupPeerId: groupPeerId, p1: p1, userPeerId: userPeerId,
                payload: payload, members: members, peer: peer, controller: controller)
        })
    }

    /// Step 2: whose key this is, and only then the write.
    ///
    /// `members` nil means the list never loaded, and then the check is *reported as not having run* rather than
    /// used to turn the admin away — the same call Web makes (`isPastedPeerMember` stays true while the members
    /// are unknown). A signed P1 in the admin's hand is evidence; a list that failed to load is not evidence
    /// against it. When the list did load, a stranger's key is refused, which is Web's behaviour too (it greys
    /// the button out). Note what that costs on a large supergroup: `participants` returns the *recent* members
    /// there, so a long-quiet member can be missing from it and has to be reached some other way — Web has the
    /// same ceiling, and widening it here alone would only make the two clients disagree about who is a member.
    private static func confirmRegisterPeer(
        context: AccountContext, groupPeerId: PeerId, p1: Rekey.ParsedP1, userPeerId: PeerId,
        payload: String, members: [EnginePeer]?, peer: EnginePeer?, controller: ViewController
    ) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        if let members = members, !members.contains(where: { $0.id == userPeerId }) {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterPeerNotMember", ["id": p1.userId]))
            return
        }
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        let title = { (peer: EnginePeer) in peer.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) }
        // The id is shown next to the name whatever happens: it is the half the signature covers, and the half
        // the admin can actually compare with what the member read out to them.
        let name = members?.first(where: { $0.id == userPeerId }).map(title) ?? peer.map(title) ?? p1.userId
        var body = SecutgL10n.string("SecutgRegisterPeerPreview", ["name": name, "id": p1.userId])
        if members == nil { body = SecutgL10n.string("SecutgMembersNotLoaded") + "\n\n" + body }
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgRegisterPeerTitle"), message: body, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            // The write goes in through `transformIncoming`, the runtime's own door for a `P1:` — the same one
            // the member's announcement would have come in by, told who the sender is instead of reading it off
            // a message. It checks the signature against that sender again and stores both halves of the key
            // (x25519 to seal a rekey to them, ed25519 to check what they sign), which is precisely what
            // registering means; a second way in would be a second copy of that rule. The alternative was a new
            // method on the shared `SecutgRuntime.swift` for a write the shared code already performs.
            _ = runtime.transformIncoming(
                text: payload, entities: [], chatPeerId: groupPeerId,
                senderPeerId: userPeerId, messageDate: nil, isOutgoing: false)
            // Asked of the keyring rather than read off the return value: `registeredMembers` is the same list
            // the welcome / reset entries pick from, so this reports success exactly when those can now name
            // this member.
            guard runtime.registeredMembers(chatPeerId: groupPeerId).contains(p1.userId) else {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "keyring"]))
                return
            }
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegistered") + " · " + name)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    /// Rule 1: manual / verified chats send at once, an unverified auto-paired chat asks first, no encrypted chat → pair first.
    private static func send(context: AccountContext, groupPeerId: PeerId, groupTitle: String, member: PeerId, name: String, level: OnlineInviteLevel?, force: Bool, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        guard level != nil else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgInviteMemberNotPaired"))
            return
        }
        if level == .unverified && !force {
            let confirm = UIAlertController(title: SecutgL10n.string("SecutgInviteUnverifiedTitle"), message: SecutgL10n.string("SecutgInviteUnverifiedBody", ["name": name]), preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgInviteSendAnyway"), style: .destructive, handler: { [weak controller] _ in
                guard let controller else { return }
                send(context: context, groupPeerId: groupPeerId, groupTitle: groupTitle, member: member, name: name, level: level, force: true, controller: controller)
            }))
            confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(confirm, over: controller)
            return
        }
        do {
            let built = try runtime.buildGroupInvite(groupPeerId: groupPeerId, userPeerId: member, title: groupTitle)
            SecutgChatMenu.sendText(context: context, peerId: member, text: built.text)
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgInviteSent", ["name": name]))
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
        }
    }

    /// Group members as peers: the cached participant list of a legacy group, the recent members of a supergroup.
    /// nil means the list never loaded, which every reader treats as "unknown", never as "nobody". Module-wide
    /// rather than private since the welcome sheet in `SecutgChatMenu` filters by it too (PLAN.md 3.32 review).
    static func participants(context: AccountContext, groupPeerId: PeerId) -> Signal<[EnginePeer]?, NoError> {
        if groupPeerId.namespace == Namespaces.Peer.CloudChannel {
            return context.engine.peers.channelMembers(peerId: groupPeerId)
            |> map { members -> [EnginePeer]? in members?.map { $0.peer } }
        }
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.LegacyGroupParticipants(id: groupPeerId))
        |> mapToSignal { participants -> Signal<[EnginePeer]?, NoError> in
            guard let list = participants.knownValue else { return .single(nil) }
            let ids = list.map { $0.peerId }
            return context.engine.data.get(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
            |> map { peers -> [EnginePeer]? in ids.compactMap { peers[$0] ?? nil } }
        }
    }

    // MARK: member: the card

    /// This invite's key is already in this device's keyring, so there is nothing left to do. The keyring is asked
    /// here, at render time: the meta rides on a persisted message attribute, so the answer can never be stored in
    /// it — only the `masterId` is, and the live ring decides what the card says. Cards stored before the id was
    /// carried fall back to deriving it from the payload, so they flip too.
    public static func isUsed(invite: SecutgTextMetaAttribute.GroupInvite, accountPeerId: PeerId) -> Bool {
        guard invite.ok, !invite.isOwn,
              let masterId = invite.masterId ?? SecutgAccountRuntime.inviteMasterId(keyPayload: invite.keyPayload) else { return false }
        return SecutgHookRegistry.shared.runtime(for: accountPeerId)?.hasMaster(masterId) ?? false
    }

    /// Card text for the bubble: title, the three steps and the tappable "Import and join" line; `entities`
    /// bolds the first and last line. `author` is the sender of the private chat (falls back to the `via` user id).
    /// Once the invite has been used the card collapses to a single line — no button, and no key behind it.
    public static func cardText(invite: SecutgTextMetaAttribute.GroupInvite, author: Peer?, accountPeerId: PeerId, strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> (text: String, entities: [MessageTextEntity]) {
        let title = invite.title ?? ""
        if !invite.ok { return (SecutgL10n.string("SecutgInviteInvalid"), []) }
        if invite.isOwn { return (SecutgL10n.string("SecutgInviteOwnLine", ["title": title]), []) }
        if isUsed(invite: invite, accountPeerId: accountPeerId) {
            return (SecutgL10n.string("SecutgInviteDone", ["title": title]), [])
        }
        let name = author.map { EnginePeer($0).displayTitle(strings: strings, displayOrder: displayOrder) } ?? (invite.via ?? "")
        let head = SecutgL10n.string("SecutgInviteCardTitle", ["name": name, "title": title])
        let body = SecutgL10n.string("SecutgInviteCardBody")
        let action = "\u{25B6} " + SecutgL10n.string("SecutgInviteAccept")
        let text = head + "\n\n" + body + "\n\n" + action
        let actionStart = text.utf16.count - action.utf16.count
        return (text, [
            MessageTextEntity(range: 0..<head.utf16.count, type: .Bold),
            MessageTextEntity(range: actionStart..<text.utf16.count, type: .Bold),
        ])
    }

    /// Tap on the card: confirm, import the key into the group, post our `P1` there, report. Presented from the
    /// bubble's view because the content node has no controller.
    public static func presentAccept(context: AccountContext, message: Message, hostView: UIView) {
        guard let meta = message.secutgMeta, meta.kind == .groupInvite, let invite = meta.invite, invite.ok, !invite.isOwn,
              !isUsed(invite: invite, accountPeerId: context.account.peerId),
              let groupChatId = invite.groupChatId, let keyPayload = invite.keyPayload, let via = invite.via,
              let groupPeerId = SecutgAccountRuntime.peerId(chatKey: groupChatId),
              let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        let title = invite.title ?? ""
        let alert = UIAlertController(title: SecutgL10n.string("SecutgInviteAccept"), message: SecutgL10n.string("SecutgInviteCardBody"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgInviteAccept"), style: .default, handler: { _ in
            do {
                let p1 = try runtime.acceptGroupInvite(groupPeerId: groupPeerId, keyPayload: keyPayload, via: via)
                SecutgChatMenu.sendText(context: context, peerId: groupPeerId, text: p1)
                // The key is in the ring now, so this card has nothing left to offer. The card reads that from the
                // live keyring when it lays out, so bumping the message here is what makes it redraw as the done
                // line at once instead of waiting for the row to be laid out again for some other reason.
                let _ = secutgRefreshMessage(postbox: context.account.postbox, id: message.id).startStandalone()
                // The whole reason a member joins late (PLAN.md 3.17): the messages already in the group open now,
                // and the count rides along in the one confirmation rather than in a second alert over it.
                SecutgChatMenu.redecrypt(context: context, peerIds: [groupPeerId], completion: { [weak hostView] line in
                    guard let hostView else { return }
                    present(SecutgChatMenu.joined(SecutgL10n.string("SecutgInviteAccepted", ["title": title]), line), from: hostView)
                })
            } catch {
                present(SecutgL10n.string("SecutgImportFailed") + "\n\(error)", from: hostView)
            }
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, from: hostView)
    }

    private static func present(_ text: String, from view: UIView) {
        let a = UIAlertController(title: "Si4Gram", message: text, preferredStyle: .alert) // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        a.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
        SecutgChatMenu.presentSystem(a, from: view)
    }

    // MARK: labels (rule 4)

    public static func levelLabel(_ level: OnlineInviteLevel?) -> String {
        switch level {
        case .verified: return SecutgL10n.string("SecutgInviteMemberVerified")
        case .unverified: return SecutgL10n.string("SecutgInviteMemberUnverified")
        case .manual: return SecutgL10n.string("SecutgInviteMemberManual")
        case nil: return SecutgL10n.string("SecutgInviteMemberNotPaired")
        }
    }

    /// How a registered member got the key, as recorded on the admin device
    public static func memberSourceLabel(status: SecutgChatStatus, userId: String) -> String {
        switch status.onlineInvites[userId] {
        case .verified: return SecutgL10n.string("SecutgMemberSourceOnlineVerified")
        case .unverified: return SecutgL10n.string("SecutgMemberSourceOnlineUnverified")
        case .manual: return SecutgL10n.string("SecutgMemberSourceOnlineManual")
        case nil: return SecutgL10n.string("SecutgMemberSourceOffline")
        }
    }

    /// The group's security level line for the status sheet: where this device's key came from (member view) or
    /// how many members got it online (admin view). `nameOf` resolves the admin's user id for the member view.
    public static func groupLevelLine(status: SecutgChatStatus, nameOf: (String) -> String) -> String {
        guard status.hasKey else { return SecutgL10n.string("SecutgStatusNoKey") }
        if case let .online(via, viaLevel) = status.keySource {
            let verified = SecutgL10n.string(viaLevel == .unverified ? "SecutgVerifiedNo" : "SecutgVerifiedYes")
            return SecutgL10n.string("SecutgLevelGroupOnline", ["name": nameOf(via), "verified": verified])
        }
        let onlineCount = status.onlineInvites.count
        return onlineCount > 0
            ? SecutgL10n.string("SecutgLevelGroupOnlineAdmin", ["count": "\(onlineCount)"])
            : SecutgL10n.string("SecutgLevelGroupOffline")
    }
}
