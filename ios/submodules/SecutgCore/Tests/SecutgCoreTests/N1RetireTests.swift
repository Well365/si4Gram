import XCTest
@testable import SecutgCore

/// `N1` at the wire level (PLAN.md 3.34.3), ported from Web A's `N1 on the wire` block.
///
/// The format is a cross-client contract: the signature covers the UTF-8 bytes of
/// `N1:<chat_id>:<user_id>:<at>:<mode>:<old_admin_pk>:<new_admin_pk>` exactly, with both keys in the same
/// base64url spelling they are sent in. A port that signs anything else produces notices no other client can
/// verify, and the failure looks like a forgery rather than like a bug.
final class N1FormatTests: XCTestCase {
    let group = "-1001234567890"
    let admin = "7001"
    let at: Int64 = 1_789_300_000

    var signer: KeyRing.Identity!
    var oldPk: [UInt8]!
    var newPk: [UInt8]!

    override func setUpWithError() throws {
        signer = try Rekey.generateIdentity()
        oldPk = try Rekey.generateIdentity().ed25519Pk
        newPk = try Rekey.generateIdentity().ed25519Pk
    }

    func notice(mode: Rekey.KeyMode = .auto, old: [UInt8]?? = nil, chatId: String? = nil) throws -> String {
        return try Rekey.buildN1(chatId: chatId ?? group, userId: admin, at: at, mode: mode,
                                 oldAdminPk: old ?? oldPk, newAdminPk: newPk, ed25519Sk: signer.ed25519Sk)
    }

    func testRoundTripsAndTheParseGivesBackExactlyWhatWasPutIn() throws {
        let parsed = try XCTUnwrap(Rekey.parseN1(try notice()))
        XCTAssertEqual(parsed.chatId, group)
        XCTAssertEqual(parsed.userId, admin)
        XCTAssertEqual(parsed.at, at)
        XCTAssertEqual(parsed.mode, .auto)
        XCTAssertEqual(parsed.oldAdminPk, oldPk)
        XCTAssertEqual(parsed.newAdminPk, newPk)
        // Every port must sign this exact string, byte for byte, or the five clients cannot read each other
        XCTAssertEqual(parsed.signedText,
                       "N1:\(group):\(admin):\(at):auto:\(Base64Url.encode(oldPk)):\(Base64Url.encode(newPk))")
    }

    /// A group's first key names no old key, and the segment is left empty rather than filled with a placeholder
    func testAGroupsFirstKeyLeavesTheOldKeyEmptyAndThatParsesAsAbsent() throws {
        let wire = try notice(mode: .manual, old: .some(nil))
        XCTAssertTrue(wire.contains(":manual::"))
        let parsed = try XCTUnwrap(Rekey.parseN1(wire))
        XCTAssertNil(parsed.oldAdminPk)
        XCTAssertEqual(parsed.newAdminPk, newPk)
    }

    /// The key being announced is not the key that signed: a member reading this has no reason to trust
    /// `newAdminPk` yet, which is the whole reason the identity key signs (3.34.3).
    func testTheSignatureVerifiesUnderTheSendersIdentityKeyNotTheNewAdminKey() throws {
        let parsed = try XCTUnwrap(Rekey.parseN1(try notice()))
        XCTAssertTrue(Rekey.verifyN1Signature(parsed, ed25519Pk: signer.ed25519Pk))
        XCTAssertFalse(Rekey.verifyN1Signature(parsed, ed25519Pk: newPk))
    }

