import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import SolidRoundedButtonNode

// SECUTG-HOOK (PLAN.md 3.53): Si4Gram's own six-page intro replaces `RMIntroViewController` (Telegram
// paper-plane GL animation + `Tour.*` strings). The language-suggestion machinery is kept, but it is now
// driven directly by `AuthorizationSequenceSplashControllerNode` instead of RMIntro's internal button.
public final class AuthorizationSequenceSplashController: ViewController {
    private var controllerNode: AuthorizationSequenceSplashControllerNode {
        return self.displayNode as! AuthorizationSequenceSplashControllerNode
    }

    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let account: UnauthorizedAccount
    private let theme: PresentationTheme

    private var validLayout: ContainerViewLayout?

    var nextPressed: ((PresentationStrings?) -> Void)?

    private let suggestedLocalization = Promise<SuggestedLocalizationInfo?>()
    private let activateLocalizationDisposable = MetaDisposable()
    private let suggestedLocalizationDisposable = MetaDisposable()

    private let startButton: SolidRoundedButtonNode

    // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): the intro is built from `SecutgL10n.string`, which reads
    // a process-global current language that nothing set before login. Without this, the six pages and the
    // start button always rendered in English regardless of the Telegram UI language already in effect.
    init(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, theme: PresentationTheme, languageCode: String?, baseLanguageCode: String?) {
        self.accountManager = accountManager
        self.account = account
        self.theme = theme

        SecutgL10n.currentLanguageCode = SecutgL10n.map(languageCode, base: baseLanguageCode).rawValue

        self.suggestedLocalization.set(.single(nil)
        |> then(TelegramEngineUnauthorized(account: self.account).localization.currentlySuggestedLocalization(extractKeys: ["Login.ContinueWithLocalization"])))

        self.startButton = SolidRoundedButtonNode(title: SecutgL10n.string("SecutgIntroStart"), theme: SolidRoundedButtonTheme(theme: theme), glass: false, height: 50.0, cornerRadius: 50.0 * 0.5, isShimmering: true)
        self.startButton.accessibilityIdentifier = "Auth.Welcome.StartButton"

        super.init(navigationBarPresentationData: nil)

        self._hasGlassStyle = true

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)

        self.statusBar.statusBarStyle = theme.intro.statusBarStyle.style

        self.startButton.pressed = { [weak self] in
            self?.activateLocalization("en")
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.activateLocalizationDisposable.dispose()
        self.suggestedLocalizationDisposable.dispose()
    }

    public override func loadDisplayNode() {
        self.displayNode = AuthorizationSequenceSplashControllerNode(theme: self.theme, startButton: self.startButton)
        self.displayNodeDidLoad()

        self.controllerNode.alternativeLanguagePressed = { [weak self] code in
            self?.activateLocalization(code)
        }

        self.suggestedLocalizationDisposable.set((self.suggestedLocalization.get()
        |> deliverOnMainQueue).start(next: { [weak self] localization in
            guard let strongSelf = self else {
                return
            }
            guard let localization = localization, let available = localization.availableLocalizations.first, available.languageCode != "en" else {
                strongSelf.controllerNode.updateAlternativeLanguage(title: nil, code: nil)
                return
            }
            strongSelf.controllerNode.updateAlternativeLanguage(title: available.localizedTitle, code: available.languageCode)
        }))
    }

    func animateIn() {
    }

    // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): called whenever the surrounding `AuthorizationSequenceController`
    // picks up new `PresentationStrings` (e.g. after `activateLocalization` applies the suggested language), so a
    // splash instance kept alive for back navigation re-renders its six pages and button in the new language.
    func updateLanguage(languageCode: String?, baseLanguageCode: String?) {
        SecutgL10n.currentLanguageCode = SecutgL10n.map(languageCode, base: baseLanguageCode).rawValue
        self.startButton.title = SecutgL10n.string("SecutgIntroStart")
        if self.isNodeLoaded {
            self.controllerNode.refreshStrings()
        }
    }

    var buttonFrame: CGRect {
        return self.startButton.frame
    }

    var buttonTitle: String {
        return self.startButton.title ?? ""
    }

    var animationSnapshot: UIView? {
        return nil
    }

    var textSnaphot: UIView? {
        return nil
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.validLayout = layout

        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: 0.0, transition: transition)
    }

    private func activateLocalization(_ code: String) {
        let currentCode = self.accountManager.transaction { transaction -> String in
            if let current = transaction.getSharedData(SharedDataKeys.localizationSettings)?.get(LocalizationSettings.self) {
                return current.primaryComponent.languageCode
            } else {
                return "en"
            }
        }
        let suggestedCode = self.suggestedLocalization.get()
        |> map { localization -> String? in
            return localization?.availableLocalizations.first?.languageCode
        }

        let _ = (combineLatest(currentCode, suggestedCode)
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] currentCode, suggestedCode in
            guard let strongSelf = self else {
                return
            }

            if let suggestedCode = suggestedCode {
                _ = TelegramEngineUnauthorized(account: strongSelf.account).localization.markSuggestedLocalizationAsSeenInteractively(languageCode: suggestedCode).start()
            }

            if currentCode == code {
                strongSelf.pressNext(strings: nil)
                return
            }

            strongSelf.startButton.alpha = 0.6
            let accountManager = strongSelf.accountManager

            strongSelf.activateLocalizationDisposable.set(TelegramEngineUnauthorized(account: strongSelf.account).localization.downloadAndApplyLocalization(accountManager: accountManager, languageCode: code).start(completed: {
                let _ = (accountManager.transaction { transaction -> PresentationStrings? in
                    let localizationSettings: LocalizationSettings?
                    if let current = transaction.getSharedData(SharedDataKeys.localizationSettings)?.get(LocalizationSettings.self) {
                        localizationSettings = current
                    } else {
                        localizationSettings = nil
                    }
                    let stringsValue: PresentationStrings
                    if let localizationSettings = localizationSettings {
                        stringsValue = PresentationStrings(primaryComponent: PresentationStrings.Component(languageCode: localizationSettings.primaryComponent.languageCode, localizedName: localizationSettings.primaryComponent.localizedName, pluralizationRulesCode: localizationSettings.primaryComponent.customPluralizationCode, dict: dictFromLocalization(localizationSettings.primaryComponent.localization)), secondaryComponent: localizationSettings.secondaryComponent.flatMap({ PresentationStrings.Component(languageCode: $0.languageCode, localizedName: $0.localizedName, pluralizationRulesCode: $0.customPluralizationCode, dict: dictFromLocalization($0.localization)) }), groupingSeparator: "")
                    } else {
                        stringsValue = defaultPresentationStrings
                    }
                    return stringsValue
                }
                |> deliverOnMainQueue).start(next: { strings in
                    self?.startButton.alpha = 1.0
                    self?.pressNext(strings: strings)
                })
            }))
        })
    }

    private func pressNext(strings: PresentationStrings?) {
        if let navigationController = self.navigationController, navigationController.viewControllers.last === self {
            self.nextPressed?(strings)
        }
    }
}
