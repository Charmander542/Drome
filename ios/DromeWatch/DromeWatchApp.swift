import SwiftUI

@main
struct DromeWatchApp: App {
    init() {
        WatchSessionStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(WatchSessionStore.shared)
        }
    }
}
