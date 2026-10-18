import XCTest
@testable import SecutgCore

/// PLAN.md 3.14. Ports every case of Web A's `src/secutg/transfer/transfer.test.ts`, plus a bundle produced by the
/// Web implementation so the cross-client wire format is checked against a real other-client file.
final class TransferTests: XCTestCase {
    let now: Int64 = 1_789_214_400_000   // 2026-09-13 12:00 UTC, in ms
    var nowSeconds: Int64 { return now / 1000 }
    let group = "-1001234567890"
    let peer = "901"

    func ring() -> KeyRing {
        return KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now }, epochDays: 1, epochTolerance: 1)
    }

    func bundle(_ snapshot: KeyRing.Snapshot, code: String, scope: TransferScope = .all) throws -> String {
        return try TransferBundle.build(
            TransferPayload(scope: scope, createdAt: nowSeconds, device: "test", snapshot: snapshot), code: code)
    }

    // MARK: transfer code

    func testGeneratesCrockfordCodeAndParsesBackToTwentyBytes() {
        let code = TransferCode.generate()
        XCTAssertNotNil(code.range(of: "^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){7}$", options: .regularExpression))
        XCTAssertEqual(TransferCode.parse(code)?.count, TransferCode.codeBytes)
        XCTAssertEqual(TransferCode.parse(code.replacingOccurrences(of: "-", with: "").lowercased()), TransferCode.parse(code))
    }

    func testAcceptsMistypedCharactersAndRejectsWrongLengths() {
        let plain = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        XCTAssertNotNil(TransferCode.parse(plain))
        // I / L read as 1, O as 0, U as V
        let mistyped = plain.replacingOccurrences(of: "1", with: "I").replacingOccurrences(of: "0", with: "O")
        XCTAssertEqual(TransferCode.parse(mistyped), TransferCode.parse(plain))
        XCTAssertEqual(TransferCode.parse(TransferCode.format(plain)), TransferCode.parse(plain))
        XCTAssertEqual(TransferCode.format(plain), "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ")
        XCTAssertNil(TransferCode.parse(String(plain.dropLast())))
        XCTAssertNil(TransferCode.parse(plain + "0"))
        XCTAssertNil(TransferCode.parse(""))
    }

    // MARK: transfer bundle

    func testRoundTripsASnapshotByteArraysIncluded() throws {
        let source = ring()
        let identity = try Rekey.generateIdentity()
        try source.setIdentity(identity)
        let masterId = try source.addMaster(KeyDerivation.generateMasterKey())
        try source.setChatMaster(chatId: group, masterId: masterId, label: "20260913")
        source.setChatEncryption(chatId: group, enabled: true)
        try source.setChatAdminPk(chatId: group, identity.ed25519Pk)
        try source.setMemberPk(chatId: group, userId: peer, identity.x25519Pk)
        try source.setMemberEdPk(chatId: group, userId: peer, identity.ed25519Pk)

        let code = TransferCode.generate()
        let text = try bundle(source.exportSnapshot(), code: code)
        XCTAssertTrue(TransferBundle.isTransferBundle(text))
        XCTAssertTrue(text.hasPrefix("K1:1:"))
        // the container leaks nothing in the clear
        XCTAssertFalse(text.contains(masterId))

        let opened = try XCTUnwrap(TransferBundle.open(text, code: code))
        XCTAssertEqual(opened.scope, .all)
        XCTAssertEqual(opened.snapshot.masters[masterId], source.masterKey(for: masterId))
        XCTAssertEqual(opened.snapshot.identityEd25519Sk, identity.ed25519Sk)
        XCTAssertEqual(opened.snapshot.memberPks[group]?[peer], identity.x25519Pk)
        XCTAssertEqual(opened.snapshot.memberEdPks[group]?[peer], identity.ed25519Pk)

        let summary = TransferBundle.summarize(opened, nowSeconds: nowSeconds)
        XCTAssertEqual(summary.scope, .all)
        XCTAssertEqual(summary.masterCount, 1)
        XCTAssertEqual(summary.chatCount, 1)
        XCTAssertTrue(summary.hasIdentity)
        XCTAssertFalse(summary.isStale)
        XCTAssertEqual(summary.device, "test")
        XCTAssertTrue(TransferBundle.summarize(opened, nowSeconds: nowSeconds + 8 * 24 * 3600).isStale)
    }

    /// PLAN.md 3.30 item 8: a master lets the holder *read* a group, the chat's admin secret lets them rekey it
    /// and remove members from it. "导出全部" has always carried those secrets and the manifest never named that
    /// second power. Pins that the count comes from `chatAdminSks` and not from any of the tables next to it —
    /// counting masters here would read as a manifest line while disclosing nothing.
    func testManifestCountsTheGroupAdminSecretsTheFileHandsOver() throws {
        let readOnly = "-100333"
        let source = ring()
        let code = TransferCode.generate()
        // Through the real container, because the file is the thing that leaves the device
        func manifest(_ snapshot: KeyRing.Snapshot, scope: TransferScope = .all) throws -> TransferSummary {
            let opened = try XCTUnwrap(TransferBundle.open(try bundle(snapshot, code: code, scope: scope), code: code))
            return TransferBundle.summarize(opened, nowSeconds: nowSeconds)
        }

        let masterId = try source.addMaster(KeyDerivation.generateMasterKey())
        try source.setChatMaster(chatId: group, masterId: masterId, label: "20260913")
        try source.setChatMaster(chatId: readOnly, masterId: masterId, label: "20260913")
        // Two chats this device can read, neither of which it can rekey
        XCTAssertEqual(try manifest(source.exportSnapshot()).adminChatCount, 0)

        try source.setChatAdminSk(chatId: group, [UInt8](repeating: 0x07, count: 64))
        try source.setChatAdminSk(chatId: "-100222", [UInt8](repeating: 0x08, count: 64))
        let whole = try manifest(source.exportSnapshot())
        XCTAssertEqual(whole.adminChatCount, 2)
        // The two counts answer different questions and must not be conflated
        XCTAssertEqual(whole.masterCount, 1)
        XCTAssertNotEqual(whole.adminChatCount, whole.masterCount)

        // scope=chat: the manifest describes this file, not this device — a chat whose key this device can
        // only read says so, even while the ring holds two admin secrets for other chats
        let slice = source.exportChatsSnapshot(chatIds: [readOnly], withIdentity: false)
        XCTAssertEqual(try manifest(slice, scope: .chat).adminChatCount, 0)
        XCTAssertEqual(try manifest(source.exportChatsSnapshot(chatIds: [group], withIdentity: false),
                                    scope: .chat).adminChatCount, 1)
    }

    /// PLAN.md 3.25.3/3.25.4: the pairing device fields and `deviceLabels` are part of the keyring, so they have
    /// to survive the K1 wire format too, not just the at-rest `SnapshotCodec` — and the export dialog's
    /// "不包含设备备注" checkbox has to actually remove them from the file, not just from the in-memory snapshot.
    func testDeviceFieldsAndLabelsRoundTripThroughTheWireFormatAndCanBeExcluded() throws {
        let source = ring()
        let identity = try Rekey.generateIdentity()
        try source.setIdentity(identity)
        let ownId = try DeviceIdentity.derive(x25519Pk: identity.x25519Pk).deviceId
        let peerId = "fdc674d049598e02"   // one of the 3.25.7 cross-client vectors (0x01..0x20)
        try source.setChatPairing(chatId: peer, KeyRing.Pairing(
            peerId: peer, state: .paired, verified: true, startedAt: nowSeconds, pairedAt: nowSeconds,
            ownDeviceId: ownId, peerDeviceId: peerId, peerSeenDeviceIds: ["3b824e8358cee308"]))
        try source.setDeviceLabel(deviceId: ownId, label: "我的手机")
        try source.setDeviceLabel(deviceId: peerId, label: "老王的公司电脑")

        let code = TransferCode.generate()
        let included = try XCTUnwrap(TransferBundle.open(try bundle(source.exportSnapshot(), code: code), code: code))
        let pairing = try XCTUnwrap(included.snapshot.chatPairings[peer])
        XCTAssertEqual(pairing.ownDeviceId, ownId)
        XCTAssertEqual(pairing.peerDeviceId, peerId)
        XCTAssertEqual(pairing.peerSeenDeviceIds, ["3b824e8358cee308"])
        XCTAssertEqual(included.snapshot.deviceLabels[ownId]?.label, "我的手机")
        XCTAssertEqual(included.snapshot.deviceLabels[peerId]?.label, "老王的公司电脑")
        XCTAssertTrue(TransferBundle.summarize(included, nowSeconds: nowSeconds).hasDeviceLabels)

        // the checkbox: excluded from export means the device_id fields on the pairing itself still travel
        // (they are needed to make sense of the chat), but the label table is empty and the file says so
        let excluded = try XCTUnwrap(TransferBundle.open(try bundle(source.exportSnapshot(includeDeviceLabels: false), code: code), code: code))
        XCTAssertEqual(excluded.snapshot.chatPairings[peer]?.ownDeviceId, ownId)
        XCTAssertTrue(excluded.snapshot.deviceLabels.isEmpty)
        XCTAssertFalse(TransferBundle.summarize(excluded, nowSeconds: nowSeconds).hasDeviceLabels)
    }

    /// PLAN.md 3.25.4 rule 2, scope=chat: `deviceLabels` is indexed by device, not by chat, so a single-chat
    /// transfer has to filter it — otherwise exporting one conversation quietly hands the other device a list of
    /// every machine this user recognises. Checked through the real `K1` container (not just the in-memory
    /// snapshot), because the file is the thing that actually leaves the device. Mirrors Android
    /// `KeyRingTransferTest` / `TransferBundleTest` and Windows `TestExportScopeDeviceLabels`.
    func testSingleChatExportCarriesOnlyThatChatsDeviceLabelsAndAlwaysThisDevicesOwn() throws {
        let other = "902"
        let source = ring()
        let identity = try Rekey.generateIdentity()
        try source.setIdentity(identity)
        let ownId = try DeviceIdentity.derive(x25519Pk: identity.x25519Pk).deviceId
        let peerA = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x03, count: 32)).deviceId
        let peerAOld = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x06, count: 32)).deviceId
        let peerB = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x04, count: 32)).deviceId
        let unrelated = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x05, count: 32)).deviceId

        try source.setChatPairing(chatId: peer, KeyRing.Pairing(
            peerId: peer, state: .paired, verified: true, startedAt: nowSeconds, pairedAt: nowSeconds,
            ownDeviceId: ownId, peerDeviceId: peerA, peerSeenDeviceIds: [peerAOld]))
        try source.setChatPairing(chatId: other, KeyRing.Pairing(
            peerId: other, state: .paired, verified: true, startedAt: nowSeconds, pairedAt: nowSeconds,
            ownDeviceId: ownId, peerDeviceId: peerB))
        try source.setDeviceLabel(deviceId: ownId, label: "我的手机")
        try source.setDeviceLabel(deviceId: peerA, label: "老王的公司电脑")
        try source.setDeviceLabel(deviceId: peerAOld, label: "老王的旧手机")
        try source.setDeviceLabel(deviceId: peerB, label: "小李的平板")
        try source.setDeviceLabel(deviceId: unrelated, label: "从未出现在任何配对里")
        XCTAssertEqual(source.exportSnapshot().deviceLabels.count, 5)

        // scope=chat for the first chat only: this device + that chat's peer (current key and the one it
        // replaced), and nothing the other chat or the unreferenced device would have added
        let code = TransferCode.generate()
        let opened = try XCTUnwrap(TransferBundle.open(
            try bundle(source.exportChatsSnapshot(chatIds: [peer], withIdentity: true), code: code, scope: .chat), code: code))
        XCTAssertEqual(opened.scope, .chat)
        XCTAssertEqual(Array(opened.snapshot.chatPairings.keys), [peer])
        XCTAssertEqual(Set(opened.snapshot.deviceLabels.keys), Set([ownId, peerA, peerAOld]))
        XCTAssertEqual(opened.snapshot.deviceLabels[peerA]?.label, "老王的公司电脑")
        XCTAssertNil(opened.snapshot.deviceLabels[peerB])
        XCTAssertNil(opened.snapshot.deviceLabels[unrelated])

        // PLAN.md 3.25.4 rule 2: this device's own label travels even when the identity keys themselves do not
        let noIdentity = try XCTUnwrap(TransferBundle.open(
            try bundle(source.exportChatsSnapshot(chatIds: [peer], withIdentity: false), code: code, scope: .chat), code: code))
        XCTAssertNil(noIdentity.snapshot.identityX25519Sk)
        XCTAssertEqual(noIdentity.snapshot.deviceLabels[ownId]?.label, "我的手机")
        XCTAssertNil(noIdentity.snapshot.deviceLabels[peerB])

        // The shape that used to lose it: the chat has no `ownDeviceId` of its own to fall back on, because the
        // pairing never completed on this device (`invited`; `other_device` has the same hole).
        let unpaired = ring()
        try unpaired.setIdentity(identity)
        try unpaired.setDeviceLabel(deviceId: ownId, label: "我的手机")
        try unpaired.setChatPairing(chatId: peer, KeyRing.Pairing(
            peerId: peer, state: .invited, verified: false, startedAt: nowSeconds))
        let unpairedOpened = try XCTUnwrap(TransferBundle.open(
            try bundle(unpaired.exportChatsSnapshot(chatIds: [peer], withIdentity: false), code: code, scope: .chat), code: code))
        XCTAssertEqual(unpairedOpened.snapshot.deviceLabels[ownId]?.label, "我的手机")

        // the export dialog's "不包含设备备注" checkbox still wins over all of the above
        XCTAssertTrue(source.exportChatsSnapshot(chatIds: [peer], withIdentity: true, includeDeviceLabels: false).deviceLabels.isEmpty)
        XCTAssertTrue(source.exportChatsSnapshot(chatIds: [peer], withIdentity: false, includeDeviceLabels: false).deviceLabels.isEmpty)
    }

    func testWrongCodeTamperedFileOrJunkOpensToNothing() throws {
        let source = ring()
        try source.setChatMaster(chatId: group, masterId: try source.addMaster(KeyDerivation.generateMasterKey()), label: nil)
        let code = TransferCode.generate()
        let text = try bundle(source.exportSnapshot(), code: code)

        XCTAssertNil(TransferBundle.open(text, code: TransferCode.generate()))
        XCTAssertNil(TransferBundle.open(text, code: "not-a-code"))
        var parts = text.components(separatedBy: ":")
        let ct = Array(parts[3])
        parts[3] = String(ct[0..<10]) + (ct[10] == "A" ? "B" : "A") + String(ct[11...])
        XCTAssertNil(TransferBundle.open(parts.joined(separator: ":"), code: code))
        XCTAssertNil(TransferBundle.open("K1:1:zz:zz", code: code))
        XCTAssertNil(TransferBundle.open("hello", code: code))
        XCTAssertNil(TransferBundle.open("K1:2:aa:bb", code: code))
    }

    // MARK: keyring merge (PLAN.md 3.14 rule 2)

    func testWholeKeyringTransferAdoptsIdentityMastersAndBindings() throws {
        let source = ring()
        let target = ring()
        let identity = try Rekey.generateIdentity()
        try source.setIdentity(identity)
        let masterId = try source.addMaster(KeyDerivation.generateMasterKey())
        try source.setChatMaster(chatId: group, masterId: masterId, label: "20260913")
        source.setChatEncryption(chatId: group, enabled: true)
        try source.setChatPairing(chatId: peer, KeyRing.Pairing(peerId: peer, state: .paired, verified: true))
        try source.setChatMaster(chatId: peer, masterId: try source.addMaster(KeyDerivation.generateMasterKey()), label: "20260913")
        try source.setChatKeySource(chatId: group, .offline)

        let result = target.mergeSnapshot(source.exportSnapshot())
        XCTAssertEqual(result.addedMasters, 2)
        XCTAssertEqual(result.boundChats.sorted(), [group, peer].sorted())
        XCTAssertEqual(result.skippedChats, [])
        XCTAssertEqual(target.identity?.ed25519Sk, identity.ed25519Sk)
        XCTAssertEqual(target.chatMasterId(group), masterId)
        XCTAssertTrue(target.isChatEncrypted(group))
        XCTAssertEqual(target.chatPairing(peer)?.state, .paired)
        XCTAssertEqual(target.chatPairing(peer)?.verified, true)
        XCTAssertEqual(target.chatKeySource(group), .offline)
        // the target can now decrypt what the source could
        XCTAssertEqual(target.masterKey(for: masterId), source.masterKey(for: masterId))
    }

    func testOlderBindingNeverRollsBackAndIdentityIsOnlyReplacedOnRequest() throws {
        let source = ring()
        let target = ring()
        try source.setIdentity(try Rekey.generateIdentity())
        try target.setIdentity(try Rekey.generateIdentity())
        let own = try XCTUnwrap(target.identity)

        let oldMaster = try source.addMaster(KeyDerivation.generateMasterKey())
        try source.setChatMaster(chatId: group, masterId: oldMaster, label: "20260901")
        let newMaster = try target.addMaster(KeyDerivation.generateMasterKey())
        try target.setChatMaster(chatId: group, masterId: newMaster, label: "20260913")

        let kept = target.mergeSnapshot(source.exportSnapshot())
        XCTAssertEqual(kept.skippedChats, [group])
        XCTAssertEqual(target.chatMasterId(group), newMaster)
        // the older master still arrives, so history stays readable
        XCTAssertEqual(target.masterKey(for: oldMaster), source.masterKey(for: oldMaster))
        XCTAssertEqual(target.identity?.ed25519Pk, own.ed25519Pk)
        XCTAssertFalse(kept.identityReplaced)

        let replaced = target.mergeSnapshot(source.exportSnapshot(), replaceIdentity: true)
        XCTAssertTrue(replaced.identityReplaced)
        XCTAssertEqual(target.identity?.ed25519Pk, source.identity?.ed25519Pk)
    }

    func testSingleChatExportCarriesThatChatOnlyAndIdentityOnlyWhenAsked() throws {
        let source = ring()
        try source.setIdentity(try Rekey.generateIdentity())
        try source.setChatMaster(chatId: group, masterId: try source.addMaster(KeyDerivation.generateMasterKey()), label: "20260913")
        try source.setChatMaster(chatId: peer, masterId: try source.addMaster(KeyDerivation.generateMasterKey()), label: "20260913")

        let withoutIdentity = source.exportChatsSnapshot(chatIds: [group], withIdentity: false)
        XCTAssertEqual(Array(withoutIdentity.chatMasters.keys), [group])
        XCTAssertEqual(withoutIdentity.masters.count, 1)
        XCTAssertNil(withoutIdentity.identityEd25519Sk)

        let target = ring()
        target.mergeSnapshot(withoutIdentity)
        XCTAssertEqual(target.chatMasterId(group), source.chatMasterId(group))
        XCTAssertNil(target.chatMasterId(peer))
        XCTAssertNil(target.identity)

        XCTAssertNotNil(source.exportChatsSnapshot(chatIds: [group], withIdentity: true).identityEd25519Sk)
    }

    // MARK: cross-client wire format

    /// A `K1` file produced by the Web A implementation (`src/secutg/transfer/bundle.ts`) with a fixed transfer
    /// code. If this stops opening, the wire format drifted and files stop moving between clients.
    func testOpensABundleProducedByTheWebClient() throws {
        let opened = try XCTUnwrap(TransferBundle.open(TransferVectors.webBundle, code: TransferVectors.webCode))
        XCTAssertEqual(opened.v, 1)
        XCTAssertEqual(opened.scope, .all)
        XCTAssertEqual(opened.device, "secuTG Web")
        XCTAssertEqual(opened.createdAt, 1_789_999_999)

        let s = opened.snapshot
        let masterId = TransferVectors.webMasterId
        XCTAssertEqual(s.masters[masterId], (1...32).map { UInt8($0) })
        XCTAssertEqual(s.masterCreatedAt[masterId], 1_789_999_999_000)
        XCTAssertEqual(s.chatMasters[group], masterId)
        XCTAssertEqual(s.chatKeyLabels[group], "20260913")
        XCTAssertEqual(s.chatEncryption[group], true)
        XCTAssertEqual(s.identityX25519Pk, (40..<72).map { UInt8($0) })
        XCTAssertEqual(s.identityEd25519Sk?.count, 64)
        XCTAssertEqual(s.chatAdminPks[group]?.count, 32)
        XCTAssertEqual(s.chatAdminSks[group]?.count, 64)
        XCTAssertEqual(s.memberPks[group]?[peer], (7..<39).map { UInt8($0) })
        XCTAssertEqual(s.memberEdPks[group]?[peer], (11..<43).map { UInt8($0) })
        XCTAssertEqual(s.chatPairings[peer]?.state, .paired)
        XCTAssertEqual(s.chatPairings[peer]?.verified, true)
        XCTAssertEqual(s.chatPairings[peer]?.startedAt, 1_789_000_000)
        XCTAssertEqual(s.chatRatchets[peer]?.label, "20260913")
        XCTAssertEqual(s.chatRatchets[peer]?.masters["20260913"], masterId)
        XCTAssertEqual(s.chatKeySources[group], .online(via: peer, viaLevel: .verified))
        XCTAssertEqual(s.groupOnlineInvites[group]?[peer], .verified)

        // and it survives the merge into a fresh ring
        let target = ring()
        let result = target.mergeSnapshot(s)
        XCTAssertEqual(result.addedMasters, 1)
        XCTAssertEqual(result.boundChats, [group])
        XCTAssertEqual(target.chatMasterId(group), masterId)
        XCTAssertNotNil(target.identity)

        // re-encoding the same snapshot here produces a file the other clients read back identically
        let mine = try bundle(s, code: TransferVectors.webCode)
        let reopened = try XCTUnwrap(TransferBundle.open(mine, code: TransferVectors.webCode))
        XCTAssertEqual(reopened.snapshot, s)
    }
}

