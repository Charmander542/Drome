import SwiftUI

struct ArtistDetailView: View {
    let artistID: String
    var placeholderName: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine

    @State private var artist: ArtistWithAlbums?
    @State private var topSongs: [Song] = []
    /// Broader set of library tracks for this artist (for Spotify missing filter).
    @State private var ownedSongs: [Song] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && artist == nil {
                LoadingStateView()
            } else if let error, artist == nil {
                ErrorStateView(message: error) { Task { await load() } }
            } else if let artist {
                content(artist)
            }
        }
        .navigationTitle(artist?.name ?? placeholderName)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private func content(_ artist: ArtistWithAlbums) -> some View {
        List {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    ArtistAvatar(artistId: artist.id, name: artist.name,
                                 size: 120, navidromeCoverArt: artist.coverArt,
                                 allowsSpotifyLookup: true)
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if !topSongs.isEmpty {
                Section("Popular") {
                    ForEach(Array(topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, index: index + 1, showAlbum: true) {
                                player.play(topSongs, startAt: index,
                                            context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
                            }
                            .listRowBackground(DromeTheme.background)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }

            Section("Albums") {
                ForEach(artist.albums) { album in
                    AlbumMediaRow(
                        album: album,
                        subtitle: album.year.map(String.init),
                        artistTappable: false
                    )
                    .listRowBackground(DromeTheme.background)
                }
            }

            SpotifyMissingTracksSection(
                buttonTitle: "Find popular songs you don’t have",
                query: "artist:\"\(artist.name)\"",
                ownedSongs: ownedSongs
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let pool = topSongs.isEmpty ? ownedSongs : topSongs
                    guard !pool.isEmpty else { return }
                    player.playShuffled(pool,
                                        context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(topSongs.isEmpty && ownedSongs.isEmpty)
            }
        }
    }

    private func load() async {
        if let cached = LibraryDetailCache.artist(artistID) {
            artist = cached.artist
            topSongs = cached.topSongs
            ownedSongs = cached.owned
            isLoading = false
        } else {
            isLoading = true
        }
        error = nil
        defer { isLoading = false }
        do {
            // Albums first so the page is usable; popular/owned fill in after.
            let loaded = try await session.client.artist(id: artistID)
            artist = loaded
            isLoading = false

            async let topTask = session.client.topSongs(artistName: loaded.name, count: 10)
            async let searchTask = session.client.search(
                loaded.name, artistCount: 0, albumCount: 0, songCount: 50)

            let fetchedTop = (try? await topTask) ?? []
            topSongs = fetchedTop
            session.ratings.ingest(fetchedTop)

            let search = try? await searchTask
            var byID: [String: Song] = [:]
            for song in fetchedTop { byID[song.id] = song }
            for song in search?.songs ?? [] {
                let artistMatch = song.displayArtist
                    .localizedCaseInsensitiveContains(loaded.name)
                    || (song.artist?.localizedCaseInsensitiveContains(loaded.name) ?? false)
                if artistMatch {
                    byID[song.id] = song
                }
            }
            ownedSongs = Array(byID.values)
            session.ratings.ingest(ownedSongs)
            LibraryDetailCache.store(artist: loaded, topSongs: topSongs, owned: ownedSongs)
        } catch {
            if artist == nil {
                self.error = error.localizedDescription
            }
        }
    }
}
