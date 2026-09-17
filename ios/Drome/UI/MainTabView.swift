import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var showPodcastNowPlaying = false
    @State private var keyboardVisible = false
    @State private var wasInBackground = false
    /// Bumped when the user re-taps an already-selected tab (pop to root).
    @State private var tabPopTriggers = [0, 0, 0, 0]

    /// Active bottom chrome: podcast wins while an episode is loaded so it
    /// replaces the music mini (music only pauses — `current` stays set).
    private var activeMiniPlayer: MiniPlayerKind {
        MiniPlayerKind.resolve(
            hasMusicCurrent: player.current != nil,
            hasPodcastEpisode: podcastPlayer.currentEpisode != nil)
    }

    private var switchPromptBinding: Binding<Bool> {
        Binding(
            get: { session.connect?.showSwitchPrompt == true },
            set: { newValue in
                if !newValue { session.connect?.declineSwitchPrompt() }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !connectivity.isOnline {
                disconnectedBanner
            }

            if connectivity.isOnline {
                TabView(selection: $selectedTab) {
                    SongNavigationStack(popToRootTrigger: tabPopTriggers[0]) {
                        HomeView()
                    }
                    .tag(0)

                    SongNavigationStack(popToRootTrigger: tabPopTriggers[1]) {
                        SearchView()
                    }
                    .tag(1)

                    SongNavigationStack(popToRootTrigger: tabPopTriggers[2]) {
                        LibraryView()
                    }
                    .tag(2)

                    SongNavigationStack(popToRootTrigger: tabPopTriggers[3]) {
                        PodcastsView()
                            .environmentObject(podcastManager)
                            .environmentObject(podcastPlayer)
                    }
                    .tag(3)
                }
                // Hide Apple's tab bar entirely (liquid glass included).
                .toolbar(.hidden, for: .tabBar)
                .tint(DromeTheme.accent)
            } else {
                SongNavigationStack {
                    DownloadsView(isOfflineMode: true)
                }
            }
        }
        // One bottom stack: mini player sits directly on the menu bar.
        // Clear chrome behind the pill so we don't get a black strip.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                switch activeMiniPlayer {
                case .music:
                    MiniPlayerBar {
                        withAnimation(.easeOut(duration: 0.32)) {
                            showPodcastNowPlaying = false
                            showNowPlaying = true
                        }
                    }
                    .opacity(keyboardVisible ? 0 : 1)
                    .allowsHitTesting(!keyboardVisible)
                    .accessibilityHidden(keyboardVisible)
                    .accessibilityIdentifier("music-mini-player")
                    .animation(nil, value: keyboardVisible)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.current?.id)
                case .podcast:
                    PodcastMiniPlayerBar {
                        withAnimation(.easeOut(duration: 0.32)) {
                            showNowPlaying = false
                            showPodcastNowPlaying = true
                        }
                    }
                    .opacity(keyboardVisible ? 0 : 1)
                    .allowsHitTesting(!keyboardVisible)
                    .accessibilityHidden(keyboardVisible)
                    .accessibilityIdentifier("podcast-mini-player")
                    .animation(nil, value: keyboardVisible)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: podcastPlayer.currentEpisode?.id)
                case .none:
                    EmptyView()
                }

                if connectivity.isOnline {
                    solidTabBar
                        .opacity(keyboardVisible ? 0 : 1)
                        .allowsHitTesting(!keyboardVisible)
                        .accessibilityHidden(keyboardVisible)
                }
            }
            .background(Color.clear)
        }
        .environment(
            \.miniPlayerClearance,
            activeMiniPlayer != .none ? MiniPlayerMetrics.clearanceHeight : 0
        )
        .overlay {
            if showNowPlaying {
                NowPlayingView {
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) { showNowPlaying = false }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom),
                    removal: .identity))
            } else if showPodcastNowPlaying {
                PodcastNowPlayingView {
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) { showPodcastNowPlaying = false }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom),
                    removal: .identity))
            }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeOpenNowPlaying)) { _ in
            if player.current != nil {
                withAnimation(.easeOut(duration: 0.32)) {
                    showPodcastNowPlaying = false
                    showNowPlaying = true
                }
            } else if podcastPlayer.currentEpisode != nil {
                withAnimation(.easeOut(duration: 0.32)) {
                    showNowPlaying = false
                    showPodcastNowPlaying = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeFocusCarPlaySearch)) { _ in
            selectedTab = 1
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
            case .active:
                if wasInBackground, !showNowPlaying, !showPodcastNowPlaying {
                    if player.isPlaying, player.current != nil {
                        withAnimation(.easeOut(duration: 0.32)) {
                            showNowPlaying = true
                        }
                    } else if podcastPlayer.isPlaying, podcastPlayer.currentEpisode != nil {
                        withAnimation(.easeOut(duration: 0.32)) {
                            showPodcastNowPlaying = true
                        }
                    }
                }
                wasInBackground = false
            default:
                break
            }
        }
        .onChange(of: podcastPlayer.currentEpisode?.id) { _, newID in
            if newID == nil { showPodcastNowPlaying = false }
        }
        .onChange(of: player.current?.id) { _, newID in
            if newID == nil { showNowPlaying = false }
        }
        .onAppear {
            Self.applyUITestHooksIfNeeded(podcastPlayer: podcastPlayer)
        }
    }

    /// Simulator / XCUITest hooks for verifying mini-player chrome.
    private static func applyUITestHooksIfNeeded(podcastPlayer: PodcastPlayer) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITestPodcastMini") else { return }

        let feed = "https://example.com/uitest-feed.xml"
        let episode = PodcastEpisode(
            id: "uitest-episode",
            showID: feed,
            title: "UITest Episode — Mini Player",
            description: nil,
            pubDate: Date(),
            duration: 3600,
            audioURL: URL(string: "https://example.com/uitest.mp3")!,
            imageURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Podcasts126/v4/f1/5a/2c/f15a2c0e-0d5e-0e5e-5e0e-0e5e0e5e0e5e/mza_default.png/200x200bb.jpg"),
            episodeNumber: 1,
            seasonNumber: 1,
            episodeType: "full",
            explicit: false,
            fileSize: nil,
            mimeType: "audio/mpeg",
            playbackPosition: 900
        )
        podcastPlayer.adoptEpisodeForChrome(episode, elapsed: 900, duration: 3600, playing: true)
    }

    private var solidTabBar: some View {
        HStack(spacing: 0) {
            solidTabItem(tag: 0, title: "Home", systemImage: "house.fill")
            solidTabItem(tag: 1, title: "Search", systemImage: "magnifyingglass")
            solidTabItem(tag: 2, title: "Your Library", systemImage: "rectangle.stack.fill")
            solidTabItem(tag: 3, title: "Podcasts", systemImage: "headphones")
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            DromeTheme.elevated
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(DromeTheme.divider)
                        .frame(height: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }

    private func solidTabItem(tag: Int, title: String, systemImage: String) -> some View {
        let selected = selectedTab == tag
        return Button {
            selectTab(tag)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? DromeTheme.accent : DromeTheme.muted)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectTab(_ tag: Int) {
        if selectedTab == tag {
            guard tabPopTriggers.indices.contains(tag) else { return }
            var triggers = tabPopTriggers
            triggers[tag] += 1
            tabPopTriggers = triggers
        } else {
            selectedTab = tag
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

/// Which bottom mini player owns chrome when both engines have state.
enum MiniPlayerKind: Equatable {
    case none
    case music
    case podcast

    static func resolve(hasMusicCurrent: Bool, hasPodcastEpisode: Bool) -> MiniPlayerKind {
        // Podcast session replaces music chrome while an episode is loaded.
        if hasPodcastEpisode { return .podcast }
        if hasMusicCurrent { return .music }
        return .none
    }
}
