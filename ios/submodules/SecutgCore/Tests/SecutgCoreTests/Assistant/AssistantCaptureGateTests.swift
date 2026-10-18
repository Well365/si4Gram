import XCTest
@testable import SecutgCore

/// PLAN.md 3.45.2 / 3.45.7 "按消息 id 去重": one event per message id across the sent-message tap, the server echo,
/// the incoming hook and the offline rescan (phase 4 review). `Capture` replays the order of operations of the macOS
/// glue (SecutgAssistantEvents: noteCommand → buildCommand → emitCommand, and the rescan's emitCommand) on the gate
/// and the watermarks, and counts what reaches the queue.
final class AssistantCaptureGateTests: XCTestCase {
    private static let savedMessages: Int64 = 7_700_000_001
    private static let cloud: Int32 = 0

    private struct Capture {
        var gate = AssistantCaptureGate()
        var marks = AssistantWatermarks(captureSince: 100)
        var saved = AssistantWatermarks(captureSince: 100)   // what watermarks.json holds
        var published: [String] = []                         // event_ids written to the queue
        var queueFails = false

        static func key(_ id: Int32) -> AssistantCaptureGate.Key {
            return AssistantCaptureGate.Key(chat: AssistantCaptureGateTests.savedMessages, namespace: AssistantCaptureGateTests.cloud, messageId: id)
        }

        /// A live sighting (tap or echo): true when a build was scheduled.
        mutating func see(_ id: Int32, date: Int32 = 200) -> Bool {
            return gate.begin(Capture.key(id), date: date, marks: marks)
        }

        /// The scheduled build finished and found a command: emitCommand, then the in-flight entry goes.
        mutating func finishBuild(_ id: Int32, date: Int32 = 200, crashBeforeSave: Bool = false) {
            publish(id, date: date, crashBeforeSave: crashBeforeSave)
            gate.end(Capture.key(id))
        }

        /// The rescan found the same message (it never looks at the gate).
        mutating func rescan(_ id: Int32, date: Int32 = 200) {
            publish(id, date: date, crashBeforeSave: false)
        }

        private mutating func publish(_ id: Int32, date: Int32, crashBeforeSave: Bool) {
            let chat = AssistantCaptureGateTests.savedMessages
            guard marks.shouldConsider(chat: chat, messageId: id, date: date), !queueFails else { return }
            published.append(AssistantCommandEvent.eventId(chatPeerId: chat, messageId: id))
            if crashBeforeSave { return }                     // the process dies before markEmitted / saveWatermarks
            marks.markEmitted(chat: chat, messageId: id)
            saved = marks
        }

        /// The app restarts: in-flight builds are gone, the watermarks come back from the file.
        mutating func restart() {
            gate.reset()
            marks = saved
        }
    }

    func testTapThenEchoIsOneEvent() {
        var capture = Capture()
        XCTAssertTrue(capture.see(10))          // the sent-message tap
        XCTAssertFalse(capture.see(10))         // the server echo while the build waits
        capture.finishBuild(10)
        XCTAssertFalse(capture.see(10))         // a late echo after it was emitted
        XCTAssertEqual(capture.published, ["c-7700000001-10"])
        XCTAssertTrue(capture.gate.inflight.isEmpty)
    }

    func testEchoThenTapIsOneEvent() {
        var capture = Capture()
        XCTAssertTrue(capture.see(11))          // another device's message through the incoming hook
        capture.finishBuild(11)
        XCTAssertFalse(capture.see(11))         // then the tap (or a second hook call) for the same id
        XCTAssertEqual(capture.published, ["c-7700000001-11"])
    }

    func testRescanWhileALiveBuildIsInFlightIsOneEvent() {
        var capture = Capture()
        XCTAssertTrue(capture.see(12))
        capture.rescan(12)                      // the rescan reaches the same id first
        capture.finishBuild(12)                 // the live build's publish now sees it emitted
        XCTAssertEqual(capture.published, ["c-7700000001-12"])
        XCTAssertFalse(capture.see(12))
        capture.rescan(12)
        XCTAssertEqual(capture.published.count, 1)
    }

    func testLiveBuildThenRescanIsOneEvent() {
        var capture = Capture()
        XCTAssertTrue(capture.see(13))
        capture.finishBuild(13)
        capture.rescan(13)
        XCTAssertEqual(capture.published, ["c-7700000001-13"])
    }

    func testWatermarkPastTheMessageStopsEveryPath() {
        var capture = Capture()
        capture.marks.advance(chat: AssistantCaptureGateTests.savedMessages, to: 20)
        XCTAssertFalse(capture.see(14))
        capture.rescan(14)
        XCTAssertFalse(capture.see(21, date: 99))  // older than capture
        XCTAssertTrue(capture.published.isEmpty)
    }

    func testFailedQueueWriteIsNotMarkedAndCanBeCapturedLater() {
        var capture = Capture()
        capture.queueFails = true
        XCTAssertTrue(capture.see(15))
        capture.finishBuild(15)
        XCTAssertTrue(capture.published.isEmpty)
        capture.queueFails = false
        XCTAssertTrue(capture.see(15))          // not emitted, not in flight: the next sighting or rescan tries again
        capture.finishBuild(15)
        XCTAssertEqual(capture.published, ["c-7700000001-15"])
    }

    func testCrashBetweenPublishAndSaveRepeatsTheSameEventId() {
        var capture = Capture()
        XCTAssertTrue(capture.see(16))
        capture.finishBuild(16, crashBeforeSave: true)
        capture.restart()
        capture.rescan(16)                      // the restart's rescan emits it again ...
        XCTAssertEqual(capture.published, ["c-7700000001-16", "c-7700000001-16"])  // ... under the same event_id
        XCTAssertFalse(capture.see(16))
    }

    func testKeysIncludeTheNamespaceAndResetClearsEverything() {
        var gate = AssistantCaptureGate()
        let marks = AssistantWatermarks()
        let cloud = AssistantCaptureGate.Key(chat: 1, namespace: 0, messageId: 5)
        let local = AssistantCaptureGate.Key(chat: 1, namespace: 1, messageId: 5)
        XCTAssertTrue(gate.begin(cloud, date: 1, marks: marks))
        XCTAssertTrue(gate.isInflight(cloud))
        XCTAssertFalse(gate.isInflight(local))
        XCTAssertTrue(gate.begin(local, date: 1, marks: marks))
        gate.reset()
        XCTAssertTrue(gate.inflight.isEmpty)
        XCTAssertTrue(gate.begin(cloud, date: 1, marks: marks))
    }
}
