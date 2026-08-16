import SwiftUI

struct TVHomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerEngine

    @State private var recent: [RecentPlayEntry] = []
    @State private var playlists: [Playlist] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var error: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 42) {
                HStack(alignment: .firstTextBaseline) {
                    TVScreenTitle(title: greeting, subtitle: "Pick something up, or browse what’s new")
                    Spacer()
                    Button("Sign Out", role: .destructive) { env.signOut() }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, TVTheme.gutter)
                .padding(.top, 12)

                if let error {
                    Text(error).foregroundStyle(.red).padding(.horizontal, TVTheme.gutter)
                }

                if let featured = recent.first {
                    TVPosterButton(
                        title: recentTitle(featured),
                        subtitle: recentSubtitle(featured),
                        coverArt: recentCover(featured),
                        fallbackId: featured.id,
                        size: TVTheme.hero)
                    {
                        Task { await playRecent(featured) }
                    }
                    .padding(.horizontal, TVTheme.gutter)
                }

                if recent.count > 1 {
                    TVRail(title: "Recently played", items: Array(recent.dropFirst())) { entry in
                        TVPosterButton(
                            title: recentTitle(entry),
                            subtitle: recentSubtitle(entry),
                            coverArt: recentCover(entry),
                            fallbackId: entry.id)
                        {
                            Task { await playRecent(entry) }
                        }
                    }
                }

                if !playlists.isEmpty {
                    TVRail(title: "Playlists", items: playlists) { playlist in
                        TVPosterLink(
                            title: playlist.name,
                            subtitle: playlist.songCountLabel,
                            coverArt: playlist.coverArt,
                            fallbackId: playlist.id)
                        {
                            TVPlaylistDetailView(playlistID: playlist.id, name: playlist.name)
                        }
                    }
                }
                if !frequent.isEmpty {
                    TVRail(title: "Jump back in", items: frequent) { album in
                        TVPosterLink(
                            title: album.name,
                            subtitle: album.artist,
                            coverArt: album.coverArt,
                            fallbackId: album.id)
                        {
                            TVAlbumDetailView(albumID: album.id, name: album.name)
                        }
                    }
                }
                if !newest.isEmpty {
                    TVRail(title: "New in your library", items: newest) { album in
                        TVPosterLink(
                            title: album.name,
                            subtitle: album.artist,
                            coverArt: album.coverArt,
                            fallbackId: album.id)
                        {
                            TVAlbumDetailView(albumID: album.id, name: album.name)
                        }
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .task(id: session.id) { await load() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func load() async {
        error = nil
        do {
            let userKey = session.account.userKey
            let db = AppEnvironment.shared.database
            async let recentTask = Task.detached(priority: .utility) {
                (try? db.recentPlayEntries(userKey: userKey, limit: 20)) ?? []
            }.value
            async let f = session.client.albumList(type: .frequent, size: 16)
            async let n = session.client.albumList(type: .newest, size: 16)
            async let p = session.client.playlists()
            let (rec, freq, neu, lists) = try await (recentTask, f, n, p)
            recent = rec
            frequent = freq
            newest = neu
            playlists = Array(lists.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }.prefix(16))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func recentTitle(_ entry: RecentPlayEntry) -> String {
        switch entry {
        case .song(let song): return song.title
        case .album(_, let name, _): return name
        case .playlist(_, let name, _): return name
        case .mix(_, let name, _, _): return name
        }
    }

    private func recentSubtitle(_ entry: RecentPlayEntry) -> String? {
        switch entry {
        case .song(let song): return song.displayArtist
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .mix(_, _, _, let subtitle): return subtitle
        }
    }

    private func recentCover(_ entry: RecentPlayEntry) -> String? {
        switch entry {
        case .song(let song): return song.coverArt ?? song.albumId ?? song.id
        case .album(_, _, let cover): return cover.coverArt ?? cover.albumId ?? cover.id
        case .playlist(_, _, let cover): return cover.coverArt ?? cover.id
        case .mix(_, _, let cover, _): return cover.coverArt ?? cover.id
        }
    }

    private func playRecent(_ entry: RecentPlayEntry) async {
        switch entry {
        case .song(let song):
            player.play([song], startAt: 0, context: PlaybackContext(label: song.title, kind: .search))
        case .album(let id, let name, _):
            guard let album = try? await session.client.album(id: id), !album.songs.isEmpty else { return }
            player.play(album.songs, startAt: 0, context: PlaybackContext(label: name, kind: .album(id: id)))
        case .playlist(let id, let name, _):
            guard let playlist = try? await session.client.playlist(id: id), !playlist.songs.isEmpty else { return }
            player.play(playlist.songs, startAt: 0, context: PlaybackContext(label: name, kind: .playlist(id: id)))
        case .mix(_, let name, let cover, _):
            player.play([cover], startAt: 0, context: PlaybackContext(label: name, kind: .mix))
        }
        NowPlayingPresenter.open()
    }
}
