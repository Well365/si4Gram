import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import SettingsUI
import SecutgChatMenu
import SecutgCore

/// SECUTG: the online gate (PLAN.md 3.37). While an account is logged in, a full-window cover hides the
/// whole app until that account is online and has finished its sync; once lifted, it comes back only after
/// 15 s of continuous loss of connection. The decision is `SecutgCore.NetGatePolicy`; this class feeds it
/// `Account.networkState` (connection status with the getDifference "updating" folded in, the same state the
/// chat list title shows) and a monotonic clock, and puts the cover on the main window.
///
/// Where it sits: a `NavigationController` presented on the window's presentation context, so it is above the
/// root controller and everything it presents (chat list, chats, media, search, alerts, calls UI), and below
/// Telegram's own passcode lock, which lives in the window's top presentation context (`presentedOverCoveringView`)
/// — the passcode therefore always comes first (rule 1). Being a navigation controller of its own is what makes
/// the proxy button work: Telegram's proxy screen is pushed onto it as a modal sheet, above the cover, with its
/// add / edit server screens pushed inside that sheet as usual (rule 2: a proxy-only user must be able to connect).
///
/// One per process, driven from `AppDelegate`: `attach` follows whichever account is current (rule 5),
/// `setAuthFlowActive` steps aside while the login / add-account flow is on screen (that flow covers the window
/// itself and has its own proxy entry). There is no switch to turn it off (rule 6).
public final class SecutgNetGate {
    public static let shared = SecutgNetGate()

    private weak var window: Window1?
    private var context: AccountContext?
    private var isAuthFlowActive: Bool = false
    private var policy = NetGatePolicy(isAuthorized: false)

    private let stateDisposable = MetaDisposable()
    private var recoverTimer: SwiftSignalKit.Timer?
    private var foregroundObserver: NSObjectProtocol?

    private var navigationController: NavigationController?
    private var contentController: SecutgNetGateContentController?
    /// `present` hands the controller over only once it is ready (next run loop); a lift that arrives before
    /// that is remembered here and carried out in the completion.
    private var isPresenting: Bool = false
    private var dismissWhenPresented: Bool = false

    private init() {
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            // Timers do not run while the app is suspended: judge the outage the moment we are back.
            self?.advance()
        })
    }

    deinit {
        if let foregroundObserver = self.foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        self.stateDisposable.dispose()
        self.recoverTimer?.invalidate()
    }

    /// True while the current account must not show anything. Other hooks (in-app message banners) consult it.
    public var isCovering: Bool {
        return self.policy.isCovered
    }

    /// The current authorized account, or nil when nobody is logged in. Called on every account switch.
    public func attach(window: Window1, context: AccountContext?) {
        assert(Thread.isMainThread)
        self.window = window
        if let current = self.context, let context, current === context {
            return
        }
        self.context = context
        self.stateDisposable.set(nil)
        // The cover of the previous account holds that account's proxy screen: never reuse it.
        self.removeCover()
        self.policy = NetGatePolicy(isAuthorized: context != nil)
        self.apply()

        guard let context else {
            return
        }
        self.stateDisposable.set((context.account.networkState
        |> deliverOnMainQueue).start(next: { [weak self, weak context] state in
            guard let self, let context, let current = self.context, current === context else {
                return
            }
            self.policy = self.policy.with(connection: SecutgNetGate.connection(state), now: SecutgNetGate.now())
            self.apply()
        }))
    }

    /// The login / add-account flow is (not) on screen.
    public func setAuthFlowActive(_ isActive: Bool) {
        assert(Thread.isMainThread)
        if self.isAuthFlowActive == isActive {
            return
        }
        self.isAuthFlowActive = isActive
        self.apply()
    }

    private static func connection(_ state: AccountNetworkState) -> NetGateConnection {
        switch state {
        case .waitingForNetwork:
            return .waitingForNetwork
        case .connecting:
            return .connecting
        case .updating:
            return .updating
        case .online:
            return .online
        }
    }

    /// Seconds on a clock that neither jumps with the wall clock nor stops while the device sleeps.
    private static func now() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000.0
    }

    private func advance() {
        self.policy = self.policy.advanced(to: SecutgNetGate.now())
        self.apply()
    }

    private func apply() {
        self.scheduleRecoverTimer()
        if self.policy.isCovered && !self.isAuthFlowActive {
            self.showCover(phase: self.policy.phase)
        } else {
            self.removeCover()
        }
    }

    private func scheduleRecoverTimer() {
        self.recoverTimer?.invalidate()
        self.recoverTimer = nil
        guard let deadline = self.policy.recoverDeadline else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: max(0.0, deadline - SecutgNetGate.now()) + 0.05, repeat: false, completion: { [weak self] in
            self?.advance()
        }, queue: Queue.mainQueue())
        self.recoverTimer = timer
        timer.start()
    }

    private func showCover(phase: NetGatePhase) {
        self.dismissWhenPresented = false
        if let contentController = self.contentController {
            contentController.update(phase: phase)
            return
        }
        guard let window = self.window, let context = self.context else {
            return
        }
        SecutgChatMenu.syncLanguage(context: context)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let contentController = SecutgNetGateContentController(presentationData: presentationData, phase: phase)
        let navigationController = NavigationController(mode: .single, theme: NavigationControllerTheme(presentationTheme: presentationData.theme))
        navigationController.setViewControllers([contentController], animated: false)
        contentController.openProxySettings = { [weak navigationController, weak context] in
            guard let navigationController, let context else {
                return
            }
            navigationController.pushViewController(proxySettingsController(context: context, mode: .modal))
        }
        self.contentController = contentController
        self.navigationController = navigationController
        self.isPresenting = true
        window.present(navigationController, on: .root, blockInteraction: false, completion: { [weak self, weak navigationController] in
            guard let self, let navigationController, self.navigationController === navigationController else {
                return
            }
            self.isPresenting = false
            if self.dismissWhenPresented {
                self.dismissWhenPresented = false
                self.navigationController = nil
                self.contentController = nil
                navigationController.dismiss(animated: false, completion: nil)
            }
        })
    }

    private func removeCover() {
        guard let navigationController = self.navigationController else {
            return
        }
        if self.isPresenting {
            self.dismissWhenPresented = true
            return
        }
        self.navigationController = nil
        self.contentController = nil
        self.dismissWhenPresented = false
        navigationController.view.endEditing(true)
        navigationController.dismiss(animated: false, completion: nil)
    }
}

