import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import TelegramPresentationData
import QrCodeUI
import SecutgCore
import SecutgBuildInfo
import SecutgRelay // SECUTG-HOOK (PLAN.md 3.48): one-directional only — SecutgRelay must never import SecutgChatMenu back

/// SECUTG: the secuTG menu of a chat. A short first level (toggle, safety code / key QR, More…) with the
/// rest behind second-level sheets (Manual pairing… / Members & rekey… / More…), the same layout on every client.
/// Every user-facing string goes through `SecutgL10n`, so the menu follows the Telegram language (PLAN.md 3.12).
public enum SecutgChatMenu {
    /// PLAN.md 3.34.6: `members` is gone. A group's key has exactly one action now — rebuild it — and the five
    /// entries that level held (online invite / register a member's key / welcome / drop members & rekey /
    /// rotate) each asked the user to work out which situation they were in first. They are all the same
    /// button now. **Receiving is untouched**: a `G1` invite card and an `R1 reset` from an older build are
    /// still parsed and applied exactly as before (3.34.6 「保留解析、移除入口」).
    public enum ListKind { case more, manual, transfer }

    /// One menu entry: either an action or a second-level list.
    public struct Entry {
        /// Stable name of the action, identical to the Web action table's `id` (`buildSecutgActions()`).
        /// PLAN.md 3.24.7 rule 2: the onboarding card is **a second renderer of this table, not a second
        /// implementation** — every button on it looks an entry up by this id and runs whatever it finds,
        /// or does nothing. That is the whole mechanism that stops the card and the menu from growing two
        /// versions of one action. It has no default on purpose: an entry without an id would be an action
        /// the card can never reach, and the compiler should say so rather than the user finding out.
        public let id: String
        public let title: String
        public let icon: String
        public let destructive: Bool
        public let list: ListKind?
        public let handler: () -> Void

        init(id: String, title: String, icon: String, destructive: Bool = false, list: ListKind? = nil, handler: @escaping () -> Void = {}) {
            self.id = id; self.title = title; self.icon = icon; self.destructive = destructive; self.list = list; self.handler = handler
        }
    }

    private struct Scope {
        let context: AccountContext
        let peerId: PeerId
        let controller: ViewController
        let runtime: SecutgAccountRuntime
        let status: SecutgChatStatus
    }

