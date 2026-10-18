import Foundation
import UIKit

// SECUTG-HOOK (scene lifecycle): apps linked against the iOS 27 SDK are terminated at launch on iOS 27 unless
// they adopt the UIScene lifecycle. Si4Gram has one window scene; this delegate attaches the existing main window
// to it and forwards the callbacks UIKit no longer sends to the app delegate (lifecycle, URLs, user activities,
// Home Screen quick actions) to the unchanged AppDelegate implementations.
@objc(SceneDelegate) final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow? {
        get {
            return self.appDelegate?.window
        }
        set {
        }
    }

    private var appDelegate: AppDelegate? {
        return UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let appDelegate = self.appDelegate else {
            return
        }
        appDelegate.attachMainWindow(to: windowScene)

        if !connectionOptions.urlContexts.isEmpty {
            self.scene(scene, openURLContexts: connectionOptions.urlContexts)
        }
        for userActivity in connectionOptions.userActivities {
            self.scene(scene, continue: userActivity)
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            appDelegate.application(UIApplication.shared, performActionFor: shortcutItem, completionHandler: { _ in })
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        self.appDelegate?.applicationDidBecomeActive(UIApplication.shared)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        self.appDelegate?.applicationWillResignActive(UIApplication.shared)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        self.appDelegate?.applicationWillEnterForeground(UIApplication.shared)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        self.appDelegate?.applicationDidEnterBackground(UIApplication.shared)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let appDelegate = self.appDelegate else {
            return
        }
        for context in URLContexts {
            var options: [UIApplication.OpenURLOptionsKey: Any] = [:]
            if let sourceApplication = context.options.sourceApplication {
                options[.sourceApplication] = sourceApplication
            }
            if let annotation = context.options.annotation {
                options[.annotation] = annotation
            }
            options[.openInPlace] = context.options.openInPlace
            let _ = appDelegate.application(UIApplication.shared, open: context.url, options: options)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        let _ = self.appDelegate?.application(UIApplication.shared, continue: userActivity, restorationHandler: { _ in })
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let appDelegate = self.appDelegate else {
            completionHandler(false)
            return
        }
        appDelegate.application(UIApplication.shared, performActionFor: shortcutItem, completionHandler: completionHandler)
    }

    @available(iOS 26.0, *)
    func preferredWindowingControlStyle(for windowScene: UIWindowScene) -> UIWindowScene.WindowingControlStyle {
        return .minimal
    }
}
