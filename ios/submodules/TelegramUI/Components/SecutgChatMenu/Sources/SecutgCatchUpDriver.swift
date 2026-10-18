import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

/// SECUTG (PLAN.md 3.47 point 1): when the catch-up pass runs — for an account as soon as its context is up (its
/// runtime was installed by `Account.init` just before), and for every account each time the app becomes active
/// (`applicationIsActive` false → true, i.e. `applicationDidBecomeActive`). The pass itself, its single-flight gate
/// and its budgets are `SecutgCatchUp` in TelegramCore; this only decides the moments.
///
/// Attached once per process from `AuthorizedApplicationContext.init` (idempotent), and it follows every logged-in
/// account, not only the one on screen: the Notification Service Extension writes for all of them.
public final class SecutgCatchUpDriver {
    private static let lock = NSLock()
    private static var attached: SecutgCatchUpDriver?

    private var disposable: Disposable?
    private var wasActive = false
    private var knownAccounts = Set<AccountRecordId>()

    public static func attach(sharedContext: SharedAccountContext) {
        lock.lock(); defer { lock.unlock() }
        guard attached == nil else { return }
        let driver = SecutgCatchUpDriver()
        attached = driver
        driver.disposable = (combineLatest(queue: Queue.mainQueue(),
                                           sharedContext.applicationBindings.applicationIsActive,
                                           sharedContext.activeAccountContexts)
        ).start(next: { [weak driver] isActive, contexts in
            driver?.update(isActive: isActive, accounts: contexts.accounts.map { ($0.0, $0.1) })
        })
    }

    /// Main queue only (the subscription above delivers there).
    private func update(isActive: Bool, accounts: [(AccountRecordId, AccountContext)]) {
        let becameActive = isActive && !wasActive
        wasActive = isActive
        let current = Set(accounts.map { $0.0 })
        let added = current.subtracting(knownAccounts)
        knownAccounts = current
        guard isActive else { return }
        for (id, context) in accounts where becameActive || added.contains(id) {
            SecutgCatchUp.trigger(postbox: context.account.postbox, accountPeerId: context.account.peerId)
        }
    }
}
