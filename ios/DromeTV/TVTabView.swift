import SwiftUI

struct TVTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerEngine
    @State private var tab: String = "home"

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TVHomeView()
            }
            .tabItem { Text("Home") }
            .tag("home")

            NavigationStack {
                TVSearchView()
            }
            .tabItem { Text("Search") }
            .tag("search")

            NavigationStack {
                TVLibraryView()
            }
            .tabItem { Text("Library") }
            .tag("library")

            TVNowPlayingView()
                .tabItem { Text("Playing") }
                .tag("playing")
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeOpenNowPlaying)) { _ in
            guard player.current != nil else { return }
            tab = "playing"
        }
    }
}
