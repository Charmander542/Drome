import SwiftUI

struct ArtistDetailView: View {
    let artistID: String
    var placeholderName: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager

    @State private var artist: ArtistWithAlbums?
    @State private var topSongs: [Song] = []
    /// Broader set of library tracks for this artist (for Spotify missing filter + download).
    @State private var ownedSongs: [Song] = []
    @State private var relatedArtists: [Artist] = []
    @State private var biography: String?
    @State private var heroImageURL: URL?
    @State private var showFullBio = false
    @State private var mixBusy = false
    @State private var error: String?
    @State private var isLoading = true

    private var playPool: [Song] {
        topSongs.isEmpty ? ownedSongs : topSongs
    }

    private var downloadPool: [Song] {
        ownedSongs.isEmpty ? topSongs : ownedSongs
    }

    private var isFullyDownloaded: Bool {
        guard !downloadPool.isEmpty else { return false }
        return downloadPool.allSatisfy { downloads.isDownloaded($0.id) }
    }

    private var topSafeArea: CGFloat {
        Self.windowSafeAreaInsets.top
    }

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
        // Name lives on the full-bleed hero; navigationTitle still labels the back
        // button when pushing discography / related artists.
        .navigationTitle(artist?.name ?? placeholderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func content(_ artist: ArtistWithAlbums) -> some View {
        List {
            Section {
                hero(artist)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            Section {
                actionRow(artist)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }

            if !topSongs.isEmpty {
                Section {
                    Text("Popular")
                        .font(DromeTheme.headlineFont)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

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

            if !artist.albums.isEmpty {
                Section {
                    HorizontalAlbumRail(
                        title: "Discography",
                        albums: sortedAlbums(artist.albums),
                        showsReleaseMeta: true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            if !relatedArtists.isEmpty {
                Section {
                    HorizontalArtistRail(title: "Fans also like", artists: relatedArtists)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            if let biography, !biography.isEmpty {
                Section {
                    aboutSection(biography)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
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
        .contentMargins(.top, 0, for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Suppress the centered nav title over the hero art.
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    // MARK: - Hero

    private func hero(_ artist: ArtistWithAlbums) -> some View {
        let coverFallback = session.artworkURL(id: artist.coverArt ?? artist.id, size: 800)
        let bleed = topSafeArea
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                RemoteImage(
                    url: heroImageURL ?? coverFallback,
                    placeholderSymbol: "person.crop.rectangle",
                    holdImageWhileLoading: true)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    .clear,
                    DromeTheme.background.opacity(0.55),
                    DromeTheme.background,
                ],
                startPoint: .top,
                endPoint: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                Text(artist.name)
                    .font(.system(size: 34, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)

                if let count = artist.albumCount, count > 0 {
                    Text(count == 1 ? "1 album in library" : "\(count) albums in library")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340 + bleed)
        // Pull under the status / nav chrome so art is edge-to-edge at the top.
        .padding(.top, -bleed)
        .task(id: artist.id) {
            await resolveHeroImage(artist)
        }
    }

    // MARK: - Actions

    private func actionRow(_ artist: ArtistWithAlbums) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await startInstantMix(artist) }
            } label: {
                Label {
                    Text(mixBusy ? "Mixing…" : "Instant Mix")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(DromeTheme.accent)
            .foregroundStyle(.white)
            .disabled(mixBusy)

            Button {
                guard !playPool.isEmpty else { return }
                player.playShuffled(playPool,
                                    context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(playPool.isEmpty)

            // Plain arrow (not arrow.down.circle) — bordered already supplies chrome.
            Button {
                downloadArtist()
            } label: {
                Image(systemName: isFullyDownloaded ? "checkmark" : "arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.bordered)
            .tint(isFullyDownloaded ? DromeTheme.accent : .white)
            .disabled(downloadPool.isEmpty)
            .accessibilityLabel(isFullyDownloaded ? "Downloaded" : "Download artist")
        }
    }

    private func aboutSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(DromeTheme.headlineFont)
                .foregroundStyle(.white)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(DromeTheme.muted)
                .lineLimit(showFullBio ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if text.count > 180 || text.contains("\n") {
                Button(showFullBio ? "Show less" : "Show more") {
                    withAnimation(DromeTheme.Motion.expand) {
                        showFullBio.toggle()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DromeTheme.accent)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions helpers

    private func downloadArtist() {
        guard !downloadPool.isEmpty else { return }
        let name = artist?.name ?? placeholderName
        downloads.download(downloadPool, artist: name)
    }

    private func startInstantMix(_ artist: ArtistWithAlbums) async {
        guard !mixBusy else { return }
        mixBusy = true
        defer { mixBusy = false }
        var songs = await InstantMix.songs(fromArtistId: artist.id, client: session.client)
        if songs.isEmpty, let seed = playPool.first {
            songs = await InstantMix.songs(from: seed, client: session.client)
        }
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: 0,
                    context: PlaybackContext(label: "Instant Mix · \(artist.name)", kind: .mix))
    }

    private func sortedAlbums(_ albums: [Album]) -> [Album] {
        albums.sorted { lhs, rhs in
            let ly = lhs.year ?? 0
            let ry = rhs.year ?? 0
            if ly != ry { return ly > ry }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func resolveHeroImage(_ artist: ArtistWithAlbums) async {
        if let cached = session.artistImages.memoryURL(artistId: artist.id) {
            heroImageURL = cached
            return
        }
        if let raw = artist.artistImageUrl, let url = URL(string: raw), !raw.isEmpty {
            heroImageURL = url
        }
        let resolved = await session.artistImages.resolve(
            artistId: artist.id, name: artist.name, wishlist: session.wishlist)
        if let resolved {
            heroImageURL = resolved
        }
    }

    // MARK: - Load

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
            // Albums first so the page is usable; popular/owned/info fill in after.
            let loaded = try await session.client.artist(id: artistID)
            artist = loaded
            isLoading = false

            async let topTask = session.client.topSongs(artistName: loaded.name, count: 10)
            async let searchTask = session.client.search(
                loaded.name, artistCount: 0, albumCount: 0, songCount: 40)
            async let infoTask = session.client.artistInfo2(id: loaded.id, count: 12)

            // Paint popular + unlock download as soon as top songs arrive.
            let fetchedTop = (try? await topTask) ?? []
            topSongs = fetchedTop
            if ownedSongs.isEmpty {
                ownedSongs = fetchedTop
            }
            session.ratings.ingest(fetchedTop)
            LibraryDetailCache.store(artist: loaded, topSongs: topSongs, owned: ownedSongs)

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

            let info = try? await infoTask
            if let plain = info?.plainBiography, !plain.isEmpty {
                biography = plain
            }
            var related = (info?.similarArtists ?? []).filter { $0.id != loaded.id && !$0.id.isEmpty }
            if related.isEmpty {
                // Only hit similarSongs when Last.fm / agents didn’t return peers.
                let similar = (try? await session.client.similarSongs(artistId: loaded.id, count: 40)) ?? []
                related = Self.relatedArtists(from: similar, excluding: loaded.id)
            }
            relatedArtists = Array(related.prefix(12))
        } catch {
            if artist == nil {
                self.error = error.localizedDescription
            }
        }
    }

    /// Fallback “Fans also like” when Last.fm / agents aren’t configured.
    private static func relatedArtists(from songs: [Song], excluding artistId: String) -> [Artist] {
        var seen = Set<String>()
        var out: [Artist] = []
        for song in songs {
            guard let id = song.artistId, !id.isEmpty, id != artistId else { continue }
            guard seen.insert(id).inserted else { continue }
            out.append(Artist(
                id: id,
                name: song.artist ?? song.displayArtist,
                albumCount: nil,
                coverArt: song.coverArt,
                artistImageUrl: nil))
            if out.count >= 12 { break }
        }
        return out
    }

    private static var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }
}
