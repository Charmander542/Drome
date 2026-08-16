import UIKit
import CarPlay
import Intents

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Stored so the background download session can tell the system when all
    /// events for a background launch have been handled.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Self.backgroundSessionCompletionHandler = completionHandler
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(
                name: "Drome-CarPlay",
                sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task { @MainActor in
            DeepLink.open(url, env: AppEnvironment.shared)
        }
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return PlayMediaIntentHandler()
        }
        return nil
    }
}