enum TransferVectors {
    static let webCode = "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ"
    static let webMasterId = "441edc56cebc8e28"
    static let webBundle = "K1:1:Ns8zJObpb1PCfgMAiuT5lrL8NkLd5_9-:kq0C1P6uKvzLhEDNYiDhppVEwMHakXLH4ml4UH_GkXZjmWrtaL2FALbDdDVdOOcrcN6sfKwOId4vF3AOdeRPVw7nQPbNRR64NSr6CNLcP4isCMxSBjyOPSlIpul9nP3_4BXcRgoXzxcg7MHGhBjME9ADmpI0OREG04BbCvlUwCdRbbDFujEpZeQbaQ2uAGt1Rt8LPG-2vSh-Q1OsbFVklhhZ0nucZtbqDbjEOibn7ucH88WJ9dADzBJO9p2CVXjTr-AlBmwx7O_KCfKlIIT5tyCX1kcl0EmeZKFQDinNu1Iv5gTQR0azoHhoQB9lF4NGoDJCBbUknQrdVha-28xBeLbcM4ih1cp3Bez4y-S8e7IKe18VcJSXdo4Zy1FSmNcUVp27wZl-Y-xs8AEgdjg7U863z7OkGo16MGwzMo9xhyQ0tbsmrLAcREXaG9EpwfT7rTkH9B6Y924c9UG7XjtOO41h-_re9bvJZR48-u_aidA7HiSdsujTsGTijOxpuo5NXKTBfaC4RCvBInk8PrHDb6gEIPDRtVct8X9-ujk_-jmDTe4MY_0Pdi-IBmg8Zn29pOgqA9J0K8UvWFdKrluWod32S64c9yQDelf-4pQEfKUNw4NVLJ5e4QoZokY-KUHvTW9KznIT7ozJj7S1pUvxutaacPGVuw10HGtiWcw3hvQLtsBRnswCr0bWppxGaSadkv4aDvHYaOEQg2M1jO9-K5VmLnPeso2lKt0Rp1IKzfuzMHbUHcPs04JNKXwcCqCi3mI_cOt3Cik3Nexz36M9Z8cYfdFQpjS8EjCJ7yZ8N105j63m4yCx-yJDJ8rqbvgPGLHm2zzkzqwBBVeW8LYEEuDyqirIjh4FCwQ71Bbw7N8Z6MCUp-V9W5AxKdWE3iUGpmdhOI3zHwaEddPUQ0tshPuoNE2DhJYZE7GlYrNXPyLyuVxXv76Vqs-XwTAYQJ9qbnM4pDkEKtJLCCr4PXZqWZKokSAJEBtsEjYOm1iz3KBhNqKCeXKWX-BrXA3MGFPNRPRZIK4LwDuYjfdmRrXFqD102QBQIOR9JEpm0HEsg-YAqSE1DOMSqvixhKx_n7FxG5O58M7XXXeqsyl6iWrmazM9mTsTJgjgGmSe1jEXqa2EcFobHMAbzaEp5_vJsvEF_BGbmu8LLmq-2vMd5yoEOcxp2anWLuBjIbl-wD8CqK-CFKTJefKiqjfpeDVfrO-9mGU5beviMTilnjSLrdlUJWay_SZA_03j1jQRUydnE88HXMRoMHBP2J2x8rai1Aba71FqPk8Y4s31Mm_GCgLtBo5f5_ItnW1LKlHLSsh-KB4NbReuH5OQoxk4mcKmkAcpn9hEeZMEUb6ZVEL1_ElBUasy2alOZh4NkPARF-EPomeknyU0PA_2VakqSBRPLO-QyjkQ0RuXHA1Bfnogh6Om_WF4gZC2InNeoAY_O-S5CvourLMzi9pneRpdIiCio0hNKiNUhp55KlqCd4oORrRfaKE1-5QTXfrmEwol0t3QiqqD_0AICE2s1CJpG-tmt0fqVGj_7qtP33iJzGkj6D8gFdMqIR72fTHWtiaUD8x06mSfFMtZWwoyVFl4EI1sIDoGyJAi-EAJzd0TZ0D1s7M4vIEdZpB1rE8gMklxR9ZrOr6rNKKmatYtG3nGFJSUXoSN24auqMot6DXtwBdy84rAmghj4ky2kT0NAQzMnsBkab7K_jOFgZU_JzAeBM-pbO7DqMyGnqS2ZIfbO0zXvyaClgXt2FuYMxExOfm26kaxThbDGnHL5JGrb_dU7e-rjbzoe5lYdplHzYgWmD3hCCZJLc7p6Eo7X2m6L5lCPYg1AeqEKhEajoSr1ESti7K-hjSD1aDi--8rQxfXGDd3C5nWjblB6_aB5L8cpbRdyQ321Q"
}
