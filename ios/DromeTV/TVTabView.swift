import SwiftUI

struct TVTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @State private var tab: String = "home"

    private var switchPromptBinding: Binding<Bool> {
        Binding(
            get: { session.connect?.showSwitchPrompt == true },
            set: { newValue in
                if !newValue { session.connect?.declineSwitchPrompt() }
            }
        )
    }

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
        .alert(
            "Switch playback?",
            isPresented: switchPromptBinding
        ) {
            Button("Play here") {
                session.connect?.confirmSwitchToThisDevice()
            }
            Button("Cancel", role: .cancel) {
                session.connect?.declineSwitchPrompt()
            }
        } message: {
            Text("\(session.connect?.switchPromptDeviceName ?? "Another device") is the current player. Switch playback to this device?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeOpenNowPlaying)) { _ in
            guard player.current != nil else { return }
            tab = "playing"
        }
    }
}
