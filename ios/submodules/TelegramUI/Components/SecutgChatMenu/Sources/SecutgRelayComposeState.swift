import Foundation
import SwiftSignalKit
import Postbox

/// SECUTG-HOOK (PLAN.md 3.48) support: one-shot per-chat overrides for the very next send in that chat —
/// "force relay" (the send-button long-press `⇄ 通过中转发送…` entry, PLAN.md 3.48.4) and "skip relay for this
/// one send" (the ✕ on the compose tag). Deliberately in-memory only and scoped to this process, never
/// persisted (PLAN.md 3.48.0 rule 5's "own storage" taken to its logical conclusion here: a relaunch should
/// never surprise the user with a stale override from a session they do not remember).
public enum SecutgRelayComposeOverride {
    case forceNext
    case skipNext
}

public final class SecutgRelayComposeState {
    public static let shared = SecutgRelayComposeState()

    private let lock = NSLock()
    private var overrides: [Int64: SecutgRelayComposeOverride] = [:]
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)

    private init() {}

    /// Bumped whenever an override is set — the compose tag lives in the header strip (built during layout),
    /// and nothing else relayouts the chat when the ✕/✎ buttons or the long-press menu's entry are tapped,
    /// matching `SecutgPlaintextPaneState.revision` / `SecutgKeyRequiredNoticeState.revision`'s own notes.
    public var revision: Signal<Int32, NoError> {
        return self.revisionPromise.get()
    }

    private func invalidate() {
        self.lock.lock()
        self.counter &+= 1
        let value = self.counter
        self.lock.unlock()
        self.revisionPromise.set(value)
    }

    public static func setForceNext(peerId: PeerId) {
        shared.lock.lock()
        shared.overrides[peerId.toInt64()] = .forceNext
        shared.lock.unlock()
        shared.invalidate()
    }

    public static func setSkipNext(peerId: PeerId) {
        shared.lock.lock()
        shared.overrides[peerId.toInt64()] = .skipNext
        shared.lock.unlock()
        shared.invalidate()
    }

    /// Non-consuming read, for layout passes that only need to know whether to draw something (the compose tag
    /// re-asks this on every relayout — see `SecutgRelayComposeHost.isDue`).
    public static func peek(peerId: PeerId) -> SecutgRelayComposeOverride? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.overrides[peerId.toInt64()]
    }

    /// Consuming read, for the one place that actually acts on an override — the send chokepoint
    /// (`SecutgRelayComposeHost.interceptSend`). After this, the chat is back to its ordinary policy until the
    /// user sets another override.
    public static func consume(peerId: PeerId) -> SecutgRelayComposeOverride? {
        shared.lock.lock()
        let value = shared.overrides.removeValue(forKey: peerId.toInt64())
        shared.lock.unlock()
        if value != nil {
            shared.invalidate()
        }
        return value
    }
}
