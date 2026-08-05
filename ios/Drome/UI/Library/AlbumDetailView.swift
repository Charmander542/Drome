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

    private struct ArtistNav: Hashable, Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        Group {
            if isLoading && album == nil {
                LoadingStateView()
            } else if let error, album == nil {
                ErrorStateView(message: error) { Task { await load() } }
            } else if let album {
                content(album)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $artistDestination) { dest in
            ArtistDetailView(artistID: dest.id, placeholderName: dest.name)
        }
        .task { await load() }
    }

    private func content(_ album: AlbumWithSongs) -> some View {
        List {
            Section {
                header(album)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(album.songs, startAt: index,
                                        context: PlaybackContext(label: album.name, kind: .album))
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            SpotifyMissingTracksSection(
                buttonTitle: "Find songs on this album you’re missing",
                query: spotifyAlbumQuery(album),
                ownedSongs: album.songs
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        downloads.download(album.songs, albumId: album.id,
                                           albumName: album.name, artist: album.artist)
                    } label: {
                        Label("Download Album", systemImage: "arrow.down.circle")
                    }
                    Button {
                        player.playShuffled(album.songs,
                                            context: PlaybackContext(label: album.name, kind: .album))
                    } label: {
                        Label("Shuffle Play", systemImage: "shuffle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func header(_ album: AlbumWithSongs) -> some View {
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
                                context: PlaybackContext(label: album.name, kind: .album))
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(DromeTheme.accent)
                .foregroundStyle(.white)

                Button {
                    player.playShuffled(album.songs,
                                        context: PlaybackContext(label: album.name, kind: .album))
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.white)
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
        parts.append("\(album.songs.count) songs")
        if let duration = album.duration {
            parts.append(Formatters.longDuration(seconds: duration))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await session.client.album(id: albumID)
            album = loaded
            ratings.ingest(loaded.songs)
        } catch {
            self.error = error.localizedDescription
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
