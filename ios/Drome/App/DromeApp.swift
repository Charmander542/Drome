import SwiftUI

@main
struct DromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(env)
                    .environmentObject(env.accounts)

                SplashOverlay(isVisible: $showSplash)
            }
            .task {
                // Brief hold so launch → first frame stays on-brand, then fade.
                try? await Task.sleep(nanoseconds: 700_000_000)
                showSplash = false
            }
        }
    }
}
