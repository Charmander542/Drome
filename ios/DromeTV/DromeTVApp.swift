import SwiftUI

@main
struct DromeTVApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(env)
                .environmentObject(env.accounts)
                .dromeScreen()
                .background(TVTheme.canvas.ignoresSafeArea())
        }
    }
}