    func testEverySegmentIsCoveredByTheSignature() throws {
        let parts = try notice().components(separatedBy: ":")
        let tampered: [String: [String]] = [
            "chatId": ["N1", "-1009999999999", parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]],
            "userId": ["N1", parts[1], "7002", parts[3], parts[4], parts[5], parts[6], parts[7]],
            "at": ["N1", parts[1], parts[2], String(at + 1), parts[4], parts[5], parts[6], parts[7]],
            "mode": ["N1", parts[1], parts[2], parts[3], "manual", parts[5], parts[6], parts[7]],
            "oldAdminPk": ["N1", parts[1], parts[2], parts[3], parts[4], Base64Url.encode(newPk), parts[6], parts[7]],
            "newAdminPk": ["N1", parts[1], parts[2], parts[3], parts[4], parts[5], Base64Url.encode(oldPk), parts[7]],
        ]
        for (field, segments) in tampered {
            let parsed = try XCTUnwrap(Rekey.parseN1(segments.joined(separator: ":")), "\(field) should still parse")
            XCTAssertFalse(Rekey.verifyN1Signature(parsed, ed25519Pk: signer.ed25519Pk),
                           "\(field) must break the signature")
        }
    }

    /// Without this the notice is dropped one layer earlier and shows up in the chat as a line of raw text
    func testTheInboundGateLetsItThrough() throws {
        let wire = try notice()
        XCTAssertTrue(Rekey.isN1(wire))
        XCTAssertTrue(Rekey.isControlMessage(wire))
    }

    func testIsNotConfusedWithTheOtherControlMessages() {
        XCTAssertFalse(Rekey.isN1("U1:7001:1789300000:AAAA"))
        XCTAssertFalse(Rekey.isN1("P1:1:a:b:c"))
        XCTAssertFalse(Rekey.isN1("R1:rotate:0123456789abcdef.20260911:cGF5:c2ln"))
    }

    func testRejectsAnythingMalformedRatherThanGuessingAtIt() throws {
        let parts = try notice().components(separatedBy: ":")
        let good = parts.joined(separator: ":")
        let cases: [String: String] = [
            "unknown mode": ["N1", group, admin, String(at), "sometimes", parts[5], parts[6], parts[7]].joined(separator: ":"),
            "empty mode": ["N1", group, admin, String(at), "", parts[5], parts[6], parts[7]].joined(separator: ":"),
            "empty new key": ["N1", group, admin, String(at), "auto", parts[5], "", parts[7]].joined(separator: ":"),
            "missing signature": parts.dropLast().joined(separator: ":"),
            "extra segment": good + ":extra",
            "chat id not numeric": ["N1", "group", admin, String(at), "auto", parts[5], parts[6], parts[7]].joined(separator: ":"),
            "user id not numeric": ["N1", group, "notdigits", String(at), "auto", parts[5], parts[6], parts[7]].joined(separator: ":"),
        ]
        for (name, text) in cases {
            XCTAssertNil(Rekey.parseN1(text), name)
            XCTAssertFalse(Rekey.isN1(text), name)
        }
        // Wrong-length keys and signatures are shaped right, so the regex admits them; the parser does not.
        let shortPk = Base64Url.encode([UInt8](repeating: 0, count: 16))
        XCTAssertNil(Rekey.parseN1(["N1", group, admin, String(at), "auto", parts[5], shortPk, parts[7]].joined(separator: ":")))
        XCTAssertNil(Rekey.parseN1((parts.dropLast() + [Base64Url.encode([UInt8](repeating: 0, count: 32))]).joined(separator: ":")))
    }

    /// `\d{1,20}` admits more than Web A can hold exactly, and "what counts as malformed" is part of the
    /// contract, so this port refuses the same range its JavaScript twin does instead of accepting quietly.
    /// The gate is deliberately the looser of the two, and that is the safe direction: the processor sees the
    /// message and says "malformed" rather than letting wire text through as if a person had typed it.
    func testTheGateIsLooserThanTheParserAndThatIsTheSafeDirection() throws {
        let parts = try notice().components(separatedBy: ":")
        let tooBig = ["N1", group, admin, "99999999999999999999", "auto", parts[5], parts[6], parts[7]]
            .joined(separator: ":")
        XCTAssertTrue(Rekey.isN1(tooBig))
        XCTAssertTrue(Rekey.isControlMessage(tooBig))
        XCTAssertNil(Rekey.parseN1(tooBig))
        XCTAssertNil(Rekey.parseN1(["N1", group, admin, "9007199254740992", "auto", parts[5], parts[6], parts[7]]
            .joined(separator: ":")))
    }

    /// Groups are negative and that is what this is for, but the parser is not the place to enforce it: the
    /// processor refuses a notice whose chat is not a group, and says so with a reason.
    func testAPrivateChatIdIsAValidChatIdTooTheFormatDoesNotDecideWhereItIsMeaningful() throws {
        XCTAssertNotNil(Rekey.parseN1(try notice(chatId: "7002")))
    }
}

/// `N1` applied: the group's key has been retired (PLAN.md 3.34.3 / 3.34.4), ported from Web A.
///
/// The three checks are the whole security of this feature: a notice acted on without them is a way for anyone
/// in a group to take everybody's key away. The action has its own hazard, which 3.34.5 calls a red line and
/// which the last block here pins: retiring UNBINDS the old master, it never destroys it, because destroying it
/// would take the group's history with it.
final class N1AppliedTests: XCTestCase {
    let group = "-1001234567890"
    /// The Telegram admin doing the retiring
    let admin = "7001"
    /// This device
    let member = "7002"
    let outsider = "7003"
    let now: Int64 = 1_789_300_000

