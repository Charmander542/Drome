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

    /// Library tracks that aren’t already in the Top Songs preview.
    private var allSongsPreview: [Song] {
        let topIDs = Set(topSongs.prefix(5).map(\.id))
        let rest = ownedSongs.filter { !topIDs.contains($0.id) }
        return rest.isEmpty ? ownedSongs : rest
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
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            if !artist.albums.isEmpty {
                Section {
                    HorizontalAlbumRail(
                        title: nil,
                        albums: sortedAlbums(artist.albums),
                        showsReleaseMeta: false,
                        cardWidth: 140)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                }
            }

            if !topSongs.isEmpty {
                songSection(
                    title: "Top Songs",
                    songs: topSongs,
                    artist: artist)
            }

            if allSongsPreview.count > 1 || (topSongs.isEmpty && !ownedSongs.isEmpty) {
                songSection(
                    title: "All Songs",
                    songs: ownedSongs.isEmpty ? allSongsPreview : ownedSongs,
                    artist: artist)
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

    @ViewBuilder
    private func songSection(
        title: String,
        songs: [Song],
        artist: ArtistWithAlbums
    ) -> some View {
        Section {
            songSectionHeader(title: title, songs: songs, artistName: artist.name)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)

            // YouTube Music / Qobuz-style: swipe sideways through pages of song rows.
            ArtistSongPagesRail(
                songs: songs,
                pageSize: 4,
                artistName: artist.name,
                artistID: artist.id)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    private func songSectionHeader(title: String, songs: [Song], artistName: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if songs.count > 4 {
                NavigationLink {
                    ArtistSongsListView(
                        title: title,
                        artistName: artistName,
                        artistID: artistID,
                        songs: songs)
                } label: {
                    HStack(spacing: 2) {
                        Text("See All")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(DromeTheme.muted)
                }
            }
        }
    }

    // MARK: - Hero

    private func hero(_ artist: ArtistWithAlbums) -> some View {
        let coverFallback = session.artworkURL(id: artist.coverArt ?? artist.id, size: 800)
        let bleed = heroTopBleed
        // Taller frame + slight downward bias so faces / subjects aren’t cropped off the top.
        let heroBody: CGFloat = 400
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                RemoteImage(
                    url: heroImageURL ?? coverFallback,
                    placeholderSymbol: "person.crop.rectangle",
                    holdImageWhileLoading: true)
                    // Draw taller than the slot, then nudge down so more of the
                    // upper subject stays in frame under the Dynamic Island.
                    .frame(width: w, height: h * 1.18)
                    .offset(y: h * 0.06)
                    .frame(width: w, height: h, alignment: .center)
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
        .frame(height: heroBody + bleed)
        // Negative inset pulls art under the transparent nav + Dynamic Island.
        .listRowInsets(EdgeInsets(top: -bleed, leading: 0, bottom: 0, trailing: 0))
    }

    // MARK: - Actions

    /// Qobuz-style chrome: outline icons on the left, large accent Play on the right.
    private func actionRow(_ artist: ArtistWithAlbums) -> some View {
        HStack(spacing: 20) {
            actionIconButton(
                systemImage: isFullyDownloaded ? "checkmark.circle" : "arrow.down.circle",
                label: isFullyDownloaded ? "Downloaded" : "Download artist",
                disabled: downloadPool.isEmpty,
                accent: isFullyDownloaded
            ) {
                downloadArtist()
            }

            actionIconButton(
                systemImage: "heart",
                label: mixBusy ? "Mixing" : "Instant Mix",
                disabled: mixBusy
            ) {
                Task { await startInstantMix(artist) }
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
                guard !playPool.isEmpty else { return }
                player.play(
                    playPool, startAt: 0,
                    context: PlaybackContext(label: artist.name, kind: .artist(id: artist.id)))
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.black)
                    .offset(x: 1)
                    .frame(width: 56, height: 56)
                    .background(dromeAccent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(playPool.isEmpty)
            .accessibilityLabel("Play")
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
                .font(.title2.weight(.regular))
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
            warmImages(artist: cached.artist, songs: cached.topSongs + cached.owned)
        } else {
            isLoading = true
        }
        error = nil
        defer { isLoading = false }

        do {
            // Albums + cover art are enough to paint. Biography, top songs, and
            // search used to block the hero and every album thumbnail.
            let loaded = try await session.client.artist(id: artistID)
            apply(
                artist: loaded,
                topSongs: topSongs,
                owned: ownedSongs,
                related: relatedArtists,
                bio: biography,
                hero: immediateHero(for: loaded))
            isLoading = false
            warmImages(artist: loaded, songs: topSongs + ownedSongs)

            async let topTask = session.client.topSongs(artistName: loaded.name, count: 10)
            async let searchTask = session.client.search(
                loaded.name, artistCount: 0, albumCount: 0, songCount: 40)
            async let infoTask = session.client.artistInfo2(id: loaded.id, count: 12)

            let fetchedTop = (try? await topTask) ?? []
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
            let owned = Array(byID.values)
            session.ratings.ingest(fetchedTop)
            session.ratings.ingest(owned)
            LibraryDetailCache.store(artist: loaded, topSongs: fetchedTop, owned: owned)
            apply(
                artist: loaded,
                topSongs: fetchedTop,
                owned: owned,
                related: relatedArtists,
                bio: biography,
                hero: heroImageURL)
            warmImages(artist: loaded, songs: fetchedTop + owned)

            let info = try? await infoTask
            var related = (info?.similarArtists ?? []).filter { $0.id != loaded.id && !$0.id.isEmpty }
            if related.isEmpty {
                let similar = (try? await session.client.similarSongs(artistId: loaded.id, count: 24)) ?? []
                related = Self.relatedArtists(from: similar, excluding: loaded.id)
            }
            let bio = info?.plainBiography.flatMap { $0.isEmpty ? nil : $0 }
            let relatedFinal = Array(related.prefix(12))
            let relatedCovers = relatedFinal.compactMap {
                session.artworkURL(id: $0.coverArt ?? $0.id, size: 192)
            }
            ImageLoader.shared.prefetch(relatedCovers, limit: 12, priority: .utility)
            apply(
                artist: loaded,
                topSongs: fetchedTop,
                owned: owned,
                related: relatedFinal,
                bio: bio,
                hero: heroImageURL)

            if let upgraded = await resolveHeroImage(loaded),
               await ImageLoader.shared.image(for: upgraded) != nil {
                heroImageURL = upgraded
            }
        } catch {
            if artist == nil {
                self.error = error.localizedDescription
            }
        }
    }

    /// Navidrome cover art is the fast hero. A Spotify or Last.fm portrait
    /// replaces it only after that bitmap is already decoded.
    private func immediateHero(for artist: ArtistWithAlbums) -> URL? {
        session.artistImages.memoryURL(artistId: artist.id)
    }

    /// Start cover fetches before the song lists return so the rail isn't blank.
    private func warmImages(artist: ArtistWithAlbums, songs: [Song]) {
        var urls: [URL] = []
        if let hero = session.artworkURL(id: artist.coverArt ?? artist.id, size: 800) {
            urls.append(hero)
        }
        for album in artist.albums.prefix(16) {
            if let url = session.artworkURL(id: album.coverArt ?? album.id, size: 300) {
                urls.append(url)
            }
        }
        for song in songs.prefix(12) {
            if let url = session.artworkURL(for: song, size: 96) {
                urls.append(url)
            }
        }
        ImageLoader.shared.prefetch(urls, limit: 28, priority: .userInitiated)
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

// MARK: - Horizontal song pages

/// Columns of song rows you swipe sideways through (next page peeks on the right).
private struct ArtistSongPagesRail: View {
    let songs: [Song]
    var pageSize: Int = 4
    let artistName: String
    let artistID: String

    @EnvironmentObject private var player: PlayerEngine

    private var pages: [[(offset: Int, song: Song)]] {
        let indexed = Array(songs.enumerated()).map { (offset: $0.offset, song: $0.element) }
        guard pageSize > 0 else { return [indexed] }
        return stride(from: 0, to: indexed.count, by: pageSize).map { start in
            Array(indexed[start..<min(start + pageSize, indexed.count)])
        }
    }

    /// ~4 rows × (cover 56 + padding) ≈ page height.
    private var pageHeight: CGFloat {
        let rows = CGFloat(min(pageSize, max(songs.count, 1)))
        return rows * 68
    }

    var body: some View {
        GeometryReader { geo in
            let pageWidth = max(geo.size.width - 40, 280)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        VStack(spacing: 0) {
                            ForEach(page, id: \.song.id) { item in
                                SongRow(
                                    song: item.song,
                                    showAlbum: true,
                                    // Nested horizontal paging owns the swipe.
                                    enablesSwipeActions: false
                                ) {
                                    player.play(
                                        songs, startAt: item.offset,
                                        context: PlaybackContext(
                                            label: artistName,
                                            kind: .artist(id: artistID)))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: pageWidth, alignment: .topLeading)
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 16)
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: pageHeight)
    }
}

// MARK: - See All songs

private struct ArtistSongsListView: View {
    let title: String
    let artistName: String
    let artistID: String
    let songs: [Song]

    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, showAlbum: true) {
                    player.play(
                        songs, startAt: index,
                        context: PlaybackContext(label: artistName, kind: .artist(id: artistID)))
                }
                .listRowBackground(DromeTheme.background)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DromeTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
