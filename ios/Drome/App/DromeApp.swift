import SwiftUI

@main
struct DromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = AppEnvironment()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(env)
                    .environmentObject(env.accounts)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .zIndex(1)
                }
            }
            .onOpenURL { DeepLink.open($0, env: env) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    DeepLink.open(url, env: env)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    DeepLink.consumePending(env: env)
                }
            }
        }
    }
}
