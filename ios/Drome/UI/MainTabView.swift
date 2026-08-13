import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var keyboardVisible = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !connectivity.isOnline {
                    disconnectedBanner
                }

                if connectivity.isOnline {
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
                } else {
                    SongNavigationStack {
                        DownloadsView(isOfflineMode: true)
                    }
                }
            }

            // Keep the mini player in the hierarchy while the keyboard is up.
            // Removing it (or animating a move transition) relayouts `.searchable`
            // mid-presentation and delays the keyboard / first keystroke.
            if player.current != nil {
                MiniPlayerBar {
                    showNowPlaying = true
                }
                .padding(.bottom, connectivity.isOnline ? 49 : 0)
                .opacity(keyboardVisible ? 0 : 1)
                .allowsHitTesting(!keyboardVisible)
                .accessibilityHidden(keyboardVisible)
                .animation(nil, value: keyboardVisible)
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
        .onReceive(NotificationCenter.default.publisher(for: .dromeOpenNowPlaying)) { _ in
            showNowPlaying = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeFocusCarPlaySearch)) { _ in
            selectedTab = 1
        }
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
            Text("Disconnected")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Text("Showing downloads")
                .font(.caption)
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(DromeTheme.accent.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disconnected. Showing downloaded music.")
    }
}
