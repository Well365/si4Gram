import XCTest
@testable import SecutgCore

/// Ported from Android's `WipeExecuteTest.java` — v1.4 section 19's local-wipe sequence.
final class V2WipeExecuteTests: XCTestCase {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testAllFourStepsRunInTheExactStatedOrderWhenEveryStepSucceeds() {
        let order = Box<[String]>([])
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { order.value.append("stopSending") },
            writeRemoteRequest: { order.value.append("writeRemoteRequest") },
            deleteLocalData: { order.value.append("deleteLocalData") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertEqual(order.value, ["stopSending", "writeRemoteRequest", "deleteLocalData", "logOut"])
        XCTAssertTrue(outcome.stopSending.ok)
        XCTAssertEqual(outcome.remoteRequest.kind, "ok")
        XCTAssertTrue(outcome.deleteLocalData.ok)
        XCTAssertTrue(outcome.logOut.ok)
    }

    func testWriteRemoteRequestIsOptionalOmittingItReportsSkippedNotAFailure() {
        let order = Box<[String]>([])
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { order.value.append("stopSending") },
            deleteLocalData: { order.value.append("deleteLocalData") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertEqual(outcome.remoteRequest.kind, "skipped")
    }

    func testAHangingWriteRemoteRequestTimesOutAndDoesNotBlockDeleteLocalDataLogOut() {
        let order = Box<[String]>([])
        let neverSignals = DispatchSemaphore(value: 0)
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { order.value.append("stopSending") },
            writeRemoteRequest: { neverSignals.wait() }, // hangs until the process ends; the timeout fires first
            deleteLocalData: { order.value.append("deleteLocalData") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks, remoteRequestTimeoutMs: 10)
        XCTAssertEqual(outcome.remoteRequest.kind, "timed_out")
        XCTAssertEqual(order.value, ["stopSending", "deleteLocalData", "logOut"])
    }

    func testARejectingWriteRemoteRequestReportsFailureButStillDoesNotBlockLaterSteps() {
        let order = Box<[String]>([])
        struct TestError: Error, CustomStringConvertible { var description: String }
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { order.value.append("stopSending") },
            writeRemoteRequest: { throw TestError(description: "offline") },
            deleteLocalData: { order.value.append("deleteLocalData") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertEqual(outcome.remoteRequest.kind, "failed")
        XCTAssertEqual(outcome.remoteRequest.error, "offline")
        XCTAssertEqual(order.value, ["stopSending", "deleteLocalData", "logOut"])
    }

    func testStopSendingThrowingStillLetsDeleteLocalDataAndLogOutRun() {
        let order = Box<[String]>([])
        struct TestError: Error, CustomStringConvertible { var description: String }
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { throw TestError(description: "no active tasks") },
            deleteLocalData: { order.value.append("deleteLocalData") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertFalse(outcome.stopSending.ok)
        XCTAssertEqual(outcome.stopSending.error, "no active tasks")
        XCTAssertEqual(order.value, ["deleteLocalData", "logOut"])
    }

    func testDeleteLocalDataThrowingStillLetsLogOutRunAndReportsTheRealError() {
        let order = Box<[String]>([])
        struct TestError: Error, CustomStringConvertible { var description: String }
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { order.value.append("stopSending") },
            deleteLocalData: { throw TestError(description: "disk error") },
            logOut: { order.value.append("logOut") }
        )
        let outcome = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertFalse(outcome.deleteLocalData.ok)
        XCTAssertEqual(outcome.deleteLocalData.error, "disk error")
        XCTAssertEqual(order.value, ["stopSending", "logOut"])
    }

    func testEveryStepActuallyGetsCalledExactlyOnce() {
        let stopSendingCalls = Box<Int>(0)
        let deleteLocalDataCalls = Box<Int>(0)
        let logOutCalls = Box<Int>(0)
        let callbacks = V2WipeExecute.Callbacks(
            stopSending: { stopSendingCalls.value += 1 },
            deleteLocalData: { deleteLocalDataCalls.value += 1 },
            logOut: { logOutCalls.value += 1 }
        )
        _ = V2WipeExecute.executeLocalWipe(callbacks)
        XCTAssertEqual(stopSendingCalls.value, 1)
        XCTAssertEqual(deleteLocalDataCalls.value, 1)
        XCTAssertEqual(logOutCalls.value, 1)
    }
}