    private static func scope(context: AccountContext, peerId: PeerId, controller: ViewController) -> Scope? {
        guard peerId.namespace != Namespaces.Peer.SecretChat, let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return nil }
        syncLanguage(context: context)
        return Scope(context: context, peerId: peerId, controller: controller, runtime: runtime, status: runtime.status(chatPeerId: peerId))
    }

    /// Keeps `SecutgL10n` on the Telegram in-app language (English UI → English, Chinese UI → Chinese).
    public static func syncLanguage(context: AccountContext) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        // Primary first, base only as a fallback, the same order the other four clients use. Taking the
        // base first would hand a Traditional pack derived from Simplified the wrong table.
        SecutgL10n.currentLanguageCode = SecutgL10n.map(
            strings.primaryComponent.languageCode, base: strings.baseLanguageCode
        ).rawValue
        // SECUTG-HOOK (PLAN.md 3.48): wires SecutgRelay's own UIKit modals through the same passcode-lock gate
        // every other secuTG modal uses (PLAN.md 3.37.1). SecutgRelay cannot import SecutgAppLock itself without
        // creating the cycle this component already avoids (SecutgChatMenu → SecutgRelay only); this one-line
        // assignment is the bridge, re-run on every menu/settings open (idempotent, negligible cost).
        SecutgRelayPresentation.presentModal = SecutgAppLock.presentModal
    }

    /// First level.
    ///
    /// PLAN.md 3.34.6 moved 「重建群密钥」 up to here, and it is gated on Telegram's own admin rights, which
    /// live in the postbox rather than in the keyring and so cannot be read on this thread. This entry point
    /// answers no for it, exactly as `list(_:context:peerId:controller:)` has always done for the same entry
    /// one level down: `presentSheet` resolves the fact first and asks the overload below, which is how the
    /// sheet the user actually sees gets it right, and the onboarding card keeps the no deliberately — it
    /// never names `recreateGroupKey`, and a card able to reach an action this table is still deciding about
    /// would be a second copy of the rules (PLAN.md 3.24.7 rule 2).
    public static func entries(context: AccountContext, peerId: PeerId, controller: ViewController) -> [Entry] {
        return entries(context: context, peerId: peerId, controller: controller, isTelegramAdmin: false)
    }

    private static func entries(context: AccountContext, peerId: PeerId, controller: ViewController, isTelegramAdmin: Bool) -> [Entry] {
        guard let s = scope(context: context, peerId: peerId, controller: controller) else { return [] }
        return s.status.isPrivateChat ? privatePrimary(s) : groupPrimary(s, isTelegramAdmin: isTelegramAdmin)
    }

    /// Second level.
    ///
    /// PLAN.md 3.32: the group "More…" list has one entry whose presence turns on Telegram's own admin
    /// rights, and those live in the postbox rather than in the keyring, so they cannot be read on this
    /// thread. This entry point answers no for it. `presentList` resolves the fact first and then asks the
    /// overload below, which is how the sheet the user actually sees gets it right; `action(anyOf:)` comes
    /// through here and keeps the no, deliberately — the onboarding card never names `recreateGroupKey`,
    /// and a card able to reach an action this table is still deciding about would be a second copy of the
    /// rules (rule 2 of PLAN.md 3.24.7).
    public static func list(_ kind: ListKind, context: AccountContext, peerId: PeerId, controller: ViewController) -> [Entry] {
        return list(kind, context: context, peerId: peerId, controller: controller, isTelegramAdmin: false)
    }

    private static func list(_ kind: ListKind, context: AccountContext, peerId: PeerId, controller: ViewController, isTelegramAdmin: Bool) -> [Entry] {
        guard let s = scope(context: context, peerId: peerId, controller: controller) else { return [] }
        switch kind {
        case .more: return s.status.isPrivateChat ? privateMore(s) : groupMore(s)
        case .manual: return manual(s)
        case .transfer: return transfer(s)
        }
    }

    /// PLAN.md 3.24.7 rule 2: how a *second renderer* of this table reaches an action. The onboarding
    /// card (PLAN.md 3.24) never implements a button itself — it names one or more ids, takes the first
    /// that this chat's current state actually offers, and runs it exactly as the menu would, second-level
    /// lists included. **An id that is not there does nothing**, because a card offering something the
    /// menu would not is a card that has grown its own copy of the rules.
    public static func action(anyOf ids: [String], context: AccountContext, peerId: PeerId, controller: ViewController) -> Entry? {
        let available = entries(context: context, peerId: peerId, controller: controller)
            + list(.more, context: context, peerId: peerId, controller: controller)
        for id in ids {
            if let found = available.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    public static func run(anyOf ids: [String], context: AccountContext, peerId: PeerId, controller: ViewController, sourceView: UIView?) {
        guard let entry = action(anyOf: ids, context: context, peerId: peerId, controller: controller) else { return }
        if let kind = entry.list {
            presentList(kind, context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        } else {
            entry.handler()
        }
    }

    public static func title(of kind: ListKind) -> String {
        switch kind {
        case .more: return SecutgL10n.string("SecutgMenuMore")
        case .manual: return SecutgL10n.string("SecutgMenuPairManual")
        case .transfer: return SecutgL10n.string("SecutgTransferTitle")
        }
    }

    /// Context-menu form (profile "More" menu and any other upstream menu builder).
    public static func items(context: AccountContext, peerId: PeerId, controller: ViewController) -> [ContextMenuItem] {
        let entries = entries(context: context, peerId: peerId, controller: controller)
        guard !entries.isEmpty else { return [] }
        var items: [ContextMenuItem] = entries.map { entry in
            .action(ContextMenuActionItem(text: entry.title, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: entry.icon), color: theme.contextMenu.primaryColor)
            }, action: { [weak controller] _, f in
                f(.default)
                guard let controller else { return }
                if let kind = entry.list {
                    presentList(kind, context: context, peerId: peerId, controller: controller, sourceView: nil)
                } else {
                    entry.handler()
                }
            }))
        }
        items.append(.separator)
        return items
    }

    /// Action-sheet form, used by the floating lock button in the chat.
    public static func presentSheet(context: AccountContext, peerId: PeerId, controller: ViewController, sourceView: UIView) {
        // PLAN.md 3.34.6: the group's one action is gated on Telegram's own admin rights, and a postbox read is
        // the only way to know them. It reads memory Postbox already holds, so the sheet is not perceptibly
        // later. The other order — put the sheet up now, add the entry when the answer lands — would grow the
        // list under the user's thumb, or miss the entry entirely if they were quick, and for this entry that
        // means the group has no way to change its key at all.
        let _ = (secutgTelegramGroupAdmin(postbox: context.account.postbox, peerId: peerId)
        |> deliverOnMainQueue).startStandalone(next: { [weak controller] isTelegramAdmin in
            guard let controller else { return }
            present(entries(context: context, peerId: peerId, controller: controller, isTelegramAdmin: isTelegramAdmin),
                    title: SecutgL10n.string("SecutgEncrypted"), context: context, peerId: peerId,
                    controller: controller, sourceView: sourceView)
        })
    }

    public static func presentList(_ kind: ListKind, context: AccountContext, peerId: PeerId, controller: ViewController, sourceView: UIView?) {
        guard case .more = kind else {
            present(list(kind, context: context, peerId: peerId, controller: controller), title: title(of: kind), context: context, peerId: peerId, controller: controller, sourceView: sourceView)
            return
        }
        // PLAN.md 3.32: one entry in here is gated on Telegram's own admin rights, and a postbox read is the
        // only way to know them. It reads memory Postbox already holds, so the page is not perceptibly later.
        // The other order — push the page now, add the entry when the answer lands — would grow the list under
        // the user's thumb, or miss the entry entirely if they were quick, which for this entry means the group
        // stays stuck.
        let _ = (secutgTelegramGroupAdmin(postbox: context.account.postbox, peerId: peerId)
        |> deliverOnMainQueue).startStandalone(next: { [weak controller] isTelegramAdmin in
            guard let controller else { return }
            // PLAN.md 3.49 rule 3 / 6: "更多…" is a titled, three-section page now (查看 / 备份 / 危险) rather
            // than a second action sheet — the one place this client's menu needed a real section header.
            controller.push(secutgMoreListController(
                entries: list(.more, context: context, peerId: peerId, controller: controller, isTelegramAdmin: isTelegramAdmin),
                context: context, peerId: peerId, hostController: controller))
        })
    }

    private static func present(_ entries: [Entry], title: String, context: AccountContext, peerId: PeerId, controller: ViewController, sourceView: UIView?) {
        guard !entries.isEmpty else { return }
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: sourceView == nil ? .alert : .actionSheet)
        for entry in entries {
            sheet.addAction(UIAlertAction(title: entry.title, style: entry.destructive ? .destructive : .default, handler: { [weak controller] _ in
                guard let controller else { return }
                if let kind = entry.list {
                    presentList(kind, context: context, peerId: peerId, controller: controller, sourceView: sourceView)
                } else {
                    entry.handler()
                }
            }))
        }
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        if let sourceView, let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        presentSystem(sheet, over: controller)
    }

    // MARK: PLAN.md 3.49 — display-only reorg

    /// Re-groups and re-orders a list this file already decided to offer (every `out.append` below is exactly
    /// the condition it always was) by `MenuLayout`'s fixed PLAN.md 3.49 tables. Decides nothing about presence:
    /// an id this function does not recognise, or one `overrides` does not redirect, asserts in DEBUG and is
    /// otherwise left out — see `MenuLayout.Id`'s own doc for the two ids (`showKey` from a group, `import`
    /// from "更多…") that need an explicit `overrides` entry because the same literal `Entry.id` means a
    /// different section depending on which of this file's functions built it.
    private static func layout(_ entries: [Entry], overrides: [String: MenuLayout.Id] = [:], more: Bool = false) -> [Entry] {
        // PLAN.md 3.49 / menu-layout-expectations.json: the "更多…" list's own `import` entry (a private chat's
        // "导入对方密钥…") is `importManual` in the shared table, distinct from section ③'s `import`
        // (`MenuLayout.Id.importKey`, a group's own first-key/import cluster) — the two never appear in the same
        // caller's list, because they come from two different functions, so this mapping is unconditional
        // whenever `more` is true rather than something each "更多…" call site has to repeat.
        let overrides = more ? overrides.merging(["import": .importManual]) { _, new in new } : overrides
        var byId: [MenuLayout.Id: Entry] = [:]
        var ids: [MenuLayout.Id] = []
        for entry in entries {
            guard let id = overrides[entry.id] ?? MenuLayout.Id(rawValue: entry.id) else {
                assertionFailure("SecutgChatMenu: \(entry.id) has no MenuLayout.Id — add one before offering it.")
                continue
            }
            ids.append(id)
            byId[id] = entry
        }
        let ordered = more ? MenuLayout.moreOrder(ids) : MenuLayout.order(ids)
        return ordered.compactMap { byId[$0] }
    }

    // MARK: entries

    private static func toggle(_ s: Scope) -> Entry {
        let on = s.status.encryptionEnabled
        // PLAN.md 3.49 rule 4: an action sheet cannot show state, so this row reads as a verb here — on other
        // clients, which can draw a checked state, it keeps "加密 · 已开启/已关闭" (`SecutgMenuEncryptionOn/Off`,
        // used elsewhere on this client, e.g. `secutgShowStatus`'s own line, which is a true status line and
        // stays as it was). Same key set as before, same condition, same handler.
        return Entry(id: "toggle", title: SecutgL10n.string(on ? "SecutgMenuEncryptionTurnOff" : "SecutgMenuEncryptionTurnOn"), icon: "Chat/Context Menu/Lock", destructive: on, handler: { [weak controller = s.controller] in
            guard let controller else { return }
            s.runtime.setChatEncryption(chatPeerId: s.peerId, enabled: !on)
            // SECUTG-HOOK (PLAN.md 3.30 rule 10): this switch is one of the two live facts the plaintext bar
            // reads, and the bar is drawn during layout — which this tap does not otherwise trigger. Turning
            // encryption on in a chat the peer has been writing to in the clear is exactly when it should
            // appear, so it appears now rather than whenever the chat next relayouts.
            SecutgPlaintextPaneState.shared.encryptionSwitchChanged()
            // The confirmation spells out what the switch changes, not just which state it landed in
            toast(controller, SecutgL10n.string(on ? "SecutgEncryptionOffNotice" : "SecutgEncryptionOnNotice"))
        })
    }

    /// PLAN.md 3.34.6: in a group the reminder points at the rebuild, because there is no other key action left
    /// there to point at. In a private chat it still runs the ordinary rotate, which is unchanged.
    private static func rekeyDue(_ s: Scope) -> Entry? {
        guard s.status.hasKey, s.status.isRekeyDue else { return nil }
        let days = s.status.keyAgeDays ?? 0
        let run: () -> Void = s.status.isPrivateChat ? { rotate(s) } : groupKeyEntry(s, isFirstKey: false).handler
        return Entry(id: "due", title: SecutgL10n.string("SecutgRekeyDue", ["days": "\(days)"]), icon: "Chat/Context Menu/Reload", destructive: true, handler: run)
    }

    private static func rotate(_ s: Scope) {
        do {
            if s.status.isAutoPaired {
                sendText(context: s.context, peerId: s.peerId, text: try s.runtime.rotatePairedKey(chatPeerId: s.peerId))
            } else if s.status.pairingState != nil || s.status.hasResidualV1Pairing {
                // SECUTG-HOOK (fix, 2026-09-27 真机): a leftover v1 pairing now reads as no state
                // (`hasResidualV1Pairing`), but it is still a pairing record on file — the rule below keeps covering it.
                // PLAN.md 3.25.10: a private chat that has a pairing at all must NEVER fall back to the admin
                // road below. That `R1` is signed with this chat's admin key, and the peer of a paired chat has
                // no `chatAdminPk` to check it against — so it lands as `no_admin_key`, this side switches to
                // the new master and the peer does not, and nothing this side sends can be opened after that.
                // Reported by the user on real phones. The way out of `key_changed` is 重新配对, which this
                // menu already offers.
                toast(s.controller, SecutgL10n.string("SecutgRotateNeedsRepair"))
                return
            } else if s.status.isAdmin {
                sendText(context: s.context, peerId: s.peerId, text: try s.runtime.buildRekey(chatPeerId: s.peerId, request: .rotate))
            } else {
                toast(s.controller, SecutgL10n.string("SecutgRekeyDueMember", ["days": "\(s.status.keyAgeDays ?? 0)"]))
                return
            }
            toast(s.controller, SecutgL10n.string("SecutgRotated"))
        } catch {
            toast(s.controller, SecutgL10n.string("SecutgRotateFailed", ["error": "\(error)"]))
        }
    }

    private static func pair(_ s: Scope) {
        startPairing(context: s.context, peerId: s.peerId, controller: s.controller)
    }

    /// Invite / accept / re-pair: sends this device's P1. When the peer's key is already known the pairing completes
    /// at once and the safety-code dialog follows — through the chat's pairing observer when the chat is on screen
    /// (the runtime announces it), otherwise directly from here (e.g. from the profile menu).
    ///
    /// PLAN.md 3.25.6 rule 2b: every plain "accept" in this client comes through here — the lock menu's entry,
    /// the invite dialog, the button on an invite control line — and none of them has told the user what a
    /// takeover costs. The runtime refuses them while another device of this account holds the pairing, and the
    /// answer is to go to that confirmation rather than to fail: pressing 〔同意〕 means wanting this chat
    /// encrypted, and the takeover dialog is exactly what that wish looks like in this state. Failing silently
    /// would read as a broken button; an error would tell the user they cannot do something they can.
    public static func startPairing(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        do {
            switch try runtime.startPairing(chatPeerId: peerId) {
            case .needsTakeover, .tooSoon:
                SecutgHandoffDialogs.presentTakeoverConfirm(context: context, peerId: peerId, controller: controller)
            case let .started(p1, completed, code):
                sendText(context: context, peerId: peerId, text: p1)
                if completed, let code = code {
                    if !SecutgPairingDialogs.isObserving(peerId: peerId) {
                        SecutgPairingDialogs.presentDone(context: context, peerId: peerId, controller: controller, code: code)
                    }
                    // PLAN.md 3.17: the pairing produced this chat's key, so anything the peer sent before it opens
                    // now. The safety-code dialog is already on screen and matters more, so this one says nothing —
                    // the chat behind it simply becomes readable.
                    redecrypt(context: context, peerIds: [peerId], completion: { _ in })
                } else {
                    toast(controller, SecutgL10n.string("SecutgPairInvited"))
                }
            }
        } catch {
            toast(controller, SecutgL10n.string("SecutgPairFailed", ["error": "\(error)"]))
        }
    }

    /// The safety-code dialog: the twelve digits, what to do with them, whether this chat has been marked as
    /// checked, and both devices' codes.
    ///
    /// A function rather than the body of the lock menu's entry because PLAN.md 3.30 rule 1 puts 〔安全码…〕 on
    /// the "this conversation is now encrypted" line as well (`SecutgControlLine`), and two copies of this
    /// dialog is two places for the verified/unverified wording, the device codes and the note under them to
    /// drift apart. The status is re-read here rather than passed in, so the row — laid out once and then left
    /// alone for as long as it is on screen — cannot open a dialog describing a pairing that has since changed.
    public static func presentSafetyCode(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId),
              let code = runtime.safetyCode(chatPeerId: peerId) else { return }
        syncLanguage(context: context)
        let status = runtime.status(chatPeerId: peerId)
        let verified = status.pairingVerified
        var message = "\(code)\n\n" + SecutgL10n.string("SecutgSafetyHint") + "\n\n"
            + SecutgL10n.string(verified ? "SecutgSafetyStatusVerified" : "SecutgSafetyStatusUnverified")
        // PLAN.md 3.30 rule 5: iOS carried the device codes only in the pairing-done dialog
        // (`SecutgPairingDialogs.presentDone`); the ruling is that both dialogs get them, because both are
        // read on the spot and telling two machines apart on the spot is the entire job of a device code.
        // Last in the body, after the safety code and its status, for the reason the note itself gives and
        // Web's dialog lays out the same way: these codes never stand in for comparing the code above.
        // 本机 is this device's own id, never `pairingState`'s — after a takeover those are two machines.
        if let own = runtime.ownDeviceIdentity(), let peerDeviceId = status.peerDeviceId {
            message += "\n\n" + SecutgL10n.string("SecutgSafetyDeviceCodes", [
                "own": runtime.deviceDisplayText(own.deviceId),
                "peer": runtime.deviceDisplayText(peerDeviceId),
            ]) + "\n" + SecutgL10n.string("SecutgSafetyDeviceCodeNote")
        }
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgSafetyTitle"), message: message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string(verified ? "SecutgSafetyUnverify" : "SecutgSafetyVerified"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            runtime.setPairingVerified(chatPeerId: peerId, verified: !verified)
            toast(controller, SecutgL10n.string(!verified ? "SecutgMarkedVerified" : "SecutgMarkedUnverified"))
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgClose"), style: .cancel))
        presentSystem(sheet, over: controller)
    }

    /// Another device of this account holds the pairing (PLAN.md 3.7 rule 8): only a deliberate re-pair here.
    /// PLAN.md 3.25.6: shares its confirmation and its in-place "sending…" feedback with the header notice's
    /// own take-over button (`SecutgHandoffDialogs`), rather than each keeping its own copy of the flow.
    private static func repairHere(_ s: Scope) -> Entry {
        return Entry(id: "repairHere", title: SecutgL10n.string("SecutgMenuRepairHere"), icon: "Chat/Context Menu/Reload", destructive: true, handler: { [weak controller = s.controller] in
            guard let controller else { return }
            SecutgHandoffDialogs.presentTakeoverConfirm(context: s.context, peerId: s.peerId, controller: controller)
        })
    }

    private static func showKey(_ s: Scope, title: String) -> Entry {
        return Entry(id: "showKey", title: title, icon: "Chat/Context Menu/Image", handler: { [weak controller = s.controller] in
            guard let controller, let payload = s.runtime.exportPayload(chatPeerId: s.peerId) else { return }
            controller.present(SecutgKeyQrController(payload: payload, title: SecutgL10n.string(s.status.isPrivateChat ? "SecutgKeyOfflineTitle" : "SecutgGroupKeyOfflineTitle")), in: .window(.root))
        })
    }

    private static func createKey(_ s: Scope, title: String) -> Entry {
        return Entry(id: "create", title: title, icon: "Chat/Context Menu/Image", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            createMaster(s, over: controller)
        })
    }

    /// Makes this device the holder of this chat's key and puts the payload up for handing out.
    ///
    /// Private chats only, since PLAN.md 3.34: a group's first key goes through `groupKeyEntry` like every
    /// later one, because the mode has to be chosen when the key is made and the notice has to go out with it.
    /// This call makes no notice and asks no question, which is exactly right for a chat with one other person
    /// in it and exactly wrong for a group.
    private static func createMaster(_ s: Scope, over controller: ViewController) {
        do {
            let payload = try s.runtime.createMaster(chatPeerId: s.peerId)
            controller.present(SecutgKeyQrController(payload: payload, title: SecutgL10n.string(s.status.isPrivateChat ? "SecutgKeyCreatedTitle" : "SecutgGroupKeyCreatedTitle")), in: .window(.root))
        } catch {
            toast(controller, SecutgL10n.string("SecutgCreateFailed", ["error": "\(error)"]))
        }
    }

    private static func importKey(_ s: Scope, title: String) -> Entry {
        return Entry(id: "import", title: title, icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            promptImport(context: s.context, peerId: s.peerId, controller: controller, runtime: s.runtime)
        })
    }

    private static func statusEntry(_ s: Scope) -> Entry {
        return Entry(id: "status", title: SecutgL10n.string("SecutgMenuStatus"), icon: "Chat/Context Menu/Info", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let st = s.status
            // PLAN.md 3.13 rule 4: groups say which of the two levels applies and why; private chats keep the pairing levels
            let level = st.isPrivateChat
                ? SecutgL10n.string(!st.hasKey ? "SecutgStatusNoKey" : (st.isAutoPaired ? (st.pairingVerified ? "SecutgLevelVerified" : "SecutgLevelStandard") : "SecutgLevelHigh"))
                : SecutgGroupInvite.groupLevelLine(status: st, nameOf: { $0 })
            var lines = [
                SecutgL10n.string("SecutgStatusEncryption", ["state": SecutgL10n.string(st.encryptionEnabled ? "SecutgOn" : "SecutgOff")]),
                level,
                SecutgL10n.string("SecutgStatusKeyId", ["keyId": st.currentKeyId ?? SecutgL10n.string("SecutgStatusKeyIdNone")]),
                SecutgL10n.string("SecutgStatusKeyAge", ["days": "\(st.keyAgeDays ?? 0)"]),
                SecutgL10n.string("SecutgStatusRole", ["role": SecutgL10n.string(st.isAdmin ? "SecutgRoleAdmin" : "SecutgRoleMember")]),
                SecutgL10n.string("SecutgStatusMembers", ["count": "\(st.memberCount)"]),
                SecutgL10n.string(st.isForwardSecrecy ? "SecutgStatusRatchetOn" : "SecutgStatusRatchetOff"),
            ]
            // PLAN.md 3.25.5 item 1: two more lines for a private chat once it has paired at least once —
            // which key belongs to the peer, and which of this account's own devices currently holds it.
            // The picker rows repeat the row's own role key rather than the bare device text: before either
            // device has been labelled both read as a six-character code, and a picker of two identical-looking
            // codes is how a user ends up naming the wrong machine.
            var labelOptions: [(deviceId: String, title: String)] = []
            if st.isPrivateChat, let peerDeviceId = st.peerDeviceId {
                let peerLine = SecutgL10n.string("SecutgStatusPeerDevice", ["device": s.runtime.deviceDisplayText(peerDeviceId)])
                lines.append(peerLine)
                labelOptions.append((peerDeviceId, peerLine))
            }
            if st.isPrivateChat, let ownDeviceId = st.ownDeviceId {
                let ownText = st.pairingState == "other_device"
                    ? SecutgL10n.string("SecutgDeviceNotThisOne", ["device": s.runtime.deviceDisplayText(ownDeviceId)])
                    : SecutgL10n.string("SecutgSelfDevice") + " · " + s.runtime.deviceDisplayText(ownDeviceId)
                lines.append(SecutgL10n.string("SecutgStatusOwnDevice", ["device": ownText]))
                labelOptions.append((ownDeviceId, SecutgL10n.string("SecutgStatusOwnDevice", ["device": s.runtime.deviceDisplayText(ownDeviceId)])))
            }
            let a = UIAlertController(title: SecutgL10n.string("SecutgMenuStatus"), message: lines.joined(separator: "\n"), preferredStyle: .alert)
            if !labelOptions.isEmpty {
                a.addAction(UIAlertAction(title: SecutgL10n.string("SecutgDeviceLabelEdit"), style: .default, handler: { [weak controller] _ in
                    guard let controller else { return }
                    SecutgDeviceLabelDialogs.presentPicker(context: s.context, controller: controller, options: labelOptions)
                }))
            }
            a.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
            presentSystem(a, over: controller)
        })
    }

    // SECUTG-HOOK (fix, 2026-09-27 真机): 〔重新生成密钥并重新配对〕 (`regenerate`, PLAN.md 3.7 rule 12) is gone from
    // every menu, for every chat. It replaced this device's identity key pair — the very keys v2's identity is built
    // from (`V2IdentityBridge`) — so after the next launch every v2 binding on the device failed with bad_signature
    // (「这条加密信息用本聊天的密钥打不开…」), and it sent a v1 P1 that stacked a second, parallel v1 pairing on a live v2
    // one. v1 new pairing is permanently disabled. `SecutgAccountRuntime.regenerateAndRepair` stays, unreachable.

    /// PLAN.md 3.11 "About secuTG": version, channel, site, source, contact and build fingerprint from the bundled
    /// secutg.json (the fingerprint itself is the Bazel-injected `SecutgBuildInfo`); anything missing → unofficial.
    /// PLAN.md 3.25.5 item 5 used to ride along here — this device's code, with copy and a label editor — because
    /// iOS had no secuTG settings screen to put it on. It has one now (PLAN.md 3.29.1 rule 3,
    /// `secutgSettingsController`), which is where those rows moved, so this dialog is about the build again.
    private static func aboutEntry(_ s: Scope) -> Entry {
        return Entry(id: "about", title: SecutgL10n.string("SecutgAboutTitle"), icon: "Chat/Context Menu/Info", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let about = SecutgAbout.current()
            let sheet = UIAlertController(title: SecutgL10n.string("SecutgAboutTitle"), message: about.lines.joined(separator: "\n"), preferredStyle: .alert)
            if let site = about.siteURL {
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgAboutSite"), style: .default, handler: { _ in
                    s.context.sharedContext.applicationBindings.openUrl(site.absoluteString)
                }))
            }
            if let source = about.sourceURL {
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgAboutSource"), style: .default, handler: { _ in
                    s.context.sharedContext.applicationBindings.openUrl(source.absoluteString)
                }))
            }
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgClose"), style: .cancel))
            presentSystem(sheet, over: controller)
        })
    }

    /// PLAN.md 3.15: the illustrated guide and the sponsor page, reachable from the chat menu as well as from
    /// Settings. Opening the guide from a private chat jumps straight to the `private` chapter; a group opens the
    /// chapter list, because a group member may be reading it as a member or as an admin.
    private static func guideEntry(_ s: Scope) -> Entry {
        return Entry(id: "guide", title: SecutgL10n.string("SecutgGuideTitle"), icon: "Chat/Context Menu/Help", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            presentGuide(context: s.context, controller: controller, chapterId: s.status.isPrivateChat ? "private" : nil)
        })
    }

    // SECUTG-HOOK (PLAN.md 3.48.0 hook ④): one row, "本聊天的中转", pushing SecutgRelay's own chat screen. Shown
    // for every chat this menu already covers (private or group) — relay sending does not depend on this chat
    // having a keyring entry, since PLAN.md 3.48.0 rule 4 routes `L1:` through whatever this chat's ordinary send
    // path already is (encrypted when paired, plain otherwise).
    private static func relayEntry(_ s: Scope) -> Entry {
        return Entry(id: "relay", title: SecutgL10n.string("SecutgRelayChatTitle"), icon: "Chat/Context Menu/Forward", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            SecutgRelayMenu.pushChatController(context: s.context, peerId: s.peerId, controller: controller)
        })
    }

    /// An unconfigured sponsor block hides the entry instead of opening an empty page.
    // SECUTG-HOOK (PLAN.md 3.53): the real implementation (and its `presentSponsor` reference) is compiled
    // out entirely for an App Store submission build; the stub below always hides the entry instead.
    #if !SECUTG_STORE_BUILD
    private static func sponsorEntry(_ s: Scope) -> Entry? {
        guard hasSponsorContent else { return nil }
        return Entry(id: "sponsor", title: SecutgL10n.string("SecutgSponsorTitle"), icon: "Chat/Context Menu/Gift", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            presentSponsor(context: s.context, controller: controller)
        })
    }
    #else
    private static func sponsorEntry(_ s: Scope) -> Entry? {
        return nil
    }
    #endif

    /// Whether this build carries any sponsor details at all (built-in config only, PLAN.md 3.15 rule 7).
    // SECUTG-HOOK (PLAN.md 3.53): an App Store build never shows the sponsor section — this is now decided at
    // compile time (`SECUTG_STORE_BUILD`), not by a runtime config flag.
    public static var hasSponsorContent: Bool {
        #if SECUTG_STORE_BUILD
        return false
        #else
        return SecutgConfigHolder.shared.config?.hasSponsorContent ?? false
        #endif
    }

    public static func presentGuide(context: AccountContext, controller: ViewController, chapterId: String? = nil) {
        syncLanguage(context: context)
        controller.present(SecutgGuideController(context: context, initialChapterId: chapterId), in: .window(.root))
    }

    /// Same guide, for a caller that has no `ViewController` of its own — a message bubble, which reaches the chat
    /// only through its controller interaction (PLAN.md 3.17: the undecryptable line points at the member chapter).
    public static func presentGuide(context: AccountContext, present: (ViewController) -> Void, chapterId: String? = nil) {
        syncLanguage(context: context)
        present(SecutgGuideController(context: context, initialChapterId: chapterId))
    }

    // SECUTG-HOOK (PLAN.md 3.53): absent entirely from an App Store submission build — `SecutgSponsorController`
    // itself does not exist there either. Every caller (SecutgSettingsAboutPage.swift,
    // PeerInfoScreenSettingsActions.swift) wraps its own call site in `#if !SECUTG_STORE_BUILD` too.
    #if !SECUTG_STORE_BUILD
    public static func presentSponsor(context: AccountContext, controller: ViewController) {
        syncLanguage(context: context)
        controller.present(SecutgSponsorController(context: context), in: .window(.root))
    }
    #endif

    /// PLAN.md 3.15 rule 1: "{version} · {build}", or the unofficial-build line when the distribution block is
    /// incomplete. Tapping the row copies exactly this text.
    public static func versionLine(context: AccountContext) -> String {
        syncLanguage(context: context)
        return SecutgAbout.versionLine() ?? SecutgL10n.string("SecutgAboutUnofficial")
    }

    /// The Settings row copies the line and says so.
    public static func copyVersion(context: AccountContext, controller: ViewController) {
        UIPasteboard.general.string = versionLine(context: context)
        toast(controller, SecutgL10n.string("SecutgVersionCopied"))
    }

    private static func privatePrimary(_ s: Scope) -> [Entry] {
        // PLAN.md 3.15: the guide goes first, at the top level, never inside "更多…" — the person it
        // exists for is the one who does not yet know how any of this works, and that person does not
        // open a submenu called "more".
        let st = s.status
        var out: [Entry] = [guideEntry(s)]
        // SECUTG-HOOK (UI, 2026-09-27 用户要求): the due-key reminder runs 〔换新密钥〕, hidden on a paired 1v1 chat for now.
        if !st.isAutoPaired, let due = rekeyDue(s) { out.append(due) }
        if st.hasKey { out.append(toggle(s)) }
        // SECUTG-HOOK: "accept"/"pair" below (`pairingState == nil`, i.e. v1 has no record for this
        // chat at all) are kept — NOT removed — even though v1's fresh-pairing entry points are
        // otherwise gone from this client. Both call `pair(s)` -> `startPairing(context:peerId:
        // controller:)` -> `SecutgAccountRuntime.startPairing(chatPeerId:)`, which (PLAN.md UI-01,
        // `startPairingV2` above `startPairing` in SecutgRuntime.swift) already tries v2 FIRST
        // whenever `ring.chatPairing(chat) == nil` — precisely the condition gating both cases here —
        // and a `V2Runtime` exists for the account, which it now always does once `Account.init` has
        // run (`V2Bootstrap.initV2Worker`, wired in unconditionally). So these two menu entries are
        // structurally v2's OWN pairing-initiation UI now, not a v1 entry point that happens to still
        // be reachable: removing them would remove the only way to start v2 pairing at all, which is
        // the opposite of this task's goal. SECUTG-HOOK (fix, 2026-09-27 真机): `startPairing` no longer
        // reaches v1's `processor.startPairing` at all — whatever v1 records exist, it is v2 only, and a v2
        // refusal is thrown (「配对失败：…」) rather than answered with a v1 P1 the peer could never accept.
        // SECUTG-HOOK (fix, 2026-09-27 真机): `pairingState` is v2-first now and a leftover v1 pairing reads as
        // nothing — but the v1 key such a leftover left behind used to hide 〔自动配对〕 below (`hasKey == false`),
        // the only way left to pair. A key only blocks it when no leftover explains it (a real manual key).
        let keyBlocksAutoPair = st.hasKey && !st.hasResidualV1Pairing
        switch (st.pairingState, st.hasIncomingInvite, keyBlocksAutoPair) {
        case ("key_changed", _, _):
            out.append(Entry(id: "repair", title: SecutgL10n.string("SecutgMenuRepair"), icon: "Chat/Context Menu/Reload", destructive: true, handler: { pair(s) }))
        case ("other_device", _, _):
            out.append(repairHere(s))
        case ("invited", _, _):
            out.append(Entry(id: "waiting", title: SecutgL10n.string("SecutgMenuPairWaiting"), icon: "Chat/Context Menu/Lock", handler: { toast(s.controller, SecutgL10n.string("SecutgWaitingPeer")) }))
        // SECUTG-HOOK (fix, 2026-09-27): used to require `hasKey == false` too — live-reported, this made
        // a genuinely detected, freshly-cached v2 invite unreachable the moment any key already existed
        // for the chat, exactly the normal case for re-pairing. `hasKey` reads only v1's KeyRing and has
        // nothing to do with v2's own send dispatch (which checks its own binding store), so dropping it
        // here cannot mix v1/v2 state or auto-adopt anything — tapping still goes through the same
        // explicit `pair(s)` accept flow as before. `(nil, false, false)`'s "start fresh" entry right
        // below keeps requiring `hasKey == false`: that action means "no key and no invite", which stays
        // wrong to offer once a key exists.
        case (nil, true, _):
            out.append(Entry(id: "accept", title: SecutgL10n.string("SecutgMenuPairAccept"), icon: "Chat/Context Menu/Lock", handler: { pair(s) }))
        // SECUTG-HOOK (fix, 2026-09-27): an already-paired chat whose peer sent a genuinely NEWER invite
        // (reinstall / reset on their side) — `hasIncomingInvite` is only true here when the cached v2
        // INVITE post-dates the current binding (`v2Status`). Same accept action as above: `pair(s)` →
        // `startPairingV2` accepts the cached invite first, and the new pairing replaces the old key.
        case ("paired", true, _):
            out.append(Entry(id: "accept", title: SecutgL10n.string("SecutgMenuPairAccept"), icon: "Chat/Context Menu/Lock", handler: { pair(s) }))
        case (nil, false, false):
            out.append(Entry(id: "pair", title: SecutgL10n.string("SecutgMenuPairAuto"), icon: "Chat/Context Menu/Lock", handler: { pair(s) }))
        default:
            break
        }
        if st.isAutoPaired {
            out.append(Entry(id: "safety", title: SecutgL10n.string(st.pairingVerified ? "SecutgMenuSafetyCodeVerified" : "SecutgMenuSafetyCodeUnverified"), icon: "Chat/Context Menu/Info", handler: { [weak controller = s.controller] in
                guard let controller else { return }
                presentSafetyCode(context: s.context, peerId: s.peerId, controller: controller)
            }))
        } else if st.hasKey {
            out.append(showKey(s, title: SecutgL10n.string("SecutgMenuShowKey")))
        }
        // SECUTG-HOOK (fix, 2026-09-27 真机): 〔手动配对〕 imports / creates a v1 key. While v2 has any state for the chat
        // (binding, in-flight exchange, pending invite) that is a second, parallel key set — hidden.
        if !st.hasKey && !st.hasV2PairingState { out.append(Entry(id: "manual", title: title(of: .manual), icon: "Chat/Context Menu/Image", list: .manual)) }
        if chatKeyShareOnTop(s) { out.append(quickShareEntry(s, id: "chatKeyShare", title: SecutgL10n.string("SecutgMenuChatKeyShare"))) }
        // PLAN.md 3.49 rule 1 section ④: these two used to live inside "更多…"; the rule moves them to the
        // first level, unconditionally — same entries, same conditions, same handlers, `layout` below places them.
        out.append(keyRequiredEntry(s))
        out.append(relayEntry(s)) // SECUTG-HOOK (PLAN.md 3.48.0 hook ④)
        if !privateMore(s).isEmpty { out.append(Entry(id: "more", title: title(of: .more), icon: "Chat/Context Menu/More", list: .more)) }
        return layout(out)
    }

    /// The paired-chat key actions (〔换新密钥〕, forward secrecy) — hidden from the menu for now (2026-09-27, user
    /// request); kept here unchanged so bringing them back is one call in `privateMore`.
    private static func pairedKeyActions(_ s: Scope) -> [Entry] {
        let st = s.status
        var out: [Entry] = []
            // PLAN.md 3.30 rule 6: this replaces the key the chat is encrypting with, the moment it is tapped
            // and with no way back, so it asks first — reusing the string Android has carried all along
            // (`SecutgRotatePairedHint`, which answers the question the user actually has: old messages stay
            // readable).
            //
            // Scoped to this entry alone, which is the one the ruling names. 〔该换钥了〕 (`rekeyDue`) runs the
            // very same `rotate`, but it is an answer to a reminder this menu just put in front of the user
            // rather than something they went looking for; and the group admin's 〔换新密钥〕 is a different
            // action on a different key, outside rule 6's two. Neither confirms, on any client.
            out.append(Entry(id: "rotate", title: SecutgL10n.string("SecutgMenuRotatePaired"), icon: "Chat/Context Menu/Reload", handler: { [weak controller = s.controller] in
                guard let controller else { return }
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgMenuRotatePaired"), message: SecutgL10n.string("SecutgRotatePairedHint"), preferredStyle: .alert)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgMenuRotatePaired"), style: .default, handler: { _ in rotate(s) }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
                presentSystem(sheet, over: controller)
            }))
            // SECUTG-HOOK (fix, 2026-09-27 真机): a v1-only entry, hidden on a v2-bound chat — forward secrecy re-keys
            // the v1 record (`R1:ratchet`). A real v1-only "paired" chat keeps it. 〔换新密钥〕 above stays: on a v2
            // binding it is v2's own rekey. (Regenerate-and-repair is gone from every chat — see the note above
            // `aboutEntry`.)
            if !st.isV2Paired {
                let turningOn = !st.isForwardSecrecy
                out.append(Entry(id: "fs", title: SecutgL10n.string(st.isForwardSecrecy ? "SecutgMenuForwardSecrecyOn" : "SecutgMenuForwardSecrecyOff"), icon: "Chat/Context Menu/Lock", handler: { [weak controller = s.controller] in
                    guard let controller else { return }
                    let message = SecutgL10n.string(turningOn ? "SecutgForwardSecrecyOnHint" : "SecutgForwardSecrecyOffHint")
                    let sheet = UIAlertController(title: SecutgL10n.string("SecutgForwardSecrecyTitle"), message: message, preferredStyle: .alert)
                    sheet.addAction(UIAlertAction(title: SecutgL10n.string(turningOn ? "SecutgForwardSecrecyTurnOn" : "SecutgForwardSecrecyTurnOff"), style: turningOn ? .destructive : .default, handler: { _ in
                        do {
                            let wire = try s.runtime.setForwardSecrecy(chatPeerId: s.peerId, enabled: turningOn)
                            sendText(context: s.context, peerId: s.peerId, text: wire)
                            toast(controller, SecutgL10n.string(turningOn ? "SecutgForwardSecrecyEnabled" : "SecutgForwardSecrecyDisabled"))
                        } catch {
                            toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
                        }
                    }))
                    sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
                    presentSystem(sheet, over: controller)
                }))
            }
        return out
    }

    private static func privateMore(_ s: Scope) -> [Entry] {
        let st = s.status
        var out: [Entry] = []
        if st.isAutoPaired {
            // SECUTG-HOOK (UI, 2026-09-27 用户要求「1v1 配对成功后，菜单里面的 换新密钥 / 前向保密 / 重新生成密钥并重新配对 /
            // 解除配对 先隐藏，所有端都这样」): a paired 1v1 chat offers none of them for now. 〔一键恢复初始状态〕 stays and is
            // the way back to an unpaired chat. The entries are kept, unused, in `pairedKeyActions` for when they return.
        } else if st.pairingState == nil && st.hasKey && st.isAdmin && !st.hasResidualV1Pairing {
            // SECUTG-HOOK (fix, 2026-09-27 真机): `!hasResidualV1Pairing` — a leftover v1 pairing reads as no state
            // now, but the admin road stays closed for a chat with any pairing record on file (PLAN.md 3.25.10).
            // PLAN.md 3.25.10 / 3.25.12 (2026-09-20 用户真机：「在配对前，没有配对成功，不应该显示换新密钥」).
            // The admin road signs an `R1` with this chat's admin key. A private chat that HAS a pairing —
            // just not a healthy one — gives the peer no `chatAdminPk` to check that signature against, so it
            // lands as `no_admin_key`: this side switches master, the peer does not, and nothing sent after
            // that can be opened. Android has carried this guard since 3.25.10; the other four had not.
            // The way out of those states is 〔重新配对〕/〔在本机重新配对〕, offered in `privatePrimary`.
            out.append(Entry(id: "rotate", title: SecutgL10n.string("SecutgMenuRotate"), icon: "Chat/Context Menu/Reload", handler: { rotate(s) }))
        }
        if (st.pairingState != nil || st.hasIncomingInvite) && !st.isAutoPaired {
            // PLAN.md 3.30 rule 6, the other half: unpairing takes this chat's encryption away the moment it is
            // tapped and there is no undo, so it asks first — Android's `SecutgUnpairHint` says what is lost.
            //
            // One carve-out, which Web, Windows and macOS each arrived at separately: an invitation nobody has
            // answered yet (`invited`). Nothing is bound and there is no encryption to lose, the button running
            // this action there is the onboarding card's 〔撤回邀请〕 (PLAN.md 3.24.8), and `SecutgUnpairHint`'s
            // promise that "old messages stay readable" is not even true in that state — there are none.
            let needsConfirm = st.pairingState != "invited"
            out.append(Entry(id: "unpair", title: SecutgL10n.string("SecutgMenuUnpair"), icon: "Chat/Context Menu/Delete", destructive: true, handler: { [weak controller = s.controller] in
                guard let controller else { return }
                let run: () -> Void = { [weak controller] in
                    guard let controller else { return }
                    unpairAndNotify(context: s.context, peerId: s.peerId, runtime: s.runtime)
                    // PLAN.md 3.24.8, last-but-one row: the onboarding guide comes back, but already counted as
                    // ignored once, so it returns collapsed. Here rather than in the card, so it holds however
                    // the user unpaired — the card's [withdraw invitation] runs this very entry.
                    SecutgOnboardCardHost.noteUnpaired(context: s.context, peerId: s.peerId)
                    toast(controller, SecutgL10n.string("SecutgUnpaired"))
                }
                guard needsConfirm else {
                    run()
                    return
                }
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgMenuUnpair"), message: SecutgL10n.string("SecutgUnpairHint"), preferredStyle: .alert)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgMenuUnpair"), style: .destructive, handler: { _ in run() }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
                presentSystem(sheet, over: controller)
            }))
        }
        // SECUTG-HOOK (feature, 2026-10-03, PLAN.md 3.50): 「仅在本机重置本聊天的加密」 — the same local
        // clearing as "resetChat" below (`SecutgAccountRuntime#resetChatLocally`'s own doc) but nothing is
        // sent: no cancel, no UNPAIR, no U1. The peer is left believing whatever it believed before. Ranks
        // immediately before "resetChat" in the danger section (`MenuLayout`), same icon, same destructive
        // styling, same confirm-alert shape.
        out.append(Entry(id: "resetChatLocal", title: SecutgL10n.string("SecutgMenuResetChatLocal"), icon: "Chat/Context Menu/Delete", destructive: true, handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let run: () -> Void = { [weak controller] in
                guard let controller else { return }
                s.runtime.resetChatLocally(chatPeerId: s.peerId)
                SecutgOnboardCardHost.noteUnpaired(context: s.context, peerId: s.peerId)
                toast(controller, SecutgL10n.string("SecutgResetChatLocalDone"))
            }
            let sheet = UIAlertController(title: SecutgL10n.string("SecutgMenuResetChatLocal"), message: SecutgL10n.string("SecutgResetChatLocalHint"), preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgMenuResetChatLocal"), style: .destructive, handler: { _ in run() }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            presentSystem(sheet, over: controller)
        }))
        // SECUTG-HOOK (feature, 2026-09-27, "一键恢复"): always offered for a private chat, unlike
        // "unpair" above — a no-op when the chat is already clean is the point, not a bug (see
        // SecutgAccountRuntime#resetChat's own doc), and this is the one action that also reaches a
        // chat stuck in a crossed-invite shape (a transaction open in BOTH roles at once) that
        // "unpair"'s single-transaction lookup cannot.
        out.append(Entry(id: "resetChat", title: SecutgL10n.string("SecutgMenuResetChat"), icon: "Chat/Context Menu/Delete", destructive: true, handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let run: () -> Void = { [weak controller] in
                guard let controller else { return }
                for notice in s.runtime.resetChat(chatPeerId: s.peerId) {
                    sendText(context: s.context, peerId: s.peerId, text: notice)
                }
                SecutgOnboardCardHost.noteUnpaired(context: s.context, peerId: s.peerId)
                toast(controller, SecutgL10n.string("SecutgResetChatDone"))
            }
            let sheet = UIAlertController(title: SecutgL10n.string("SecutgMenuResetChat"), message: SecutgL10n.string("SecutgResetChatHint"), preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgMenuResetChat"), style: .destructive, handler: { _ in run() }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            presentSystem(sheet, over: controller)
        }))
        // SECUTG-HOOK (fix, 2026-09-27 真机): the same v1 manual-key import as 〔手动配对〕, same reason to hide it.
        if st.hasKey && !st.hasV2PairingState { out.append(importKey(s, title: SecutgL10n.string("SecutgMenuPairManualImport"))) }
        // PLAN.md 3.49: `keyRequired` / `relay` moved to the first level (see `privatePrimary`); this list keeps
        // every other entry it always had.
        out.append(transferEntry())
        out.append(statusEntry(s))
        if let sponsor = sponsorEntry(s) { out.append(sponsor) }
        out.append(aboutEntry(s))
        return layout(out, more: true)
    }

    /// PLAN.md 3.41.1 手动: 「没有钥匙时禁止发送」 on / off. A sheet row has no subtitle, so the hint is said where it
    /// is acted on: turning it on is one tap and the confirmation is the hint; turning it off is a deliberate act
    /// — it asks first, with the same words — and sticks until the chat gains a new key (`KeyRequired.toggled`).
    private static func keyRequiredEntry(_ s: Scope) -> Entry {
        let on = s.status.keyRequired
        let title = SecutgL10n.string("SecutgKeyRequiredTitle")
        let state = SecutgL10n.string(on ? "SecutgOn" : "SecutgOff")
        return Entry(id: "keyRequired", title: "\(title) (\(state))", icon: "Chat/Context Menu/Lock", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            if on {
                let sheet = UIAlertController(title: title, message: SecutgL10n.string("SecutgKeyRequiredHint"), preferredStyle: .alert)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgForwardSecrecyTurnOff"), style: .destructive, handler: { _ in
                    s.runtime.setKeyRequired(chatPeerId: s.peerId, enabled: false)
                    SecutgKeyRequiredNoticeState.shared.invalidate()
                }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
                presentSystem(sheet, over: controller)
            } else {
                s.runtime.setKeyRequired(chatPeerId: s.peerId, enabled: true)
                SecutgKeyRequiredNoticeState.shared.invalidate()
                toast(controller, SecutgL10n.string("SecutgKeyRequiredHint"))
            }
        })
    }

    /// PLAN.md 3.14: move keys between this user's own devices. The whole-keyring export also has a home on the
    /// secuTG settings screen (PLAN.md 3.29.1 rule 6); it stays here next to the single-chat one because that is
    /// where somebody already handing one chat's key over will look for it.
    private static func transfer(_ s: Scope) -> [Entry] {
        var out: [Entry] = []
        // PLAN.md 3.14.1: first in the list, as on Web. Saved Messages and groups only (Saved Messages takes the
        // group branch, 3.20): a 1v1 chat's binding belongs to this device's identity, so its multi-device story is
        // ROSTER_COMMIT instead.
        // PLAN.md 3.39.13: ...a 1v1 chat's own entry is the V2Q clone (the other device becomes this one in the chat).
        // Offered in every 1v1 chat; one that has no v2 pairing answers `SecutgV2JoinNotPaired`.
        // 2026-10-02 (user): once the chat has a usable key the entry lives on the lock menu's first level as
        // 〔本会话密钥分享〕 (id `chatKeyShare`, `chatKeyShareOnTop`) and is not repeated here. A 1v1 chat without a v2 binding keeps it
        // here, so `SecutgV2JoinNotPaired` stays reachable.
        if (s.status.isPrivateChat || s.status.hasKey) && !chatKeyShareOnTop(s) {
            out.append(quickShareEntry(s, id: "quickShare", title: SecutgL10n.string("SecutgQuickShare")))
        }
        if s.status.hasKey {
            // An auto-paired private chat only works on the other device with the identity key, so it goes along;
            // groups and manually paired chats do not need it and must not carry it (PLAN.md 3.14).
            let withIdentity = s.status.isAutoPaired
            out.append(Entry(id: "exportChat", title: SecutgL10n.string("SecutgMenuExportChat"), icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
                guard let controller else { return }
                SecutgTransfer.presentExport(context: s.context, controller: controller, scope: .chat, chatPeerIds: [s.peerId], withIdentity: withIdentity)
            }))
        }
        out.append(Entry(id: "exportAll", title: SecutgL10n.string("SecutgMenuExportAll"), icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            SecutgTransfer.presentExport(context: s.context, controller: controller, scope: .all)
        }))
        out.append(Entry(id: "importKeyring", title: SecutgL10n.string("SecutgMenuImportKeyring"), icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            // Opened from a chat, so an offline key pasted into it by mistake has somewhere to be sent.
            SecutgTransfer.presentImport(context: s.context, controller: controller, peerId: s.peerId)
        }))
        // PLAN.md 3.14.1: the receiving half of 〔扫码分享到我的设备〕, next to the import it ends up in. Offered in
        // every chat's list, as on Web: what it imports is whichever chat the QR names, not this one.
        out.append(quickShareScan(s))
        out.append(codeFileImport(s))
        return out
    }

    /// PLAN.md 3.14.1 〔扫码导入〕: the app's QR scanner, then the 3.14 import. Also on a group's first level next to
    /// 〔导入密钥〕, for the new device of mine that has no key yet — the same two places as Web.
    private static func quickShareScan(_ s: Scope) -> Entry {
        return Entry(id: "quickShareScan", title: SecutgL10n.string("SecutgQuickShareScan"), icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            // PLAN.md 3.39.13: from a 1v1 chat the same scanner also takes that chat's V2Q (a clone into THIS chat).
            SecutgTransfer.presentQuickShareScan(context: s.context, controller: controller, peerId: s.peerId)
        })
    }

    /// 2026-10-02 (user): the chat's own key can be shared — a 1v1 chat with a current v2 binding, a group or Saved
    /// Messages with a key. Then 〔本会话密钥分享〕 sits on the first level and the transfer list drops its copy.
    private static func chatKeyShareOnTop(_ s: Scope) -> Bool {
        return s.status.isPrivateChat ? s.status.isV2Paired : s.status.hasKey
    }

    /// The share page (QR + 〔用文件分享〕): the V2Q clone in a 1v1 chat, the K1Q otherwise. `chatKeyShare` on the first
    /// level, `quickShare` in the transfer list — the ids every client uses.
    private static func quickShareEntry(_ s: Scope, id: String, title: String) -> Entry {
        return Entry(id: id, title: title, icon: "Chat/Context Menu/Image", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            SecutgTransfer.presentQuickShare(context: s.context, controller: controller, peerId: s.peerId)
        })
    }

    /// PLAN.md 3.39.14 〔从文件导入〕: the same import as 〔扫码导入〕, from a `.secutg-v2q` / `.secutg-k1q` file — for a code
    /// that came over by AirDrop or as a file because this device could not scan it.
    private static func codeFileImport(_ s: Scope) -> Entry {
        return Entry(id: "quickShareImportFile", title: SecutgL10n.string("SecutgImportFromFile"), icon: "Chat/Context Menu/Download", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            SecutgTransfer.presentCodeFileImport(context: s.context, controller: controller, peerId: s.peerId)
        })
    }

    private static func transferEntry() -> Entry {
        return Entry(id: "transfer", title: SecutgL10n.string("SecutgTransferTitle"), icon: "Chat/Context Menu/Download", list: .transfer)
    }

    private static func manual(_ s: Scope) -> [Entry] {
        var out: [Entry] = []
        if !s.status.hasKey { out.append(createKey(s, title: SecutgL10n.string("SecutgMenuPairManualCreate"))) }
        out.append(importKey(s, title: SecutgL10n.string("SecutgMenuPairManualImport")))
        return out
    }

    private static func groupPrimary(_ s: Scope, isTelegramAdmin: Bool) -> [Entry] {
        // PLAN.md 3.15: same rule in a group.
        let st = s.status
        let isManual = s.runtime.chatKeyMode(chatPeerId: s.peerId) == .manual
        var out: [Entry] = [guideEntry(s)]
        // PLAN.md 3.32 review, batch 1: a member cannot act on a due key — the entry used to open only to
        // say so. The age still shows on the status page; the reminder itself is the signing-key holder's.
        if st.isAdmin, let due = rekeyDue(s) { out.append(due) }
        if st.hasKey { out.append(toggle(s)) }
        // PLAN.md 3.13 rule 5: the offline (QR) and online (encrypted private chat) paths stay separate and carry their level
        if !st.hasKey {
            // The group's first key. Same dialog as the rebuild below, only the explanation differs: from
            // here on there is one thing you do to this key, and this is the first time you do it.
            //
            // PLAN.md 3.34 (2026-09-20 用户定): because it IS the same dialog it reads the same gate. Without
            // this an ordinary member of a keyless group was handed the rebuild —「其他的非管理员不要有重建
            // 群钥匙的菜单」. Importing by hand stays open to everyone: it binds a key this device was given
            // and locks nobody else out.
            if RecreateGroupKeyGate.canCreateGroupKey(hasKey: st.hasKey, isTelegramAdmin: isTelegramAdmin) {
                out.append(groupKeyEntry(s, isFirstKey: true))
            }
            out.append(importKey(s, title: SecutgL10n.string("SecutgMenuImportKeyOffline")))
            out.append(quickShareScan(s))
            out.append(codeFileImport(s))
        } else if st.isAdmin {
            // PLAN.md 3.34.6: the QR code is a manual-mode entry only. In auto mode the key goes to members
            // by itself, so putting it on a screen is nothing but one more place it can be read off.
            if isManual { out.append(showKey(s, title: SecutgL10n.string("SecutgMenuInviteOffline"))) }
        } else {
            out.append(importKey(s, title: SecutgL10n.string("SecutgMenuImportKeyOffline")))
            out.append(quickShareScan(s))
            out.append(codeFileImport(s))
        }
        // PLAN.md 3.34.6: 「重建群密钥」 is the whole of what a group does to its key, so it belongs where
        // somebody looking for it will look. It used to sit in "More…" because it was only the way out after
        // the key-holder went missing; now excluding a member, changing the key and switching mode all run
        // through it. Gated on Telegram's own admins, never on secuTG's — `RecreateGroupKeyGate` says why.
        // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): the group password is a gate, not a key, so 〔重建群密钥〕 is
        // no longer hidden while it is on (the two are unrelated).
        if RecreateGroupKeyGate.canRecreateGroupKey(hasKey: st.hasKey, isTelegramAdmin: isTelegramAdmin) {
            out.append(groupKeyEntry(s, isFirstKey: false))
        }
        out.append(contentsOf: groupPasswordEntries(s, isTelegramAdmin: isTelegramAdmin))
        if chatKeyShareOnTop(s) { out.append(quickShareEntry(s, id: "chatKeyShare", title: SecutgL10n.string("SecutgMenuChatKeyShare"))) }
        // PLAN.md 3.49 rule 1 section ④: moved here from `groupMore` — same entries, same conditions, same
        // handlers, `layout` below places them.
        out.append(keyRequiredEntry(s))
        out.append(relayEntry(s)) // SECUTG-HOOK (PLAN.md 3.48.0 hook ④)
        out.append(Entry(id: "more", title: title(of: .more), icon: "Chat/Context Menu/More", list: .more))
        // PLAN.md 3.49: the one id this file reuses across two different sections — a group's manual-mode
        // invite QR is the same `Entry.id` ("showKey") as a private chat's own key QR, but belongs in section ③
        // (`inviteOffline`, a later rank) here rather than `MenuLayout.Id.showKey`’s own rank in the same section ③.
        return layout(out, overrides: ["showKey": .inviteOffline])
    }

    /// SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.2): 〔设置群密码〕 / 〔修改群密码〕〔关闭群密码〕 for the group's
    /// Telegram admins on an auto-mode group, and — legacy — 〔解锁〕 for a 3.38.1 locked record not yet opened.
    private static func groupPasswordEntries(_ s: Scope, isTelegramAdmin: Bool) -> [Entry] {
        let actions = SecutgGroupPassword.menuActions(status: s.status, keyMode: s.runtime.chatKeyMode(chatPeerId: s.peerId),
                                                     isTelegramAdmin: isTelegramAdmin)
        func makeEntry(_ action: SecutgGroupPassword.MenuAction) -> Entry {
            let id: String
            switch action {
            case .set: id = "groupPwSet"
            case .change: id = "groupPwChange"
            case .disable: id = "groupPwDisable"
            case .unlock: id = "groupPwUnlock"
            }
            let isDisable: Bool
            switch action { case .disable: isDisable = true; default: isDisable = false }
            return Entry(id: id, title: SecutgGroupPassword.title(action), icon: "Chat/Context Menu/Lock",
                         destructive: isDisable, handler: { [weak controller = s.controller] in
                guard let controller else { return }
                SecutgGroupPassword.run(action, context: s.context, peerId: s.peerId, controller: controller)
            })
        }
        // PLAN.md 3.49 decision B: 〔修改群密码〕/〔关闭群密码〕 merge into one row, "群密码 · 已设置"
        // (`SecutgMenuGroupPwRow`), that opens a small sheet holding the exact same two actions, untouched —
        // same ids, same handlers, same dialogs (`SecutgGroupPassword.run`); only this one extra level is new.
        var hasChange = false
        var hasDisable = false
        for action in actions {
            switch action {
            case .change: hasChange = true
            case .disable: hasDisable = true
            default: break
            }
        }
        guard hasChange && hasDisable else {
            return actions.map(makeEntry)
        }
        let change = makeEntry(.change)
        let disable = makeEntry(.disable)
        var out: [Entry] = []
        for action in actions {
            switch action {
            case .change, .disable: continue
            default: out.append(makeEntry(action))
            }
        }
        out.append(Entry(id: "groupPw", title: SecutgL10n.string("SecutgMenuGroupPwRow"), icon: "Chat/Context Menu/Lock", handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let sheet = UIAlertController(title: SecutgL10n.string("SecutgMenuGroupPwRow"), message: nil, preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: change.title, style: .default, handler: { _ in change.handler() }))
            sheet.addAction(UIAlertAction(title: disable.title, style: .destructive, handler: { _ in disable.handler() }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            presentSystem(sheet, over: controller)
        }))
        return out
    }

    private static func groupMore(_ s: Scope) -> [Entry] {
        var out: [Entry] = []
        // PLAN.md 3.34.6: a member's hand crank for the announcement that auto mode normally makes by itself,
        // kept for the case where it did not fire. In manual mode the key never travels by public key at all,
        // so leaving it there would only invite the reader to think it might.
        if !s.status.isAdmin, s.runtime.chatKeyMode(chatPeerId: s.peerId) == .auto {
            out.append(Entry(id: "announce", title: SecutgL10n.string("SecutgMenuAnnounce"), icon: "Chat/Context Menu/User", handler: { [weak controller = s.controller] in
                guard let controller else { return }
                do {
                    sendText(context: s.context, peerId: s.peerId, text: try s.runtime.announceIdentity())
                    toast(controller, SecutgL10n.string("SecutgAnnounced"))
                } catch {
                    toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "\(error)"]))
                }
            }))
        }
        // PLAN.md 3.49: `keyRequired` / `relay` moved to the first level (see `groupPrimary`); this list keeps
        // every other entry it always had.
        out.append(transferEntry())
        out.append(statusEntry(s))
        if let sponsor = sponsorEntry(s) { out.append(sponsor) }
        out.append(aboutEntry(s))
        return layout(out, more: true)
    }

    /// PLAN.md 3.34: **the one thing a group does to its key.** Rebuilding it and creating its first one are
    /// the same act with the same dialog; only the sentence above the question differs.
    ///
    /// The dialog says what this changes before it asks anything, then asks the one question there is: how
    /// does this key reach members? Each answer carries its own price in the same breath, including auto
    /// mode's honest boundary — in that mode the member list *is* the authorisation, so whoever can add
    /// somebody to this group can let them read (3.34.6 「安全边界如实写进文案」).
    private static func groupKeyEntry(_ s: Scope, isFirstKey: Bool) -> Entry {
        let title = SecutgL10n.string(isFirstKey ? "SecutgMenuSetupKey" : "SecutgMenuRecreateGroupKey")
        return Entry(id: isFirstKey ? "create" : "recreateGroupKey", title: title,
                     icon: isFirstKey ? "Chat/Context Menu/Image" : "Chat/Context Menu/Reload",
                     destructive: !isFirstKey, handler: { [weak controller = s.controller] in
            guard let controller else { return }
            let message = SecutgL10n.string(isFirstKey ? "SecutgSetupGroupKeyHint" : "SecutgRecreateGroupKeyHint")
                + "\n\n" + SecutgL10n.string("SecutgKeyModeQuestion")
                + "\n\n" + SecutgL10n.string("SecutgKeyModeAuto") + "\n" + SecutgL10n.string("SecutgKeyModeAutoHint")
                + "\n\n" + SecutgL10n.string("SecutgKeyModeManual") + "\n" + SecutgL10n.string("SecutgKeyModeManualHint")
            let sheet = UIAlertController(title: title, message: message, preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgKeyModeAuto"), style: .default, handler: { _ in
                recreateGroupKey(s, mode: .auto, over: controller)
            }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgKeyModeManual"), style: .default, handler: { _ in
                recreateGroupKey(s, mode: .manual, over: controller)
            }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            presentSystem(sheet, over: controller)
        })
    }

    /// PLAN.md 3.34.3 / 3.34.4: build the key, announce it, then hand it out.
    ///
    /// **The notice goes first, always.** It is what retires the copy every member already holds, and the
    /// order is not cosmetic: a welcome that arrived before it would bind the new master and then be thrown
    /// away by the notice that followed, leaving the member with nothing and no reason to ask again.
    ///
    /// `recreateGroupKey` is one runtime call rather than three because the old public key has to be read
    /// before the new one overwrites it — see there.
    private static func recreateGroupKey(_ s: Scope, mode: Rekey.KeyMode, over controller: ViewController) {
        let built: (notice: String, payload: String, broadcast: String?)
        do {
            built = try s.runtime.recreateGroupKey(chatPeerId: s.peerId, mode: mode)
        } catch {
            toast(controller, SecutgL10n.string("SecutgCreateFailed", ["error": "\(error)"]))
            return
        }
        // PLAN.md 3.35.6: **auto mode is two messages now** — the notice, then the key itself. No `P1` first
        // (nothing verifies a signature on the auto road any more), no welcome per member, no waiting for
        // anyone to announce themselves. 3.35.1 is the list of what each of those could not deliver.
        //
        // Manual mode is untouched and still sends its own `P1` first: rule 2 of 3.34.3 still verifies the
        // notice against the sender's announced identity key there, and a member who never collected it by
        // hand would otherwise meet every notice with no key to check it against.
        if mode == .manual, let p1 = try? s.runtime.announceIdentity() {
            sendText(context: s.context, peerId: s.peerId, text: p1)
        }
        // The notice goes first so the two lines read in order; unlike the welcome road this replaced,
        // nothing breaks if they arrive the other way round, because the broadcast stands on its own.
        sendText(context: s.context, peerId: s.peerId, text: built.notice)
        switch mode {
        case .manual:
            controller.present(SecutgKeyQrController(payload: built.payload, title: SecutgL10n.string("SecutgGroupKeyCreatedTitle")), in: .window(.root))
        case .auto:
            // Missing here means the group gets a notice and no key — precisely the failure 3.35 exists to
            // end — so it is reported rather than passed over in silence.
            guard let broadcast = built.broadcast else {
                toast(controller, SecutgL10n.string("SecutgCreateFailed", ["error": "no broadcast"]))
                return
            }
            sendText(context: s.context, peerId: s.peerId, text: broadcast)
            toast(controller, SecutgL10n.string("SecutgGroupKeyByYou"))
        }
    }

    /// PLAN.md 3.34.4: auto mode hands the new key to 「当前 Telegram 成员 ∩ 已登记公钥」, one sealed copy each.
    ///
    /// The member list is read fresh, here, at send time: that intersection is the whole security model of
    /// auto mode, and it is also how one button does exclusion — somebody who left is simply not in the list.
    /// A list that never loaded stops the send and says so, rather than treating half a list as the whole of
    /// one; the button can be pressed again a moment later, and nobody has been quietly left out meanwhile.
    private static func sendAutoWelcomes(_ s: Scope, over controller: ViewController) {
        let _ = (SecutgGroupInvite.participants(context: s.context, groupPeerId: s.peerId)
        |> deliverOnMainQueue).startStandalone(next: { [weak controller] current in
            guard let controller else { return }
            guard let current else { toast(controller, SecutgL10n.string("SecutgAutoWelcomeMembersUnknown")); return }
            let welcomes = s.runtime.buildAutoWelcomes(
                chatPeerId: s.peerId, memberIds: current.map { SecutgAccountRuntime.userId($0.id) })
            // Nobody has announced a public key yet. Not a failure: every member's device announces itself the
            // moment it opens an auto-mode group it holds no key for, and `SecutgAutoWelcome` answers it then.
            guard !welcomes.isEmpty else { toast(controller, SecutgL10n.string("SecutgAutoWelcomeNobody")); return }
            for welcome in welcomes { sendText(context: s.context, peerId: s.peerId, text: welcome.wire) }
            toast(controller, SecutgL10n.string("SecutgAutoWelcomeSent", ["count": "\(welcomes.count)"]))
        })
    }

    /// PLAN.md 3.34.6: the one road by which a group announcement that REPLACES a registered key is adopted.
    ///
    /// Reached only from the control line that reported it, so the decision lands on the very message being
    /// read. The dialog states both possibilities honestly, because the software genuinely cannot tell them
    /// apart: it may be their new phone, or it may be somebody else sending in their name.
    static func presentAdoptMemberKey(context: AccountContext, peerId: PeerId, controller: ViewController,
                                      userId: String, p1: String) {
        syncLanguage(context: context)
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accept = SecutgL10n.string("SecutgGroupKeyChangedAccept")
        let sheet = UIAlertController(title: accept, message: SecutgL10n.string("SecutgGroupKeyChangedHint"),
                                      preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: accept, style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            let ok = runtime.adoptMemberKey(chatPeerId: peerId, userId: userId, p1: p1)
            toast(controller, ok ? SecutgL10n.string("SecutgGroupKeyAccepted")
                                 : SecutgL10n.string("SecutgRegisterFailed", ["error": "P1"]))
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        presentSystem(sheet, over: controller)
    }

    // MARK: flows

    /// The offline key dialog of one chat. `prefill` carries a payload the user already pasted somewhere else
    /// (the keyring-import dialog, which then offered to bring them here) so nobody has to find it and paste it
    /// a second time — the same courtesy the K1 offer in `applyImport` does in the other direction.
    static func presentOfflineKeyImport(context: AccountContext, peerId: PeerId, controller: ViewController, prefill: String? = nil) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        syncLanguage(context: context)
        promptImport(context: context, peerId: peerId, controller: controller, runtime: runtime, prefill: prefill)
    }

    private static func promptImport(context: AccountContext, peerId: PeerId, controller: ViewController, runtime: SecutgAccountRuntime, prefill: String? = nil) {
        let input = UIAlertController(title: SecutgL10n.string("SecutgImportDialogTitle"), message: SecutgL10n.string("SecutgImportDialogHint"), preferredStyle: .alert)
        input.addTextField { field in
            field.placeholder = SecutgL10n.string("SecutgImportLabel")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let prefill = prefill, !prefill.isEmpty { field.text = prefill }
        }
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgScan"), style: .default, handler: { _ in
            let scanner = QrCodeScanScreen(context: context, subject: .custom(info: SecutgL10n.string("SecutgScanHint")))
            scanner.completion = { [weak controller] code in
                guard let controller, let code else { return }
                applyImport(code, context: context, peerId: peerId, controller: controller, runtime: runtime)
            }
            controller.push(scanner)
        }))
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImport"), style: .default, handler: { [weak input] _ in
            let text = input?.textFields?.first?.text ?? ""
            applyImport(text, context: context, peerId: peerId, controller: controller, runtime: runtime)
        }))
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        presentSystem(input, over: controller)
    }

    private static func applyImport(_ payload: String, context: AccountContext, peerId: PeerId, controller: ViewController, runtime: SecutgAccountRuntime) {
        let outcome = runtime.importMasterResult(chatPeerId: peerId, payload: payload)
        // PLAN.md 3.34.4: the code being scanned is not the one the group's notice announced. Its own sentence
        // rather than the generic failure, because it is the one refusal a real person walks into — they were
        // told to go and scan something, and this is the software saying "not that one, and here is what to do".
        if outcome == .wrongAdminKey {
            presentWrongImportDialog(
                controller: controller, title: SecutgL10n.string("SecutgMenuImportKeyOffline"),
                message: SecutgL10n.string("SecutgImportWrongAdminKey"), action: nil)
            return
        }
        if outcome == .imported {
            // Group members announce their public key right away so the admin can include them in rekeys
            if !runtime.status(chatPeerId: peerId).isPrivateChat, let p1 = try? runtime.announceIdentity() {
                sendText(context: context, peerId: peerId, text: p1)
            }
            // PLAN.md 3.17: whatever this chat was sent before the key arrived can be read now, and the one
            // confirmation waits for that count rather than being followed by a second alert carrying it.
            redecrypt(context: context, peerIds: [peerId], completion: { [weak controller] line in
                guard let controller else { return }
                toast(controller, joined(SecutgL10n.string("SecutgImported"), line))
            })
        } else if ImportText.classify(payload) == .k1 {
            // A K1 transfer file pasted here used to come back as "not a valid secutg://key payload"
            // — true, and no help at all in finding the dialog that does want it.
            presentWrongImportDialog(
                controller: controller,
                title: SecutgL10n.string("SecutgImportKeyringTitle"),
                message: SecutgL10n.string("SecutgImportWrongDialogK1"),
                action: (SecutgL10n.string("SecutgImportWrongDialogOpenKeyring"), { [weak controller] in
                    guard let controller else { return }
                    // carrying the paste across means nobody has to find the file and paste it twice
                    SecutgTransfer.presentImport(
                        context: context, controller: controller,
                        pastedBundle: payload.trimmingCharacters(in: .whitespacesAndNewlines))
                }))
        } else {
            toast(controller, SecutgL10n.string("SecutgImportFailed"))
        }
    }

    /// Names what the pasted text really is and, when there is somewhere to send the user, offers to
    /// open the dialog that wants it. Shared by both import dialogs so the two read the same way.
    static func presentWrongImportDialog(
        controller: ViewController, title: String, message: String, action: (String, () -> Void)?
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let (label, run) = action {
            alert.addAction(UIAlertAction(title: label, style: .default, handler: { _ in run() }))
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        } else {
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
        }
        presentSystem(alert, over: controller)
    }

    // MARK: helpers

    /// SECUTG: PLAN.md 3.17 point 3 — a key has just landed, so the messages that arrived before it can be opened
    /// now. The decrypt hook runs once, when a message is stored, and Postbox never runs it again; the ciphertext
    /// was kept for exactly this moment. `peerIds` nil sweeps every chat, which is what a transferred keyring needs.
    ///
    /// `completion` always runs, on the main queue, carrying the line to say so or nil when nothing opened. Callers
    /// fold it into the message they were going to show anyway rather than stacking a second alert on top of it.
    static func redecrypt(context: AccountContext, peerIds: [PeerId]?, completion: @escaping (String?) -> Void) {
        let _ = (secutgRedecryptChats(postbox: context.account.postbox, accountPeerId: context.account.peerId, peerIds: peerIds)
        |> deliverOnMainQueue).startStandalone(next: { count in
            completion(count > 0 ? SecutgL10n.string("SecutgRedecrypted", ["count": "\(count)"]) : nil)
        })
    }

    /// `line` appended under `text` when there is one — the "n earlier messages can be read now" tail.
    static func joined(_ text: String, _ line: String?) -> String {
        guard let line else { return text }
        return text + "\n" + line
    }

    /// One ordinary text message through the normal send path. Control messages (R1 / P1) bypass the encrypt
    /// hook by format; any other text (the pairing confirmation) is encrypted by the A1 hook when the chat is encrypted.
    static func sendText(context: AccountContext, peerId: PeerId, text: String) {
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
            .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []),
        ]).startStandalone()
    }

    /// PLAN.md 3.31.3: unpair, and then tell the peer to destroy their copy of the key too.
    ///
    /// One function because every unpair path on this client has to behave the same way and there is more than
    /// one of them — the lock menu's entry, which the onboarding card's 〔撤回邀请〕 also runs, and the
    /// safety-code mismatch dialog. Neither call site's own signature has to change to reach a send.
    ///
    /// The order is the design, not an accident: `runtime.unpair` has already destroyed this device's copy by
    /// the time there is anything to send, and if the send fails nothing is retried or queued — the security
    /// property is local and is satisfied the moment the keys are gone, and the notice is hygiene on top of it.
    /// It comes back nil when this chat had no pairing (nobody it would be about) or there was no identity to
    /// sign with, and then this sends nothing at all.
    static func unpairAndNotify(context: AccountContext, peerId: PeerId, runtime: SecutgAccountRuntime) {
        guard let notice = runtime.unpair(chatPeerId: peerId) else { return }
        sendText(context: context, peerId: peerId, text: notice)
    }

    static func presentSystem(_ alertController: UIAlertController, over controller: ViewController) {
        // SECUTG-HOOK (fix, 2026-10-01 真机): right after a pushed screen (the QR scanner) is popped, the chat's view is
        // not back in the window yet; presenting then is silently dropped by UIKit. Wait until it is (≤ 2 s).
        whenInWindow(controller, attempts: 20) {
            // SECUTG-HOOK (fix, 2026-10-02 真机, PLAN.md 3.37.1): a modal on the window root sits above the passcode
            // lock — `SecutgAppLock` holds it back until the app is unlocked.
            SecutgAppLock.presentModal(alertController, from: { [weak controller] in
                guard let controller else { return nil }
                return controller.view.window?.rootViewController ?? controller
            })
        }
    }

    private static func whenInWindow(_ controller: ViewController, attempts: Int, _ action: @escaping () -> Void) {
        if controller.view.window != nil || attempts <= 0 {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak controller] in
            guard let controller else { return }
            whenInWindow(controller, attempts: attempts - 1, action)
        }
    }

    /// Same, anchored on any view in the window (used by the group-invite card inside a message bubble).
    static func presentSystem(_ alertController: UIAlertController, from view: UIView) {
        // SECUTG-HOOK (fix, 2026-10-02, PLAN.md 3.37.1): same lock gate as above.
        SecutgAppLock.presentModal(alertController, from: { [weak view] in view?.window?.rootViewController })
    }

    private static func alert(_ controller: ViewController, title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
        presentSystem(a, over: controller)
    }

    static func toast(_ controller: ViewController, _ text: String) {
        alert(controller, title: "Si4Gram", message: text) // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
    }
}
