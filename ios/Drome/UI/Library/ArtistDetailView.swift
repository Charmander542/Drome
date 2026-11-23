import SwiftUI

struct ArtistDetailView: View {
    let artistID: String
    var placeholderName: String

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dromeAccent) private var dromeAccent

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

    /// Status / Dynamic Island + inline nav bar — List content starts below both.
    private var heroTopBleed: CGFloat {
        Self.windowSafeAreaInsets.top + 44
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
                    .listRowSeparator(.hidden)
            }

            Section {
                actionRow(artist)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
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
        // Let the hero draw under the Dynamic Island / status bar.
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Suppress the centered nav title over the hero art.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Hero

    private func hero(_ artist: ArtistWithAlbums) -> some View {
        let coverFallback = session.artworkURL(id: artist.coverArt ?? artist.id, size: 800)
        let bleed = heroTopBleed
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

            Text(artist.name)
                .font(.system(size: 34, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340 + bleed)
        // Negative inset pulls art under the transparent nav + Dynamic Island.
        .listRowInsets(EdgeInsets(top: -bleed, leading: 0, bottom: 0, trailing: 0))
    }

    // MARK: - Actions

    /// Compact Spotify-style chrome: small icon buttons + one primary circle.
    /// Refs: [Spotify artist](https://mobbin.com/screens/5def950c-68f1-4df1-8a04-124f53ab97c5)
    private func actionRow(_ artist: ArtistWithAlbums) -> some View {
        HStack(spacing: 18) {
            actionIconButton(
                systemImage: isFullyDownloaded ? "checkmark" : "arrow.down",
                label: isFullyDownloaded ? "Downloaded" : "Download artist",
                disabled: downloadPool.isEmpty,
                accent: isFullyDownloaded
            ) {
                downloadArtist()
            }

            actionIconButton(
                systemImage: "shuffle",
                label: "Shuffle",
                disabled: playPool.isEmpty
            ) {
                guard !playPool.isEmpty else { return }
                player.playShuffled(
                    playPool,
                    context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
            }

            Spacer(minLength: 8)

            Button {
                Task { await startInstantMix(artist) }
            } label: {
                Group {
                    if mixBusy {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 56, height: 56)
                .background(dromeAccent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(mixBusy)
            .accessibilityLabel(mixBusy ? "Mixing" : "Instant Mix")
        }
        .padding(.vertical, 2)
    }

    private func actionIconButton(
        systemImage: String,
        label: String,
        disabled: Bool = false,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(accent ? dromeAccent : Color.white.opacity(disabled ? 0.35 : 0.92))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
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

    private func resolveHeroImage(_ artist: ArtistWithAlbums) async -> URL? {
        if let cached = session.artistImages.memoryURL(artistId: artist.id) {
            return cached
        }
        if let raw = artist.artistImageUrl, let url = URL(string: raw), !raw.isEmpty {
            // Still try Spotify/wishlist upgrade, but return Navidrome URL immediately.
            let resolved = await session.artistImages.resolve(
                artistId: artist.id, name: artist.name, wishlist: session.wishlist)
            return resolved ?? url
        }
        return await session.artistImages.resolve(
            artistId: artist.id, name: artist.name, wishlist: session.wishlist)
    }

    // MARK: - Load

    private func load() async {
        if let cached = LibraryDetailCache.artist(artistID) {
            apply(
                artist: cached.artist,
                topSongs: cached.topSongs,
                owned: cached.owned,
                related: relatedArtists,
                bio: biography,
                hero: heroImageURL)
            isLoading = false
        } else {
            isLoading = true
        }
        error = nil
        defer { isLoading = false }

        do {
            // Fetch everything in parallel, then paint once — no chunked section reveals.
            let loaded = try await session.client.artist(id: artistID)

            async let topTask = session.client.topSongs(artistName: loaded.name, count: 10)
            async let searchTask = session.client.search(
                loaded.name, artistCount: 0, albumCount: 0, songCount: 40)
            async let infoTask = session.client.artistInfo2(id: loaded.id, count: 12)
            // Prefetch similar in parallel; only used if artistInfo has no peers.
            async let similarTask = session.client.similarSongs(artistId: loaded.id, count: 40)

            let fetchedTop = (try? await topTask) ?? []
            let search = try? await searchTask
            let info = try? await infoTask

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
            let owned = Array(byID.values)

            var related = (info?.similarArtists ?? []).filter { $0.id != loaded.id && !$0.id.isEmpty }
            if related.isEmpty {
                let similar = (try? await similarTask) ?? []
                related = Self.relatedArtists(from: similar, excluding: loaded.id)
            }
            let relatedFinal = Array(related.prefix(12))
            let bio = info?.plainBiography.flatMap { $0.isEmpty ? nil : $0 }

            session.ratings.ingest(fetchedTop)
            session.ratings.ingest(owned)
            LibraryDetailCache.store(artist: loaded, topSongs: fetchedTop, owned: owned)

            // Paint once with cover-art fallback; upgrade hero in the background.
            apply(
                artist: loaded,
                topSongs: fetchedTop,
                owned: owned,
                related: relatedFinal,
                bio: bio,
                hero: session.artistImages.memoryURL(artistId: loaded.id)
                    ?? loaded.artistImageUrl.flatMap(URL.init(string:)))
            isLoading = false

            if let upgraded = await resolveHeroImage(loaded) {
                heroImageURL = upgraded
            }
        } catch {
            if artist == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(
        artist: ArtistWithAlbums,
        topSongs: [Song],
        owned: [Song],
        related: [Artist],
        bio: String?,
        hero: URL?
    ) {
        self.artist = artist
        self.topSongs = topSongs
        self.ownedSongs = owned
        self.relatedArtists = related
        self.biography = bio
        if let hero {
            self.heroImageURL = hero
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
