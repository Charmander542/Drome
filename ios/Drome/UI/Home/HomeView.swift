import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.tabPopToRootTrigger) private var tabPopToRootTrigger
    @Environment(\.tabScrollToTopTrigger) private var tabScrollToTopTrigger

    @State private var recentEntries: [RecentPlayEntry] = []
    @State private var homePlaylists: [Playlist] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var dailyMixes: [DailyMix] = []
    @State private var dailyMixesDate: String?
    @State private var mixesLoading = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var showAccounts = false
    @State private var showSettings = false
    @State private var showTVPairing = false
    @State private var scrollToTopToken = 0

    private var hasCompanion: Bool { session.wishlist != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Color.clear.frame(height: 0).id("home-top")

                    VibeTuner()
                        .padding(.top, 4)

                    if hasCompanion {
                        DailyMixRail(mixes: dailyMixes, isLoading: mixesLoading)
                    }

                    if !recentEntries.isEmpty {
                        HorizontalRecentRail(
                            title: "Recently played",
                            entries: recentEntries,
                            dailyMixes: dailyMixes)
                    }
                    if !homePlaylists.isEmpty {
                        HorizontalPlaylistRail(title: "Playlists", playlists: homePlaylists)
                    }
                    if !frequent.isEmpty {
                        HorizontalAlbumRail(title: "Jump back in", albums: frequent)
                    }
                    if !newest.isEmpty {
                        HorizontalAlbumRail(title: "New in your library", albums: newest)
                    }

                    if let error, recentEntries.isEmpty && frequent.isEmpty && newest.isEmpty {
                        ErrorStateView(message: error) { Task { await loadAll() } }
                    } else if !isLoading && recentEntries.isEmpty && frequent.isEmpty
                                && newest.isEmpty && dailyMixes.isEmpty {
                        EmptyStateView(title: "Your library is empty",
                                       message: "Add music to Navidrome and pull to refresh.")
                            .frame(height: 220)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 72)
            }
            .onChange(of: scrollToTopToken) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("home-top", anchor: .top)
                }
            }
        }
        .task(id: session.id) { await loadAll() }
        .refreshable { await loadAll() }
        .onChange(of: tabPopToRootTrigger) { _, trigger in
            guard trigger > 0 else { return }
            dismissHomeSheets()
        }
        .onChange(of: tabScrollToTopTrigger) { _, trigger in
            guard trigger > 0 else { return }
            dismissHomeSheets()
            scrollToTopToken += 1
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAccounts = true } label: {
                        Label("Switch Account", systemImage: "person.2")
                    }
                    Button { showTVPairing = true } label: {
                        Label("Send to Apple TV", systemImage: "appletv")
                    }
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(role: .destructive) { env.signOut() } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showAccounts) {
            AccountSwitcherSheet().environmentObject(env)
        }
        .sheet(isPresented: $showTVPairing) {
            SongNavigationStack {
                TVPairingView()
                    .dromeSession(session)
                    .environmentObject(env)
            }
        }
        .sheet(isPresented: $showSettings) {
            SongNavigationStack {
                SettingsView()
                    .dromeSession(session)
                    .environmentObject(env)
            }
        }
    }

    private func dismissHomeSheets() {
        showAccounts = false
        showSettings = false
        showTVPairing = false
    }

    private func loadAll() async {
        async let home: Void = loadHome()
        async let mixes: Void = loadMixes()
        _ = await (home, mixes)
    }

    private func loadHome() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let userKey = session.account.userKey
            let db = AppEnvironment.shared.database
            async let recentTask = Task.detached(priority: .utility) {
                (try? db.recentPlayEntries(userKey: userKey, limit: 40)) ?? []
            }.value
            async let f = session.client.albumList(type: .frequent, size: 20)
            async let n = session.client.albumList(type: .newest, size: 20)
            async let p = session.client.playlists()
            let (recent, freq, neu, lists) = try await (recentTask, f, n, p)
            recentEntries = recent
            frequent = freq
            newest = neu
            homePlaylists = Self.rankedHomePlaylists(lists, recent: recent)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMixes() async {
        guard let client = session.wishlist else {
            dailyMixes = []
            mixesLoading = false
            return
        }
        if dailyMixes.isEmpty { mixesLoading = true }
        defer { mixesLoading = false }
        if session.rotation.songIDs.isEmpty {
            await session.rotation.refresh()
        }
        // OOR only for display fetch — play history applies on the next day's
        // build, not by shrinking today's cached mixes after each listen.
        let exclude = Array(session.rotation.excludedIDs)
        if let response = try? await client.dailyMixes(
            excludeSongIDs: exclude, recencyHours: PlaybackPreferences.autoplayRecencyHours
        ), !response.mixes.isEmpty {
            let cleaned = Self.withoutOutOfRotation(
                response.mixes, excluded: session.rotation.excludedIDs)
            if dailyMixesDate == response.date,
               !dailyMixes.isEmpty,
               cleaned.count < dailyMixes.count {
                return
            }
            dailyMixes = cleaned
            dailyMixesDate = response.date
        } else if dailyMixes.isEmpty {
            dailyMixes = []
            dailyMixesDate = nil
        }
    }

    /// Prefer recently played playlists, then frequently updated / larger ones.
    private static func rankedHomePlaylists(_ playlists: [Playlist],
                                            recent: [RecentPlayEntry]) -> [Playlist] {
        var recentIDs: [String] = []
        var seen = Set<String>()
        for entry in recent {
            if case .playlist(let id, _, _) = entry, seen.insert(id).inserted {
                recentIDs.append(id)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        var ordered: [Playlist] = recentIDs.compactMap { byID[$0] }
        let rest = playlists
            .filter { !seen.contains($0.id) && $0.name != RotationManager.playlistName }
            .sorted { a, b in
                let ac = a.songCount ?? 0
                let bc = b.songCount ?? 0
                if ac != bc { return ac > bc }
                return (a.changed ?? "") > (b.changed ?? "")
            }
        ordered.append(contentsOf: rest)
        return Array(ordered.prefix(20))
    }

    /// Drop Out of Rotation tracks from mixes; keep the mix card even if short.
    private static func withoutOutOfRotation(_ mixes: [DailyMix],
                                             excluded: Set<String>) -> [DailyMix] {
        guard !excluded.isEmpty else { return mixes }
        return mixes.compactMap { mix in
            let songs = mix.songs.filter { !excluded.contains($0.id) }
            guard !songs.isEmpty else { return nil }
            var cleaned = mix
            cleaned.songs = songs
            return cleaned
        }
    }
}
