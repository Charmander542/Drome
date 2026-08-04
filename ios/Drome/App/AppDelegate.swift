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
}
