import SwiftUI
import Combine

struct MainTabView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var keyboardVisible = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                SongNavigationStack {
                    HomeView()
                }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

                SongNavigationStack {
                    SearchView()
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

                SongNavigationStack {
                    LibraryView()
                }
                .tabItem { Label("Your Library", systemImage: "rectangle.stack.fill") }
                .tag(2)
            }
            .tint(DromeTheme.accent)

            // Hide the mini player while the keyboard is up so it doesn't
            // sit on top of the keys (especially on Search).
            if player.current != nil && !keyboardVisible {
                MiniPlayerBar {
                    showNowPlaying = true
                }
                .padding(.bottom, 49)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.current?.id)
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            SongNavigationStack {
                NowPlayingView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}
