import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment

    @State private var recentEntries: [RecentPlayEntry] = []
    @State private var homePlaylists: [Playlist] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showAccounts = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if isLoading && recentEntries.isEmpty && newest.isEmpty {
                LoadingStateView()
            } else if let error, recentEntries.isEmpty && frequent.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(greetingText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .padding(.horizontal, 16)
                            .padding(.top, 4)

                        MoodVibeRail()

                        if !recentEntries.isEmpty {
                            HorizontalRecentRail(title: "Recently played", entries: recentEntries)
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
                        if recentEntries.isEmpty && frequent.isEmpty && newest.isEmpty {
                            EmptyStateView(title: "Your library is empty",
                                           message: "Add music to Navidrome and pull to refresh.")
                                .frame(height: 280)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.bottom, 72)
                }
            }
        }
        .task(id: session.id) { await load() }
        .refreshable { await load() }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAccounts = true } label: {
                        Label("Switch Account", systemImage: "person.2")
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
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .dromeSession(session)
                    .environmentObject(env)
            }
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello: String
        switch hour {
        case 5..<12: hello = "Good morning"
        case 12..<17: hello = "Good afternoon"
        default: hello = "Good evening"
        }
        return "\(hello), \(session.account.username)"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            recentEntries = (try? AppEnvironment.shared.database.recentPlayEntries(
                userKey: session.account.userKey, limit: 40)) ?? []
            async let f = session.client.albumList(type: .frequent, size: 20)
            async let n = session.client.albumList(type: .newest, size: 20)
            async let p = session.client.playlists()
            let (freq, neu, lists) = try await (f, n, p)
            frequent = freq
            newest = neu
            homePlaylists = Self.rankedHomePlaylists(lists, recent: recentEntries)
        } catch {
            self.error = error.localizedDescription
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