    var ring: KeyRing!
    var processor: RekeyProcessor!
    var adminIdentity: KeyRing.Identity!
    var oldAdminPk: [UInt8]!
    var newAdminPk: [UInt8]!
    var masterId: String!

    /// A member who holds the group's key, trusts `oldAdminPk`, and has the admin's `P1` on file.
    override func setUpWithError() throws {
        ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        processor = RekeyProcessor(ring: ring, clock: { self.now * 1000 })
        adminIdentity = try Rekey.generateIdentity()
        oldAdminPk = try Rekey.generateIdentity().ed25519Pk
        newAdminPk = try Rekey.generateIdentity().ed25519Pk

        masterId = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: masterId, label: nil)
        try ring.setChatAdminPk(chatId: group, oldAdminPk)
        ring.setChatEncryption(chatId: group, enabled: true)
        // How the admin's identity key gets on file in real life: their `P1` arrived in the group.
        _ = processor.handle(text: try Rekey.buildP1(userId: admin, x25519Pk: adminIdentity.x25519Pk,
                                                     ed25519Pk: adminIdentity.ed25519Pk,
                                                     ed25519Sk: adminIdentity.ed25519Sk),
                             chatId: group, senderId: admin, ownUserId: member, messageDate: now)
    }

    /// PLAN.md 3.35.5.2: rules 2 and 3 are MANUAL-mode rules now. In auto mode the notice unbinds, renders and
    /// stops, so a default of `.auto` here would exercise a road that no longer runs. The auto-mode behaviour
    /// has its own class, `N1AutoModeTests`.
    func notice(userId: String? = nil, mode: Rekey.KeyMode = .manual, old: [UInt8]?? = nil,
                new: [UInt8]? = nil, signer: [UInt8]? = nil, chatId: String? = nil,
                at: Int64? = nil) throws -> String {
        return try Rekey.buildN1(chatId: chatId ?? group, userId: userId ?? admin, at: at ?? now, mode: mode,
                                 oldAdminPk: old ?? oldAdminPk, newAdminPk: new ?? newAdminPk,
                                 ed25519Sk: signer ?? adminIdentity.ed25519Sk)
    }

    func handle(_ wire: String, senderId: String? = nil, isSenderGroupAdmin: Bool? = true,
                chatId: String? = nil) -> RekeyProcessor.Result? {
        return processor.handle(text: wire, chatId: chatId ?? group, senderId: senderId ?? admin,
                                ownUserId: member, isSenderGroupAdmin: isSenderGroupAdmin)
    }

    // MARK: the three checks (PLAN.md 3.34.3)

    func testANoticeThatPassesAllThreeIsActedOnAndReportsTheMode() throws {
        let result = handle(try notice(mode: .manual))
        XCTAssertEqual(result?.isRetire, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertNil(result?.reason)
        XCTAssertEqual(result?.mode, .manual)
        XCTAssertEqual(result?.userId, admin)
    }

    func testRule1AMemberWhoIsNotATelegramAdminCannotRetireTheKey() throws {
        let result = handle(try notice(userId: outsider), senderId: outsider, isSenderGroupAdmin: false)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "not_admin")
        XCTAssertEqual(ring.chatMasterId(group), masterId)
        XCTAssertEqual(ring.chatAdminPk(group), oldAdminPk)
    }

    /// The distinction this pins: nil is a question we cannot answer yet, and answering it "no" would silently
    /// drop notices that arrive before the member list does — which is every notice after a long offline
    /// stretch, because the history always arrives first.
    func testRule1TheAdminListNotHavingLoadedParksTheNoticeItDoesNotRefuseIt() throws {
        let wire = try notice()
        let parked = handle(wire, isSenderGroupAdmin: nil)
        XCTAssertEqual(parked?.ok, false)
        XCTAssertEqual(parked?.reason, "pending")
        XCTAssertEqual(parked?.mode, .manual)
        XCTAssertEqual(ring.chatMasterId(group), masterId)
        // And the very same notice applies once the answer arrives.
        XCTAssertEqual(handle(wire)?.ok, true)
    }

    func testRule2AValidSignatureByTheWrongPersonIsRefused() throws {
        let impostor = try Rekey.generateIdentity()
        let result = handle(try notice(signer: impostor.ed25519Sk))
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "bad_signature")
        XCTAssertEqual(ring.chatAdminPk(group), oldAdminPk)
    }

    /// Nobody trusts the new admin key yet — that is the very thing the notice is asking them to start doing
    func testRule2SignedByTheNewAdminKeyIsRefused() throws {
        let incoming = try Rekey.generateIdentity()
        let result = handle(try notice(new: incoming.ed25519Pk, signer: incoming.ed25519Sk))
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "bad_signature")
    }

    /// PLAN.md 3.34.3 rule 2 as amended 2026-09-19: history is read newest-first, so the notice is met before
    /// the `P1` that vouches for it — the admin's button posts one immediately before every notice. Refusing it
    /// for good would let the order of a history page decide whether a member ever pairs, which on two real
    /// phones it did.
    func testRule2AnAdminWhoseP1ThisDeviceNeverSawIsWaitedForNotRefused() throws {
        let stranger = try Rekey.generateIdentity()
        let parked = try notice(userId: outsider, signer: stranger.ed25519Sk)
        let told = handle(parked, senderId: outsider)
        XCTAssertEqual(told?.ok, false)
        XCTAssertEqual(told?.reason, "pending")
        XCTAssertEqual(processor.parkedNoticeCount(chatId: group), 1)
        XCTAssertEqual(ring.chatAdminPk(group), oldAdminPk)

        // Their `P1` arrives next, and the same notice — re-read from its own row — is judged as itself.
        _ = processor.handle(text: try Rekey.buildP1(userId: outsider, x25519Pk: stranger.x25519Pk,
                                                     ed25519Pk: stranger.ed25519Pk,
                                                     ed25519Sk: stranger.ed25519Sk),
                             chatId: group, senderId: outsider, ownUserId: member, messageDate: now)
        XCTAssertEqual(handle(parked, senderId: outsider)?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(processor.parkedNoticeCount(chatId: group), 0)
    }

    func testRule3ReplayingAnAppliedNoticeDoesNothingTheSecondTime() throws {
        let wire = try notice()
        XCTAssertEqual(handle(wire)?.ok, true)
        XCTAssertNil(ring.chatMasterId(group))
        // The second reading is inert. What it reports is `already_applied` rather than `stale` — see
        // `testRule3ANoticeThisDeviceAlreadyObeyedSaysSoRatherThanStale` for why that distinction is worth
        // making — but either way nothing here moves, and the device goes on trusting the announced key.
        XCTAssertNotNil(handle(wire))
        XCTAssertNil(ring.chatMasterId(group))
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
    }

    /// PLAN.md 3.34.3: the notice this device already obeyed, read a second time. It is the only notice that
    /// names the key the device trusts *right now*, so it is distinguishable from a replay of an older one —
    /// and "ignored: stale" would be the wrong last word on a notice that was in fact carried out. This client
    /// re-derives every control line at draw time, so that wrong word is what the member keeps seeing.
    func testRule3ANoticeThisDeviceAlreadyObeyedSaysSoRatherThanStale() throws {
        let wire = try notice()
        XCTAssertEqual(handle(wire)?.ok, true)
        let again = handle(wire)
        XCTAssertEqual(again?.ok, true)
        XCTAssertEqual(again?.reason, "already_applied")
        XCTAssertEqual(again?.mode, .manual)
        XCTAssertEqual(again?.userId, admin)
    }

    /// Reported, never re-applied: everything it asks for has already happened, and doing it again would unbind
    /// a master the member imported in the meantime.
    func testAnAlreadyAppliedNoticeChangesNothingInTheRing() throws {
        let wire = try notice()
        XCTAssertEqual(handle(wire)?.ok, true)
        // The member has since scanned the replacement, so the chat holds a master again.
        let replacement = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: replacement, label: nil)

        XCTAssertEqual(handle(wire)?.reason, "already_applied")
        XCTAssertEqual(ring.chatMasterId(group), replacement)
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertTrue(ring.isChatEncrypted(group))
    }

    /// A replay of an OLDER notice still falls through to `stale` — the distinction is exactly "does it name
    /// the key this device trusts now", and an older one cannot.
    func testAReplayOfAnOlderNoticeIsStillStale() throws {
        let older = try Rekey.generateIdentity().ed25519Pk
        let firstRound = try notice(new: older)
        XCTAssertEqual(handle(firstRound)?.ok, true)
        // Now a second rebuild moves the device on to `newAdminPk`.
        XCTAssertEqual(handle(try notice(old: .some(older)))?.ok, true)
        let replay = handle(firstRound)
        XCTAssertEqual(replay?.ok, false)
        XCTAssertEqual(replay?.reason, "stale")
    }

    /// 2026-09-19, the user's rule: 「自动匹配环节不应该受到原来的密钥的影响」. A rebuild is a new request,
    /// whatever this device held before. The member who missed a generation, the member who never had a key,
    /// the admin who started over were all refused as `stale`, and none of them could ever auto-pair. What
    /// stays refused is a notice OLDER than the last one obeyed: the real replay.
    func testRule3ANoticeNamingAKeyThisDeviceNeverTrustedStillAppliesItIsNewer() throws {
        let other = try Rekey.generateIdentity().ed25519Pk
        XCTAssertEqual(handle(try notice(old: .some(other)))?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(ring.chatNoticeAt(group), now)
    }

    /// Trusts A. The admin rebuilt twice while this device was away: A→B was never read, B→C arrives. It names
    /// B, which this device never trusted, and is newer than anything it has obeyed.
    func testRule3AMemberWhoMissedAGenerationCatchesUpOnTheNextNotice() throws {
        let b = try Rekey.generateIdentity().ed25519Pk
        let c = try Rekey.generateIdentity().ed25519Pk
        XCTAssertEqual(handle(try notice(old: .some(b), new: c, at: now + 60))?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), c)
        XCTAssertNil(ring.chatMasterId(group))
        // 3.34.5 still holds: unbound, never destroyed.
        XCTAssertTrue(ring.listMasterIds().contains(masterId))
    }

    /// An admin who reinstalled has no old key left to name, and members who hold one must still obey.
    func testRule3AnAdminWhoStartedOverIsObeyedByMembersWhoHoldAKey() throws {
        XCTAssertEqual(handle(try notice(old: .some(nil), at: now + 5))?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(ring.chatNoticeAt(group), now + 5)
    }

    /// THE ANCHOR: history newest-first means the device reads the current rebuild, then scrolls into an older
    /// one. That older one is the replay, and obeying it would unbind the key the member holds right now.
    func testRule3AnOlderNoticeMetAfterANewerOneIsTheReplayAndIsRefused() throws {
        let b = try Rekey.generateIdentity().ed25519Pk
        let newest = try notice(old: .some(b), new: newAdminPk, at: now + 100)
        let older = try notice(old: .some(oldAdminPk), new: b, at: now + 50)
        XCTAssertEqual(handle(newest)?.ok, true)
        let replay = handle(older)
        XCTAssertEqual(replay?.ok, false)
        XCTAssertEqual(replay?.reason, "stale")
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(ring.chatNoticeAt(group), now + 100)
    }

    /// Two admins co-hold with skewed clocks: a notice that retires exactly the key this device trusts is the
    /// continuation of the chain and is never refused for being "earlier" than an unrelated anchor.
    func testRule3TheChainNeedsNoClock() throws {
        ring.setChatNoticeAt(chatId: group, now + 1000)
        XCTAssertEqual(handle(try notice(at: now))?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        // And the anchor never moves backwards.
        XCTAssertEqual(ring.chatNoticeAt(group), now + 1000)
    }

    /// Two co-holders rebuilding from the same key: whichever order a member meets the two notices in, it ends
    /// on the later one.
    func testRule3TwoCoHoldersRebuildingConvergeOnTheLaterNotice() throws {
        let b = try Rekey.generateIdentity().ed25519Pk
        let c = try Rekey.generateIdentity().ed25519Pk
        let fromX = try notice(new: b, at: now + 10)
        let fromY = try notice(new: c, at: now + 20)
        XCTAssertEqual(handle(fromX)?.ok, true)
        XCTAssertEqual(handle(fromY)?.ok, true)
        XCTAssertEqual(ring.chatAdminPk(group), c)
        // The other order: X's is older now, and is refused — the same end state.
        XCTAssertEqual(handle(fromX)?.reason, "stale")
        XCTAssertEqual(ring.chatAdminPk(group), c)
    }

    /// A group's FIRST key names no old key, and applies on a device that trusts nothing
    func testRule3TheFirstKeyAppliesOnADeviceThatTrustsNothing() throws {
        let fresh = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try fresh.setIdentity(try Rekey.generateIdentity())
        let freshProcessor = RekeyProcessor(ring: fresh, clock: { self.now * 1000 })
        _ = freshProcessor.handle(text: try Rekey.buildP1(userId: admin, x25519Pk: adminIdentity.x25519Pk,
                                                          ed25519Pk: adminIdentity.ed25519Pk,
                                                          ed25519Sk: adminIdentity.ed25519Sk),
                                  chatId: group, senderId: admin, ownUserId: member, messageDate: now)
        let first = try notice(old: .some(nil))
        XCTAssertEqual(freshProcessor.handle(text: first, chatId: group, senderId: admin, ownUserId: member,
                                             isSenderGroupAdmin: true)?.ok, true)
        XCTAssertEqual(fresh.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(fresh.chatNoticeAt(group), now)
    }

    /// The hole `already_applied` left open, found while porting: a member who reached this generation by
    /// SCANNING never obeyed a notice, so it had no anchor — and the next older notice it met in history
    /// passed the freshness test by default and unbound the key it had just fetched.
    func testRule3ANoticeAlreadyCarriedOutSetsTheAnchorSoOlderOnesCannotWalkInBehindIt() throws {
        // A manual-mode member who scanned the code: it trusts the announced key, having obeyed nothing.
        try ring.setChatAdminPk(chatId: group, newAdminPk)
        XCTAssertNil(ring.chatNoticeAt(group))

        let scanned = try notice(at: now + 100)
        let applied = handle(scanned)
        XCTAssertEqual(applied?.ok, true)
        XCTAssertEqual(applied?.reason, "already_applied")
        XCTAssertEqual(ring.chatNoticeAt(group), now + 100)

        // Now the older notice that used to walk straight in is what it is: a replay.
        let older = try notice(old: .some(try Rekey.generateIdentity().ed25519Pk),
                               new: try Rekey.generateIdentity().ed25519Pk, at: now + 50)
        XCTAssertEqual(handle(older)?.reason, "stale")
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
        XCTAssertEqual(ring.chatMasterId(group), masterId)
    }

    /// A device that trusts nothing has no chain to continue, so a notice naming no old key — a group's FIRST
    /// notice, the one anybody can scroll back to and replay — must still prove it is newer than what this
    /// device has already obeyed. Found by the macOS port, reading the branch as written.
    func testRule3TrustingNothingIsNotAChainAFirstKeyNoticeStillFacesTheAnchor() throws {
        let fresh = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try fresh.setIdentity(try Rekey.generateIdentity())
        let freshProcessor = RekeyProcessor(ring: fresh, clock: { self.now * 1000 })
        _ = freshProcessor.handle(text: try Rekey.buildP1(userId: admin, x25519Pk: adminIdentity.x25519Pk,
                                                          ed25519Pk: adminIdentity.ed25519Pk,
                                                          ed25519Sk: adminIdentity.ed25519Sk),
                                  chatId: group, senderId: admin, ownUserId: member, messageDate: now)
        try fresh.setChatNoticeAt(chatId: group, now + 100)

        let older = try notice(old: .some(nil), at: now + 50)
        let refused = freshProcessor.handle(text: older, chatId: group, senderId: admin, ownUserId: member,
                                            isSenderGroupAdmin: true)
        XCTAssertEqual(refused?.ok, false)
        XCTAssertEqual(refused?.reason, "stale")
        XCTAssertNil(fresh.chatAdminPk(group))

        // Newer than the anchor, the same notice is a real first key and applies.
        let newer = try notice(old: .some(nil), at: now + 150)
        XCTAssertEqual(freshProcessor.handle(text: newer, chatId: group, senderId: admin, ownUserId: member,
                                             isSenderGroupAdmin: true)?.ok, true)
        XCTAssertEqual(fresh.chatAdminPk(group), newAdminPk)
    }

    func testANoticeCarryingAnotherGroupsIdCannotBeReplayedSideways() throws {
        let result = handle(try notice(chatId: "-1009999999999"))
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "wrong_chat")
        XCTAssertEqual(result?.userId, admin)
        // `wrong_chat` is decided before the notice's own mode means anything about this chat
        XCTAssertNil(result?.mode)
    }

    func testTheSenderNamedMustBeTheTelegramSender() throws {
        let result = handle(try notice(), senderId: outsider)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "sender_mismatch")
    }

    func testOurOwnNoticeComingBackIsReportedNotActedOnAgain() throws {
        let own = try notice(userId: member, signer: ring.identity!.ed25519Sk)
        let result = handle(own, senderId: member)
        XCTAssertEqual(result?.isRetire, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.reason, "own_echo")
        XCTAssertEqual(ring.chatMasterId(group), masterId)
    }

    /// A private chat has no admin list, so it is not a place for this
    func testAPrivateChatIsRefusedWithAReason() throws {
        let wire = try notice(userId: admin, chatId: admin)
        let result = processor.handle(text: wire, chatId: admin, senderId: admin, ownUserId: member,
                                      isSenderGroupAdmin: true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "not_group")
    }

    func testAMalformedNoticeIsReportedRatherThanLeakedIntoTheChat() {
        let result = handle("N1:\(group):\(admin):99999999999999999999:auto::AAAA:AAAA")
        XCTAssertEqual(result?.isRetire, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "malformed")
    }

    // MARK: what retiring does (PLAN.md 3.34.4, red line 3.34.5)

    /// THE RED LINE (PLAN.md 3.34.5): the old master is unbound, never destroyed — history still opens.
    ///
    /// Local plaintext is NOT what makes this work: 3.19 is off by default and the people who turn it on hold
    /// ciphertext only. Destroying here would take the group's history with it, and an `N1` can be replayed,
    /// which would make one sentence enough to erase it. The private-chat unpair (3.31) destroys on purpose;
    /// these two pieces of code must never be made to look alike.
    func testTheRedLineTheOldMasterIsUnboundNeverDestroyed() throws {
        let key = try XCTUnwrap(ring.currentKey(chatId: group))
        let before = try E1Codec.encrypt(text: "said under the old key", entities: nil, keyId: key.keyId,
                                         sessionKey: key.sessionKey)
        XCTAssertTrue(E1Codec.decrypt(wire: before, lookup: { self.ring.lookupSessionKey($0) }).ok)

        XCTAssertEqual(handle(try notice())?.ok, true)

        // Unbound: this chat has no master any more.
        XCTAssertNil(ring.chatMasterId(group))
        // Not destroyed: the master is still in the ring, so everything already on this device opens.
        XCTAssertTrue(ring.listMasterIds().contains(masterId))
        XCTAssertTrue(E1Codec.decrypt(wire: before, lookup: { self.ring.lookupSessionKey($0) }).ok)
    }

    func testTheDeviceSwitchesToTrustingTheKeyTheNoticeNames() throws {
        _ = handle(try notice())
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
    }

    /// No master and encryption still on means this chat cannot send — which is exactly right: the member
    /// neither keeps sending under the retired key nor silently falls back to plain text.
    func testEncryptionStaysOnWithNoMaster() throws {
        _ = handle(try notice())
        XCTAssertTrue(ring.isChatEncrypted(group))
        XCTAssertNil(ring.currentKey(chatId: group))
    }

    /// PLAN.md 3.34.1: the notice carries the mode, and it has to be written back AFTER the unbind — unbinding
    /// clears this chat's provenance, and the old mode goes with it.
    func testTheModeTheNoticeCarriesIsWhatTheChatIsLeftWith() throws {
        // PLAN.md 3.35.5.2: this is a MANUAL-mode property of `N1` now. An auto-mode notice records nothing —
        // the mode arrives inside the `G2` payload, with the key it describes.
        ring.setChatKeyMode(chatId: group, .auto)
        _ = handle(try notice(mode: .manual))
        XCTAssertEqual(ring.chatKeyMode(group), .manual)
    }

    // MARK: the welcome that overtakes its notice (PLAN.md 3.34.7 item 4)

    /// A `R1 welcome` sealed to this device, carrying `master`, signed with `signer`.
    private func welcome(master: [UInt8], signer: [UInt8]) throws -> String {
        return try Rekey.buildWelcome(currentMaster: master, newcomerX25519Pk: ring.identity!.x25519Pk,
                                      adminSk: signer, nowMs: now * 1000, epochDays: 1).wire
    }

    /// The failure two phones showed on 2026-09-19: the notice parks (no admin list yet), the welcome sent one
    /// second later cannot be verified — it is signed with the key the notice is announcing, which this device
    /// does not trust yet — and it used to be refused for good. By the time the notice applied, the key it had
    /// announced was already gone and the admin's ledger would not send a second copy. Now the welcome waits
    /// with the notice and is judged in full the moment it applies.
    func testAWelcomeThatOvertakesItsNoticeIsParkedAndAppliedOnceTheNoticeIs() throws {
        let newAdmin = try Rekey.generateIdentity()
        let wire = try notice(new: newAdmin.ed25519Pk)
        XCTAssertEqual(handle(wire, isSenderGroupAdmin: nil)?.reason, "pending")

        let replacement = KeyDerivation.generateMasterKey()
        let sealed = try welcome(master: replacement, signer: newAdmin.ed25519Sk)
        // Signed by a key this device does not trust yet, with a notice waiting: parked, not refused.
        let told = handle(sealed)
        XCTAssertEqual(told?.ok, false)
        XCTAssertEqual(told?.reason, "pending")
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 1)
        XCTAssertEqual(ring.chatMasterId(group), masterId)

        // The list arrives and the notice is judged again — the receive hook re-runs it from the row's own wire.
        XCTAssertEqual(handle(wire)?.ok, true)
        // The parked welcome was judged in full against the key the notice announced, and applied.
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 0)
        let bound = try XCTUnwrap(ring.chatMasterId(group))
        XCTAssertNotEqual(bound, masterId)
        XCTAssertEqual(bound, try KeyDerivation.computeMasterId(replacement))
        // 3.34.5: the retired master is unbound, never destroyed.
        XCTAssertTrue(ring.listMasterIds().contains(masterId))
    }

    /// The retry is the whole road again, signature included — a parked forgery must not become an applied one.
    /// Parking an unverified `R1` and applying it verified is the one way this rule could be got wrong.
    func testAForgedWelcomeParkedBeforeTheNoticeIsStillRefusedAfterIt() throws {
        let wire = try notice()
        XCTAssertEqual(handle(wire, isSenderGroupAdmin: nil)?.reason, "pending")

        let forged = try welcome(master: KeyDerivation.generateMasterKey(),
                                 signer: try Rekey.generateIdentity().ed25519Sk)
        XCTAssertEqual(handle(forged)?.reason, "pending")
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 1)

        XCTAssertEqual(handle(wire)?.ok, true)
        // Refused on the retry, and not parked a second time — the row can say `bad_signature` out loud now.
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 0)
        XCTAssertNil(ring.chatMasterId(group))
        XCTAssertEqual(ring.chatAdminPk(group), newAdminPk)
    }

    /// Found by the macOS port, on Web: `retirePending` there empties the notice queue before it judges, so the
    /// "no notice waiting" half of the parking rule already stops a failed retry from parking again — removing
    /// the `isRetry` guard left every test green. The state that reaches the guard is one where a notice is
    /// STILL waiting while another applies.
    ///
    /// This client unparks a notice only after its verdict is in, so the guard is reachable more easily here —
    /// but the case is worth pinning in the shape the other four clients share: a second notice parked
    /// throughout, so "a notice is waiting" is true independently of when the first one is forgotten.
    func testARetryThatFailsIsNotParkedAgainEvenWithAnotherNoticeStillWaiting() throws {
        let first = try notice()
        let second = try notice(new: try Rekey.generateIdentity().ed25519Pk)
        XCTAssertEqual(handle(first, isSenderGroupAdmin: nil)?.reason, "pending")
        XCTAssertEqual(handle(second, isSenderGroupAdmin: nil)?.reason, "pending")
        XCTAssertEqual(processor.parkedNoticeCount(chatId: group), 2)

        let forged = try welcome(master: KeyDerivation.generateMasterKey(),
                                 signer: try Rekey.generateIdentity().ed25519Sk)
        XCTAssertEqual(handle(forged)?.reason, "pending")

        // The first notice arrives again with the answer attached and applies directly. The second copy is
        // still parked, so "a notice is waiting in this chat" stays true right through the retry — and the
        // retry must refuse the forgery anyway rather than park it for a third reading.
        XCTAssertEqual(handle(first)?.ok, true)
        XCTAssertEqual(processor.parkedNoticeCount(chatId: group), 1)
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 0)
        XCTAssertNil(ring.chatMasterId(group))
    }

    /// The narrow half of the rule: with no notice waiting, a signature that fails against the key this device
    /// DOES trust is a forgery or a stale key, and is refused the moment it arrives.
    func testAWelcomeWithNoNoticeWaitingIsStillRefusedOnTheSpot() throws {
        XCTAssertEqual(processor.parkedNoticeCount(chatId: group), 0)
        let forged = try welcome(master: KeyDerivation.generateMasterKey(),
                                 signer: try Rekey.generateIdentity().ed25519Sk)
        XCTAssertEqual(handle(forged)?.reason, "bad_signature")
        XCTAssertEqual(processor.parkedRekeyCount(chatId: group), 0)
    }

    func testEveryRefusalLeavesTheKeyringExactlyAsItWas() throws {
        let impostor = try Rekey.generateIdentity()
        // A notice older than the one already obeyed is the replay; the anchor is set so that it is refused.
        ring.setChatNoticeAt(chatId: group, now + 1)
        let refusals = [
            try notice(signer: impostor.ed25519Sk),
            try notice(old: .some(try Rekey.generateIdentity().ed25519Pk), at: now),
            try notice(chatId: "-1009999999999"),
        ]
        for wire in refusals {
            XCTAssertEqual(handle(wire)?.ok, false)
            XCTAssertEqual(ring.chatMasterId(group), masterId)
            XCTAssertEqual(ring.chatAdminPk(group), oldAdminPk)
            XCTAssertTrue(ring.isChatEncrypted(group))
        }
    }
}
