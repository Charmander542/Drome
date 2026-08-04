import UIKit

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
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            let config = UISceneConfiguration(
                name: "Drome-CarPlay",
                sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