/// The cover itself: opaque, an indeterminate spinner, the phase, one line on why, and the proxy button.
final class SecutgNetGateContentController: ViewController {
    private let presentationData: PresentationData
    private var phase: NetGatePhase

    private let spinner = UIActivityIndicatorView(style: .large)
    private let phaseLabel = UILabel()
    private let hintLabel = UILabel()
    private let proxyButton = UIButton(type: .system)

    var openProxySettings: (() -> Void)?

    init(presentationData: PresentationData, phase: NetGatePhase) {
        self.presentationData = presentationData
        self.phase = phase
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        let theme = self.presentationData.theme
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = theme.list.plainBackgroundColor
        self.displayNodeDidLoad()
        let view = self.displayNode.view

        self.spinner.color = theme.list.itemSecondaryTextColor
        self.spinner.hidesWhenStopped = false
        self.spinner.startAnimating()
        view.addSubview(self.spinner)

        self.phaseLabel.font = UIFont.boldSystemFont(ofSize: 17.0)
        self.phaseLabel.textColor = theme.list.itemPrimaryTextColor
        self.phaseLabel.textAlignment = .center
        self.phaseLabel.numberOfLines = 0
        view.addSubview(self.phaseLabel)

        self.hintLabel.text = SecutgL10n.string("SecutgNetGateHint")
        self.hintLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.hintLabel.textColor = theme.list.itemSecondaryTextColor
        self.hintLabel.textAlignment = .center
        self.hintLabel.numberOfLines = 0
        view.addSubview(self.hintLabel)

        self.proxyButton.setTitle(SecutgL10n.string("SecutgNetGateProxy"), for: .normal)
        self.proxyButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.proxyButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
        self.proxyButton.titleLabel?.numberOfLines = 0
        self.proxyButton.titleLabel?.textAlignment = .center
        self.proxyButton.addTarget(self, action: #selector(self.proxyPressed), for: .touchUpInside)
        view.addSubview(self.proxyButton)

        self.applyPhase()
    }

    func update(phase: NetGatePhase) {
        if self.phase == phase {
            return
        }
        self.phase = phase
        if self.isViewLoaded {
            self.applyPhase()
            self.requestLayout(transition: .immediate)
        }
    }

    private func applyPhase() {
        switch self.phase {
        case .connecting:
            self.phaseLabel.text = SecutgL10n.string("SecutgNetGateConnecting")
        case .syncing:
            self.phaseLabel.text = SecutgL10n.string("SecutgNetGateSyncing")
        }
    }

    @objc private func proxyPressed() {
        self.openProxySettings?()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        let inset: CGFloat = 32.0
        let width = max(0.0, min(layout.size.width - layout.safeInsets.left - layout.safeInsets.right, 480.0) - inset * 2.0)
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let spinnerSize = self.spinner.intrinsicContentSize
        let phaseHeight = ceil(self.phaseLabel.sizeThatFits(fit).height)
        let hintHeight = ceil(self.hintLabel.sizeThatFits(fit).height)
        let buttonHeight = max(44.0, ceil(self.proxyButton.sizeThatFits(fit).height))

        let total = spinnerSize.height + 20.0 + phaseHeight + 12.0 + hintHeight + 24.0 + buttonHeight
        let x = floor((layout.size.width - width) / 2.0)
        var y = floor((layout.size.height - total) / 2.0)

        self.spinner.frame = CGRect(x: floor((layout.size.width - spinnerSize.width) / 2.0), y: y, width: spinnerSize.width, height: spinnerSize.height)
        y += spinnerSize.height + 20.0
        self.phaseLabel.frame = CGRect(x: x, y: y, width: width, height: phaseHeight)
        y += phaseHeight + 12.0
        self.hintLabel.frame = CGRect(x: x, y: y, width: width, height: hintHeight)
        y += hintHeight + 24.0
        self.proxyButton.frame = CGRect(x: x, y: y, width: width, height: buttonHeight)
    }
}
