import SwiftUI

/// Home on the TV — Aura-inspired shelves: Made For You first, then listening
/// rails as horizontal cover rows (no hero poster clutter).
struct TVHomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var recent: [RecentPlayEntry] = []
    @State private var playlists: [Playlist] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var dailyMixes: [DailyMix] = []
    @State private var error: String?

    private var hasCompanion: Bool { session.wishlist != nil }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 50) {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVTheme.gutter)
                }

                if hasCompanion, !dailyMixes.isEmpty {
                    TVRail(title: "Made For You", items: dailyMixes) { mix in
                        TVPosterButton(
                            title: mix.title,
                            subtitle: mix.subtitle,
                            coverArt: mix.coverArtIds.first
                                ?? mix.songs.first?.coverArt
                                ?? mix.songs.first?.id,
                            fallbackId: mix.id)
                        {
                            guard !mix.songs.isEmpty else { return }
                            player.play(
                                mix.songs,
                                startAt: 0,
                                context: PlaybackContext(label: mix.title, kind: .mix))
                            NowPlayingPresenter.open()
                        }
                    }
                }

                TVRail(title: "Vibe Tuner", items: MoodVibe.spectrum) { vibe in
                    TVPosterButton(
                        title: vibe.title,
                        subtitle: vibe.dialHint,
                        coverArt: nil,
                        fallbackId: "",
                        placeholder: vibe.symbol)
                    {
                        Task {
                            let ok = await MoodPlayer.play(vibe, session: session)
                            if ok { NowPlayingPresenter.open() }
                        }
                    }
                }

                if !recent.isEmpty {
                    TVRail(title: "Recently Played", items: recent) { entry in
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

                if !newest.isEmpty {
                    TVRail(title: "Recently Added", items: newest) { album in
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

                if !frequent.isEmpty {
                    TVRail(title: "On Repeat", items: frequent) { album in
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

                if !playlists.isEmpty {
                    TVRail(title: "Your Playlists", items: playlists) { playlist in
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
            }
            .padding(.vertical, 40)
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .background(TVTheme.canvas.ignoresSafeArea())
        .task(id: session.id) { await load() }
    }

    private func load() async {
        error = nil
        do {
            let userKey = session.account.userKey
            let db = AppEnvironment.shared.database
            async let recentTask = Task.detached(priority: .utility) {
                (try? db.recentPlayEntries(userKey: userKey, limit: 24)) ?? []
            }.value
            async let f = session.client.albumList(type: .frequent, size: 24)
            async let n = session.client.albumList(type: .newest, size: 24)
            async let p = session.client.playlists()
            let mixes: [DailyMix]
            if let wishlist = session.wishlist {
                let exclude = Array(session.rotation.excludedIDs)
                mixes = (try? await wishlist.dailyMixes(excludeSongIDs: exclude))?.mixes ?? []
            } else {
                mixes = []
            }
            let (rec, freq, neu, lists) = try await (recentTask, f, n, p)
            recent = rec
            frequent = freq
            newest = neu
            playlists = Array(lists.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }.prefix(24))
            dailyMixes = mixes
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
            if let mix = dailyMixes.first(where: { $0.title == name }), !mix.songs.isEmpty {
                player.play(mix.songs, startAt: 0, context: PlaybackContext(label: name, kind: .mix))
            } else {
                player.play([cover], startAt: 0, context: PlaybackContext(label: name, kind: .mix))
            }
        }
        NowPlayingPresenter.open()
    }
}
