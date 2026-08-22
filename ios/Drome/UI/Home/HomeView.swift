import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment

    @State private var recentEntries: [RecentPlayEntry] = []
    @State private var homePlaylists: [Playlist] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var dailyMixes: [DailyMix] = []
    @State private var mixesLoading = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var showAccounts = false
    @State private var showSettings = false
    @State private var showTVPairing = false

    private var hasCompanion: Bool { session.wishlist != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VibeTuner()
                    .padding(.top, 4)

                if hasCompanion && (!dailyMixes.isEmpty || mixesLoading) {
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
        .task(id: session.id) { await loadAll() }
        .refreshable { await loadAll() }
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
        if let mixes = try? await client.dailyMixes().mixes, !mixes.isEmpty {
            dailyMixes = mixes
        } else if dailyMixes.isEmpty {
            dailyMixes = []
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
}
