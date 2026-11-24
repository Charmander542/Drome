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
    @State private var mixBusy = false

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

            if !songsReady {
                Section {
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
            } else {
                ForEach(discSections(for: visible, allSongs: allSongs), id: \.id) { section in
                    Section {
                        ForEach(section.rows, id: \.song.id) { row in
                            SongRow(song: row.song, index: row.displayTrack) {
                                player.play(
                                    allSongs,
                                    startAt: row.albumIndex,
                                    context: PlaybackContext(
                                        label: album.name, kind: .album(id: album.id)))
                            }
                            .listRowBackground(DromeTheme.background)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    } header: {
                        if let title = section.header {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DromeTheme.muted)
                                .textCase(nil)
                        }
                    }
                }

                if visibleSongCount < allSongs.count {
                    Section {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Aura QueueAllMenu + useful album actions; chrome stays Drome.
                Menu {
                    Button {
                        player.playNext(allSongs)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(!canPlay)

                    Button {
                        player.addToQueue(allSongs)
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    .disabled(!canPlay)

                    Button {
                        player.playShuffled(
                            allSongs,
                            context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                    } label: {
                        Label("Shuffle Play", systemImage: "shuffle")
                    }
                    .disabled(!canPlay)

                    Button {
                        Task { await startInstantMix(album) }
                    } label: {
                        Label("Instant Mix", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(!canPlay || mixBusy)

                    Divider()

                    Button {
                        downloads.download(
                            allSongs, albumId: album.id,
                            albumName: album.name, artist: album.artist)
                    } label: {
                        Label(
                            albumFullyDownloaded(album) ? "Downloaded" : "Download Album",
                            systemImage: albumFullyDownloaded(album)
                                ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                    .disabled(!canPlay || albumFullyDownloaded(album))
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func header(_ album: AlbumWithSongs, canPlay: Bool, songsReady: Bool) -> some View {
        VStack(spacing: 16) {
            RemoteImage(url: session.artworkURL(id: album.coverArt ?? album.id, size: 600))
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

            LibraryAlbumActionRow(
                canPlay: canPlay,
                songsReady: songsReady,
                isDownloaded: albumFullyDownloaded(album),
                mixBusy: mixBusy,
                onShuffle: {
                    player.playShuffled(
                        album.songs,
                        context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                },
                onPlay: {
                    player.play(
                        album.songs, startAt: 0,
                        context: PlaybackContext(label: album.name, kind: .album(id: album.id)))
                },
                onInstantMix: {
                    Task { await startInstantMix(album) }
                },
                onDownload: {
                    downloads.download(
                        album.songs, albumId: album.id,
                        albumName: album.name, artist: album.artist)
                }
            )
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

    private func albumFullyDownloaded(_ album: AlbumWithSongs) -> Bool {
        guard !album.songs.isEmpty else { return false }
        return album.songs.allSatisfy { downloads.isDownloaded($0.id) }
    }

    private func startInstantMix(_ album: AlbumWithSongs) async {
        guard !mixBusy, let seed = album.songs.first else { return }
        mixBusy = true
        defer { mixBusy = false }
        let mixed = await InstantMix.songs(from: seed, client: session.client)
        guard !mixed.isEmpty else { return }
        player.play(
            mixed, startAt: 0,
            context: PlaybackContext(label: "Instant Mix · \(album.name)", kind: .mix))
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
            var coverURLs = songs.prefix(24).compactMap { session.artworkURL(for: $0, size: 96) }
            if let hero = session.artworkURL(id: loaded.coverArt ?? loaded.id, size: 600) {
                coverURLs.insert(hero, at: 0)
            }
            ImageLoader.shared.prefetch(coverURLs, limit: 25, priority: .userInitiated)
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

    // MARK: - Disc / track grouping (SubSonify Reddit request)

    private struct DiscSection: Identifiable {
        var id: String
        var header: String?
        var rows: [DiscRow]
    }

    private struct DiscRow {
        var song: Song
        /// Index into the full album song array for playback.
        var albumIndex: Int
        /// Number shown in the leading column (tag track # when present).
        var displayTrack: Int
    }

    /// Groups visible songs into Disc 1 / Disc 2… when multi-disc; otherwise one untitled section.
    private func discSections(for visible: [Song], allSongs: [Song]) -> [DiscSection] {
        let indexByID = Dictionary(uniqueKeysWithValues: allSongs.enumerated().map { ($0.element.id, $0.offset) })
        let discs = Set(visible.compactMap(\.discNumber)).filter { $0 > 0 }
        let multiDisc = discs.count > 1
            || (discs.contains(where: { $0 > 1 }) && visible.contains { ($0.discNumber ?? 1) > 1 })

        if !multiDisc {
            let rows: [DiscRow] = visible.enumerated().map { position, song in
                DiscRow(
                    song: song,
                    albumIndex: indexByID[song.id] ?? position,
                    displayTrack: song.track ?? (position + 1))
            }
            return [DiscSection(id: "all", header: nil, rows: rows)]
        }

        var buckets: [(disc: Int, songs: [Song])] = []
        var order: [Int] = []
        for song in visible {
            let disc = max(1, song.discNumber ?? 1)
            if let idx = buckets.firstIndex(where: { $0.disc == disc }) {
                buckets[idx].songs.append(song)
            } else {
                buckets.append((disc, [song]))
                order.append(disc)
            }
        }
        buckets.sort { $0.disc < $1.disc }

        return buckets.map { bucket in
            let rows: [DiscRow] = bucket.songs.enumerated().map { position, song in
                DiscRow(
                    song: song,
                    albumIndex: indexByID[song.id] ?? 0,
                    displayTrack: song.track ?? (position + 1))
            }
            return DiscSection(
                id: "disc-\(bucket.disc)",
                header: "Disc \(bucket.disc)",
                rows: rows)
        }
    }
}
