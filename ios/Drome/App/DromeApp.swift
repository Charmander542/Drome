import SwiftUI

@main
struct DromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            // System `UILaunchScreen` only — no second in-app splash overlay
            // (that one never lined up with the launch image).
            RootView()
                .environmentObject(env)
                .environmentObject(env.accounts)
                .onOpenURL { DeepLink.open($0, env: env) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        DeepLink.open(url, env: env)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        DromeDiagnostics.log("scene active")
                        DeepLink.consumePending(env: env)
                    case .inactive:
                        DromeDiagnostics.log("scene inactive")
                    case .background:
                        DromeDiagnostics.log("scene background")
                    @unknown default:
                        break
                    }
                }
        }
    }
}
