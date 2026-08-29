import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchSessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .nowPlaying

    private enum Tab {
        case nowPlaying
        case pick
    }

    var body: some View {
        TabView(selection: $tab) {
            WatchNowPlayingView()
                .tag(Tab.nowPlaying)

            WatchPickView()
                .tag(Tab.pick)
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            store.refreshFromPhone()
            store.startContextPolling()
        }
        .onDisappear { store.stopContextPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshFromPhone()
                store.startContextPolling()
            } else {
                store.stopContextPolling()
            }
        }
    }
}
