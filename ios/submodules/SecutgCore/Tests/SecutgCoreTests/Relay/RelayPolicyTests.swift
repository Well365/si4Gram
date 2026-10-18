import XCTest
@testable import SecutgCore

final class RelayPolicyTests: XCTestCase {
    func testDefaultSettingsAreOff() {
        let settings = RelaySettings.default
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.trigger.manualOnly)
        XCTAssertFalse(settings.trigger.autoLongText)
        XCTAssertFalse(settings.trigger.autoImageAlways)
        XCTAssertEqual(settings.defaultKeepPolicy, RelayKeepPolicy(maxReads: 1, ttlSeconds: 86_400))
        XCTAssertTrue(settings.encryptContent)
        XCTAssertTrue(settings.stripExif)
        XCTAssertTrue(settings.showCards)
        XCTAssertTrue(settings.askUnknownRelay)
        XCTAssertFalse(settings.allowInsecureOrLAN)
    }

    func testIsEnabledFollowsChatOverride() {
        var global = RelaySettings.default
        global.enabled = false
        XCTAssertFalse(RelayPolicy.isEnabled(global: global, chat: RelayChatPolicy(mode: .followGlobal, keepPolicy: nil, relayId: nil)))
        XCTAssertTrue(RelayPolicy.isEnabled(global: global, chat: RelayChatPolicy(mode: .alwaysOn, keepPolicy: nil, relayId: nil)))

        global.enabled = true
        XCTAssertTrue(RelayPolicy.isEnabled(global: global, chat: RelayChatPolicy(mode: .followGlobal, keepPolicy: nil, relayId: nil)))
        XCTAssertFalse(RelayPolicy.isEnabled(global: global, chat: RelayChatPolicy(mode: .alwaysOff, keepPolicy: nil, relayId: nil)))
    }

    func testShouldAutoRelayManualOnlyNeverAutoRoutes() {
        let trigger = RelaySendTrigger(manualOnly: true, autoLongText: true, autoImageAlways: true)
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 999_999, isImage: false))
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 0, isImage: true))
    }

    func testShouldAutoRelayLongText() {
        let trigger = RelaySendTrigger(manualOnly: false, autoLongText: true, autoImageAlways: false)
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 4096, isImage: false))
        XCTAssertTrue(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 4097, isImage: false))
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 4097, isImage: true))
    }

    func testShouldAutoRelayImageAlways() {
        let trigger = RelaySendTrigger(manualOnly: false, autoLongText: false, autoImageAlways: true)
        XCTAssertTrue(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 0, isImage: true))
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: trigger, textLength: 99999, isImage: false))
    }

    func testEffectiveKeepPolicyPrefersChatOverride() {
        let global = RelaySettings.default
        let withOverride = RelayChatPolicy(mode: .alwaysOn, keepPolicy: RelayKeepPolicy(maxReads: 10, ttlSeconds: 3600), relayId: nil)
        XCTAssertEqual(RelayPolicy.effectiveKeepPolicy(global: global, chat: withOverride), RelayKeepPolicy(maxReads: 10, ttlSeconds: 3600))
        XCTAssertEqual(RelayPolicy.effectiveKeepPolicy(global: global, chat: .default), global.defaultKeepPolicy)
    }
}
