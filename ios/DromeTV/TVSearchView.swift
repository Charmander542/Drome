import SwiftUI

struct TVSearchView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var wishlistHits: [SpotifySearchHit] = []
    @State private var addingID: String?

    private var songs: [SearchHit] { hits.filter { $0.kind == .song } }
    private var albums: [SearchHit] { hits.filter { $0.kind == .album } }
    private var artists: [SearchHit] { hits.filter { $0.kind == .artist } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            TextField("Search songs, albums, artists", text: $query)
                .padding(.horizontal, TVTheme.gutter)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if !artists.isEmpty {
                        hitRail(title: "Artists", items: artists)
                    }
                    if !albums.isEmpty {
                        hitRail(title: "Albums", items: albums)
                    }
                    if !songs.isEmpty {
                        hitRail(title: "Songs", items: songs)
                    }
                    if session.wishlist != nil, !wishlistHits.isEmpty {
                        Text("Add to wishlist")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .padding(.horizontal, TVTheme.gutter)
                        ForEach(wishlistHits) { hit in
                            Button {
                                Task { await addWishlist(hit) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(hit.title).font(.title3.weight(.semibold))
                                        Text(hit.artist).foregroundStyle(TVTheme.dim)
                                    }
                                    Spacer()
                                    Text(addingID == hit.spotifyId ? "Adding…" : "Add")
                                }
                                .padding(.horizontal, TVTheme.gutter)
                            }
                            .buttonStyle(.plain)
                            .disabled(addingID != nil)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .onChange(of: query) { _, newValue in
            Task { await search(newValue) }
        }
    }

    private func hitRail(title: String, items: [SearchHit]) -> some View {
        TVRail(title: title, items: items) { hit in
            TVPosterButton(
                title: hit.title,
                subtitle: hit.subtitle,
                coverArt: hit.coverArt,
                fallbackId: hit.id)
            {
                Task { await open(hit) }
            }
        }
    }

    private func search(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            hits = []
            wishlistHits = []
            return
        }
        if let result = try? await session.client.search(q, artistCount: 8, albumCount: 8, songCount: 20) {
            hits = SearchRanker.rank(query: q, result: result)
        }
        if hits.isEmpty, let wishlist = session.wishlist {
            wishlistHits = (try? await wishlist.search(query: q, types: "track", limit: 6)) ?? []
        } else {
            wishlistHits = []
        }
    }

    private func open(_ hit: SearchHit) async {
        switch hit.kind {
        case .song:
            if let song = hit.song {
                player.play([song], startAt: 0, context: PlaybackContext(label: song.title, kind: .search))
                NowPlayingPresenter.open()
            }
        case .album:
            if let album = hit.album,
               let loaded = try? await session.client.album(id: album.id),
               !loaded.songs.isEmpty {
                player.play(loaded.songs, startAt: 0,
                            context: PlaybackContext(label: loaded.name, kind: .album(id: loaded.id)))
                NowPlayingPresenter.open()
            }
        case .artist:
            if let artist = hit.artist,
               let songs = try? await session.client.topSongs(artistName: artist.name),
               !songs.isEmpty {
                player.play(songs, startAt: 0,
                            context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
                NowPlayingPresenter.open()
            }
        case .lyrics:
            break
        }
    }

    private func addWishlist(_ hit: SpotifySearchHit) async {
        guard let wishlist = session.wishlist else { return }
        addingID = hit.spotifyId
        defer { addingID = nil }
        _ = try? await wishlist.add(spotifyLink: hit.spotifyUrl)
    }
}
