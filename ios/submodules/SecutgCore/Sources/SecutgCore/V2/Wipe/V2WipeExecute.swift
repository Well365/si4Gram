import Foundation

/// v1.4 section 19's actual local-wipe SEQUENCE — the piece `V2W2`'s own module doc named as
/// explicitly out of its scope. This enum IS that orchestration, but still only the SEQUENCING and
/// TIMING rules v1.4 states, not the actual platform actions themselves — those are injected
/// callbacks. Ported from `src/secutg/v2/wipe/execute.ts` and
/// `org.telegram.secutg.v2.wipe.WipeExecute`.
///
/// v1.4 section 19: "a local wipe is triggered only by an explicit confirmation: stop business and
/// background send tasks -> optionally persist and write out a signed remote request -> delete this
/// device's app-controlled keys and data -> log out. Network requests use a bounded time limit, never
/// letting Telegram's unavailability delay local cleanup."
///
/// Two things this order-of-four encodes: (1) writing the signed remote W2 request is OPTIONAL and
/// NETWORK-BOUNDED — it runs under remoteRequestTimeoutMs and its outcome never gates the two steps
/// after it, implemented here with `DispatchSemaphore.wait(timeout:)` (Swift's bounded synchronous
/// wait, the direct analog of the Java port's `ExecutorService`/`Future.get(timeout:)`); (2) explicit
/// confirmation triggers this whole sequence — this enum assumes that confirmation already happened.
public enum V2WipeExecute {
    public struct StepOutcome {
        public let ok: Bool
        public let error: String?

        static func ok() -> StepOutcome {
            return StepOutcome(ok: true, error: nil)
        }

        static func fail(_ error: String) -> StepOutcome {
            return StepOutcome(ok: false, error: error)
        }
    }

    /// The remote-request step's outcome has one more possible shape than an ordinary step:
    /// "skipped" (callback omitted) or "timed_out" (bounded wait elapsed), in addition to ok/failed.
    public struct RemoteRequestOutcome {
        public let kind: String // "ok" | "failed" | "skipped" | "timed_out"
        public let error: String?

        static func ok() -> RemoteRequestOutcome {
            return RemoteRequestOutcome(kind: "ok", error: nil)
        }

        static func failed(_ error: String) -> RemoteRequestOutcome {
            return RemoteRequestOutcome(kind: "failed", error: error)
        }

        static func skipped() -> RemoteRequestOutcome {
            return RemoteRequestOutcome(kind: "skipped", error: nil)
        }

        static func timedOut() -> RemoteRequestOutcome {
            return RemoteRequestOutcome(kind: "timed_out", error: nil)
        }
    }

    public struct Callbacks {
        /// "stop business and background send tasks".
        public let stopSending: () throws -> Void
        /// "optionally persist and write out a signed remote request" — nil entirely when there is
        /// nothing to notify, not merely a callback that no-ops.
        public let writeRemoteRequest: (() throws -> Void)?
        /// "delete this device's app-controlled keys and data".
        public let deleteLocalData: () throws -> Void
        /// "log out".
        public let logOut: () throws -> Void

        public init(stopSending: @escaping () throws -> Void, writeRemoteRequest: (() throws -> Void)? = nil, deleteLocalData: @escaping () throws -> Void, logOut: @escaping () throws -> Void) {
            self.stopSending = stopSending
            self.writeRemoteRequest = writeRemoteRequest
            self.deleteLocalData = deleteLocalData
            self.logOut = logOut
        }
    }

    public struct Outcome {
        public let stopSending: StepOutcome
        public let remoteRequest: RemoteRequestOutcome
        public let deleteLocalData: StepOutcome
        public let logOut: StepOutcome
    }

    public static let defaultRemoteRequestTimeoutMs: Int = 5000

    private static func runStep(_ step: () throws -> Void) -> StepOutcome {
        do {
            try step()
            return .ok()
        } catch {
            return .fail(String(describing: error))
        }
    }

    private static func withTimeout(_ step: @escaping () throws -> Void, timeoutMs: Int) -> RemoteRequestOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        var result: StepOutcome? = nil
        let queue = DispatchQueue(label: "secutg.v2.wipe.remoteRequest")
        queue.async {
            result = runStep(step)
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
        if waitResult == .timedOut { return .timedOut() }
        guard let result = result else { return .timedOut() }
        return result.ok ? .ok() : .failed(result.error ?? "unknown error")
    }

    public static func executeLocalWipe(_ callbacks: Callbacks, remoteRequestTimeoutMs: Int = defaultRemoteRequestTimeoutMs) -> Outcome {
        let stopSending = runStep(callbacks.stopSending)

        let remoteRequest: RemoteRequestOutcome
        if let writeRemoteRequest = callbacks.writeRemoteRequest {
            remoteRequest = withTimeout(writeRemoteRequest, timeoutMs: remoteRequestTimeoutMs)
        } else {
            remoteRequest = .skipped()
        }

        let deleteLocalData = runStep(callbacks.deleteLocalData)
        let logOut = runStep(callbacks.logOut)

        return Outcome(stopSending: stopSending, remoteRequest: remoteRequest, deleteLocalData: deleteLocalData, logOut: logOut)
    }
}
