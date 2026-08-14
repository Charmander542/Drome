import SwiftUI

struct AlbumDetailView: View {
    let albumID: String
    var placeholder: Album?

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var album: AlbumWithSongs?
    @State private var error: String?
    @State private var isLoading = true
    @State private var artistDestination: ArtistNav?
    @State private var visibleSongCount = ProgressiveSongReveal.initial

    private struct ArtistNav: Hashable, Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        Group {
            if let album {
                content(album)
            } else if let placeholder, isLoading {
                content(Self.shell(from: placeholder), songsReady: false)
            } else if isLoading {
                LoadingStateView()
            } else if let error {
                ErrorStateView(message: error) { Task { await load() } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $artistDestination) { dest in
            ArtistDetailView(artistID: dest.id, placeholderName: dest.name)
        }
        .task { await load() }
    }

    private static func shell(from placeholder: Album) -> AlbumWithSongs {
        AlbumWithSongs(
            id: placeholder.id,
            name: placeholder.name,
            artist: placeholder.artist,
            artistId: placeholder.artistId,
            coverArt: placeholder.coverArt,
            songCount: placeholder.songCount,
            duration: placeholder.duration,
            year: placeholder.year,
            genre: placeholder.genre,
            userRating: placeholder.userRating,
            song: [])
    }

    private func content(_ album: AlbumWithSongs, songsReady: Bool = true) -> some View {
        let allSongs = album.songs
        let visible = Array(allSongs.prefix(visibleSongCount))
        let canPlay = songsReady && !allSongs.isEmpty

        return List {
            Section {
                header(album, canPlay: canPlay, songsReady: songsReady)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                if !songsReady {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Loading tracks…")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1) {
                            player.play(allSongs, startAt: index,
                                        context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if songsReady, visibleSongCount < allSongs.count {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 8)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .onAppear {
                        ProgressiveSongReveal.expand(
                            visibleCount: &visibleSongCount, total: allSongs.count)
                    }
                }
            }

            if songsReady {
                SpotifyMissingTracksSection(
                    buttonTitle: "Find songs on this album you’re missing",
                    query: spotifyAlbumQuery(album),
                    ownedSongs: allSongs
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        downloads.download(allSongs, albumId: album.id,
                                           albumName: album.name, artist: album.artist)
                    } label: {
                        Label("Download Album", systemImage: "arrow.down.circle")
                    }
                    .disabled(!canPlay)
                    Button {
                        player.playShuffled(allSongs,
                                            context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                    } label: {
                        Label("Shuffle Play", systemImage: "shuffle")
                    }
                    .disabled(!canPlay)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func header(_ album: AlbumWithSongs, canPlay: Bool, songsReady: Bool) -> some View {
        VStack(spacing: 16) {
            RemoteImage(url: session.client.coverArtURL(id: album.coverArt ?? album.id, size: 600))
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(album.name)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let artist = album.artist, !artist.isEmpty {
                    albumArtistLink(
                        artist: ArtistCredits.display(albumArtist: artist, artists: nil),
                        artistId: album.artistId)
                }

                HStack(spacing: 6) {
                    if let rating = album.userRating, rating > 0 {
                        RatingBadge(rating: rating, size: 11)
                    }
                    Text(metaLine(album))
                        .font(.caption)
                        .foregroundStyle(DromeTheme.muted)
                }

                StarRatingControl(rating: album.userRating ?? 0, size: 18) { newRating in
                    Task { await rateAlbum(album, rating: newRating) }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button {
                    player.play(album.songs, startAt: 0,
                                context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(DromeTheme.accent)
                .foregroundStyle(.white)
                .disabled(!canPlay)

                Button {
                    player.playShuffled(album.songs,
                                        context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                } label: {
                    Group {
                        if songsReady {
                            Label("Shuffle", systemImage: "shuffle")
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(!canPlay)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func albumArtistLink(artist: String, artistId: String?) -> some View {
        if let artistId, !artistId.isEmpty {
            // Plain button + navigationDestination avoids List’s trailing chevron
            // and keeps the name visually centered under the title.
            Button {
                artistDestination = ArtistNav(id: artistId, name: artist)
            } label: {
                Text(artist)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DromeTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        } else {
            Text(artist)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DromeTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func metaLine(_ album: AlbumWithSongs) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        let count = album.songCount ?? album.songs.count
        if count > 0 { parts.append("\(count) songs") }
        if let duration = album.duration {
            parts.append(Formatters.longDuration(seconds: duration))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if let cached = LibraryDetailCache.album(albumID) {
            album = cached
            visibleSongCount = ProgressiveSongReveal.clampInitial(total: cached.songs.count)
            isLoading = false
        } else {
            isLoading = true
        }
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await session.client.album(id: albumID)
            visibleSongCount = ProgressiveSongReveal.clampInitial(total: loaded.songs.count)
            album = loaded
            LibraryDetailCache.store(album: loaded)
            let songs = loaded.songs
            Task {
                await Task.yield()
                ratings.ingest(songs)
            }
        } catch {
            if album == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func rateAlbum(_ current: AlbumWithSongs, rating: Int) async {
        let clamped = min(5, max(0, rating))
        var updated = current
        updated.userRating = clamped == 0 ? nil : clamped
        album = updated
        do {
            try await session.client.setRating(id: current.id, rating: clamped)
        } catch {
            album = current
            self.error = error.localizedDescription
        }
    }

    private func spotifyAlbumQuery(_ album: AlbumWithSongs) -> String {
        let name = album.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (album.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if artist.isEmpty {
            return "album:\"\(name)\""
        }
        return "album:\"\(name)\" artist:\"\(artist)\""
    }
}
