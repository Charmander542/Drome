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
            if !topSongs.isEmpty {
                Section("Popular") {
                    ForEach(Array(topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, index: index + 1, showAlbum: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(topSongs, startAt: index,
                                            context: PlaybackContext(label: artist.name, kind: .artist))
                            }
                            .listRowBackground(DromeTheme.background)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }

            Section("Albums") {
                ForEach(artist.albums) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.id, placeholder: album)
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: session.client.coverArtURL(id: album.coverArt ?? album.id, size: 120))
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name).font(DromeTheme.rowTitle)
                                Text(album.year.map(String.init) ?? "")
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
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
                    guard !topSongs.isEmpty else { return }
                    player.playShuffled(topSongs,
                                        context: PlaybackContext(label: artist.name, kind: .artist))
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(topSongs.isEmpty)
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await session.client.artist(id: artistID)
            artist = loaded
            topSongs = (try? await session.client.topSongs(artistName: loaded.name, count: 10)) ?? []
            session.ratings.ingest(topSongs)

            // Pull a wider artist song sample so “missing on Spotify” filtering
            // doesn’t only know about the top-5 popular list.
            let search = try? await session.client.search(
                loaded.name, artistCount: 0, albumCount: 0, songCount: 50)
            var byID: [String: Song] = [:]
            for song in topSongs { byID[song.id] = song }
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}
