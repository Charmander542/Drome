import SwiftUI

struct SearchView: View {
    private enum Source: String, CaseIterable {
        case library = "Library"
        case spotify = "Spotify"
    }

    @EnvironmentObject private var session: AppSession
    @Environment(\.songNavigator) private var songNavigator

    @State private var source: Source = .library
    @State private var query = ""
    @State private var includeLyrics = false
    @State private var isSearching = false
    @State private var hasCompletedSearch = false
    @State private var hits: [SearchHit] = []
    @State private var spotifyHits: [SpotifySearchHit] = []
    @State private var addingSpotifyIDs: Set<String> = []
    @State private var addedSpotifyIDs: Set<String> = []
    @State private var error: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSearchPresented = false
    @State private var recentItems: [RecentSearchItem] = []
    @State private var matchedSongs: [String: Song] = [:]
    @State private var matchedAlbums: [String: Album] = [:]

    var body: some View {
        results
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: source == .library
                    ? "Artists, songs, albums…"
                    : "Search Spotify tracks, albums…")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .safeAreaInset(edge: .top, spacing: 0) {
                searchControls
            }
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onChange(of: source) { _, _ in
                hits = []
                spotifyHits = []
                error = nil
                hasCompletedSearch = false
                scheduleSearch(query)
            }
            .task {
                let loaded = await Task.detached(priority: .utility) {
                    RecentSearchesStore.load()
                }.value
                recentItems = loaded
            }
            .onReceive(NotificationCenter.default.publisher(for: .dromeFocusCarPlaySearch)) { _ in
                source = .library
                isSearchPresented = true
            }
            .scrollDismissesKeyboard(.interactively)
    }

    /// Stays visible while the search field is focused (unlike nav toolbar items).
    private var searchControls: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            if source == .library {
                Button {
                    includeLyrics.toggle()
                    scheduleSearch(query)
                } label: {
                    Image(systemName: "text.quote")
                        .symbolVariant(includeLyrics ? .fill : .none)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(includeLyrics ? DromeTheme.accent : Color.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(DromeTheme.elevated2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityLabel(includeLyrics ? "Lyrics search on" : "Lyrics search off")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(DromeTheme.background.opacity(0.94))
    }

    @ViewBuilder
    private var results: some View {
        switch source {
        case .library:
            libraryResults
        case .spotify:
            spotifyResults
        }
    }

    @ViewBuilder
    private var libraryResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        List {
            if trimmed.isEmpty {
                recentSearchesSection
            } else if let error, hits.isEmpty {
                Section {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(DromeTheme.background)
                }
            } else if hits.isEmpty && hasCompletedSearch && !isSearching {
                Section {
                    Text("No results")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(DromeTheme.background)
                }
            } else {
                ForEach(hits) { hit in
                    hitRow(hit)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .overlay {
            if trimmed.isEmpty && recentItems.isEmpty {
                EmptyStateView(
                    title: "Find your music",
                    systemImage: "magnifyingglass",
                    message: "Try an artist, album, song, or a line of lyrics.")
                .allowsHitTesting(false)
            } else if !trimmed.isEmpty && hits.isEmpty && isSearching {
                ProgressView()
                    .tint(DromeTheme.muted)
            }
        }
        .overlay(alignment: .top) {
            if isSearching && !hits.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DromeTheme.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
        }
        .animation(nil, value: query)
    }

    @ViewBuilder
    private var spotifyResults: some View {
        if session.wishlist == nil {
            EmptyStateView(
                title: "Wishlist not configured",
                systemImage: "heart",
                message: "Set your companion server URL in Settings to search Spotify and add tracks to your wishlist.")
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            List {
                if trimmed.isEmpty {
                    Section { EmptyView() }
                } else if let error, spotifyHits.isEmpty {
                    Section {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                            .listRowBackground(DromeTheme.background)
                    }
                } else if spotifyHits.isEmpty && hasCompletedSearch && !isSearching {
                    Section {
                        Text("No results")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                            .listRowBackground(DromeTheme.background)
                    }
                } else {
                    ForEach(spotifyHits) { hit in
                        spotifyRow(hit)
                            .listRowBackground(DromeTheme.background)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay {
                if trimmed.isEmpty {
                    EmptyStateView(
                        title: "Search Spotify",
                        systemImage: "magnifyingglass",
                        message: "Find tracks to add to your wishlist.")
                    .allowsHitTesting(false)
                } else if spotifyHits.isEmpty && isSearching {
                    ProgressView()
                        .tint(DromeTheme.muted)
                }
            }
            .animation(nil, value: query)
        }
    }

    @ViewBuilder
    private var recentSearchesSection: some View {
        if !recentItems.isEmpty {
            Section {
                ForEach(recentItems) { item in
                    recentItemRow(item)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                RecentSearchesStore.remove(item)
                                recentItems = RecentSearchesStore.load()
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") {
                        RecentSearchesStore.clear()
                        recentItems = []
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func recentItemRow(_ item: RecentSearchItem) -> some View {
        switch item.kind {
        case .artist:
            NavigationLink {
                ArtistDetailView(
                    artistID: item.entityId,
                    placeholderName: item.title)
            } label: {
                recentItemLabel(item, shape: .circle)
            }
            .simultaneousGesture(TapGesture().onEnded {
                bumpRecent(item)
            })

        case .album:
            AlbumMediaRow(
                album: item.decodedAlbum() ?? Album(
                    id: item.entityId, name: item.title,
                    artist: item.subtitle.isEmpty ? nil : item.subtitle,
                    artistId: nil, coverArt: item.coverArt,
                    songCount: nil, duration: nil, playCount: nil,
                    created: nil, year: nil, genre: nil, userRating: nil),
                trailing: AnyView(
                    Text("ALBUM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DromeTheme.muted)
                )
            ) {
                dismissKeyboard()
                bumpRecent(item)
            }

        case .song:
            Group {
                if let song = item.decodedSong() {
                    SongRow(
                        song: song,
                        showAlbum: true,
                        trailing: AnyView(
                            Text("SONG")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                        ),
                        lightweight: true
                    ) {
                        playRecentSongItem(item, song: song)
                    }
                } else {
                    recentItemLabel(item, shape: .rounded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            playRecentSongItem(item, song: nil)
                        })
                }
            }
        }
    }

    private func recentItemLabel(_ item: RecentSearchItem, shape: CoverShape) -> some View {
        HStack(spacing: 12) {
            RemoteImage(
                url: session.client.coverArtURL(id: item.coverArt ?? item.entityId, size: 120),
                placeholderSymbol: item.kind == .artist ? "person.crop.circle" : "music.note")
                .frame(width: 44, height: 44)
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(item.kind.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func playRecentSongItem(_ item: RecentSearchItem, song: Song?) {
        dismissKeyboard()
        bumpRecent(item)
        if let song {
            session.player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Search", kind: .search))
            NowPlayingPresenter.open()
            return
        }
        Task { await playRecentSong(id: item.entityId) }
    }

    private func bumpRecent(_ item: RecentSearchItem) {
        RecentSearchesStore.remember(item)
        recentItems = RecentSearchesStore.load()
    }

    private func playRecentSong(id: String) async {
        do {
            let song = try await session.client.song(id: id)
            RecentSearchesStore.remember(song: song)
            recentItems = RecentSearchesStore.load()
            session.player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Search", kind: .search))
            NowPlayingPresenter.open()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func spotifyRow(_ hit: SpotifySearchHit) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: hit.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(white: 0.16)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: hit.kind == "artist" ? 22 : 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(spotifySubtitle(hit))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            spotifyTrailing(hit)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if hit.kind == "album", let album = matchedAlbums[hit.spotifyId] {
                dismissKeyboard()
                songNavigator?.viewAlbum(album)
            } else if let song = matchedSongs[hit.spotifyId] {
                dismissKeyboard()
                session.player.play([song], startAt: 0,
                            context: PlaybackContext(label: "Library", kind: .search))
                NowPlayingPresenter.open()
            }
        })
    }

    private func spotifySubtitle(_ hit: SpotifySearchHit) -> String {
        switch hit.kind {
        case "album":
            return [hit.artist, "Album"].filter { !$0.isEmpty }.joined(separator: " · ")
        case "playlist":
            let count = hit.trackCount.map { "\($0) tracks" }
            return [hit.artist, count].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "artist":
            return "Artist"
        default:
            return [hit.artist, hit.album].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private func spotifyTrailing(_ hit: SpotifySearchHit) -> some View {
        switch hit.kind {
        case "playlist":
            Button {
                if let url = URL(string: hit.spotifyUrl) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
            }
            .buttonStyle(.plain)
        case "album":
            if let album = matchedAlbums[hit.spotifyId] {
                Button {
                    LibraryPlayback.play(album: album, session: session)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DromeTheme.accent)
                }
                .buttonStyle(.plain)
            } else {
                wishlistAddButton(hit)
            }
        case "artist":
            EmptyView()
        default:
            if let song = matchedSongs[hit.spotifyId] {
                Button {
                    session.player.play([song], startAt: 0,
                                context: PlaybackContext(label: "Library", kind: .search))
                    NowPlayingPresenter.open()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DromeTheme.accent)
                }
                .buttonStyle(.plain)
            } else {
                wishlistAddButton(hit)
            }
        }
    }

    private func wishlistAddButton(_ hit: SpotifySearchHit) -> some View {
        Button {
            Task { await addToWishlist(hit) }
        } label: {
            if addingSpotifyIDs.contains(hit.spotifyId) {
                ProgressView()
            } else if addedSpotifyIDs.contains(hit.spotifyId) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DromeTheme.accent)
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DromeTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(addingSpotifyIDs.contains(hit.spotifyId)
                  || addedSpotifyIDs.contains(hit.spotifyId))
        .accessibilityLabel("Add to Wishlist")
    }

    @ViewBuilder
    private func hitRow(_ hit: SearchHit) -> some View {
        switch hit.kind {
        case .artist:
            if let artist = hit.artist {
                NavigationLink {
                    ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                } label: {
                    hitLabel(hit, shape: .circle)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    rememberHit(hit)
                })
            }
        case .album:
            if let album = hit.album {
                AlbumMediaRow(
                    album: album,
                    trailing: AnyView(
                        Text("ALBUM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                    )
                ) {
                    dismissKeyboard()
                    rememberHit(hit)
                }
            }
        case .song:
            if let song = hit.song {
                SongRow(
                    song: song,
                    showAlbum: true,
                    trailing: AnyView(
                        Text("SONG")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                    ),
                    lightweight: true
                ) {
                    dismissKeyboard()
                    rememberHit(hit)
                    let songs = hits.compactMap(\.song)
                    let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                    session.player.play(songs.isEmpty ? [song] : songs, startAt: start,
                                context: PlaybackContext(label: "Search", kind: .search))
                    NowPlayingPresenter.open()
                }
            }
        case .lyrics:
            if let lyric = hit.lyrics {
                Button {
                    rememberHit(hit)
                    Task { await playLyricsHit(lyric) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        hitLabel(hit, shape: .rounded, showsCover: false)
                        Text(lyric.snippet)
                            .font(.caption)
                            .foregroundStyle(DromeTheme.accent)
                            .lineLimit(2)
                            .padding(.leading, 60)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rememberHit(_ hit: SearchHit) {
        RecentSearchesStore.remember(hit: hit)
        recentItems = RecentSearchesStore.load()
    }

    private enum CoverShape { case circle, rounded }

    private func hitLabel(_ hit: SearchHit, shape: CoverShape, showsCover: Bool = true) -> some View {
        HStack(spacing: 12) {
            if showsCover {
                Group {
                    RemoteImage(url: session.client.coverArtURL(id: hit.coverArt, size: 120),
                                placeholderSymbol: placeholder(for: hit.kind))
                }
                .frame(width: 44, height: 44)
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(DromeTheme.elevated2)
                    Image(systemName: "text.quote")
                        .foregroundStyle(DromeTheme.muted)
                }
                .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if hit.kind == .song, let song = hit.song {
                        // Don't remount on every ratings.revision — that made
                        // search feel like a hang when ingest published.
                        RatingBadge(rating: session.ratings.rating(for: song))
                    } else if hit.kind == .album, let album = hit.album, let rating = album.userRating, rating > 0 {
                        RatingBadge(rating: rating)
                    }
                }
                Text(hit.subtitle)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(kindBadge(hit.kind))
                .font(.caption2.weight(.bold))
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func kindBadge(_ kind: SearchHit.Kind) -> String {
        switch kind {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .song: return "SONG"
        case .lyrics: return "LYRICS"
        }
    }

    private func placeholder(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .artist: return "person.crop.circle"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .lyrics: return "text.quote"
        }
    }

    private func scheduleSearch(_ raw: String) {
        debounceTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            spotifyHits = []
            error = nil
            isSearching = false
            hasCompletedSearch = false
            NotificationCenter.default.post(
                name: .dromeCarPlaySearchQuery,
                object: nil,
                userInfo: ["query": ""])
            return
        }
        error = nil
        debounceTask = Task {
            // Local index first so the first character isn't waiting on the network.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: .dromeCarPlaySearchQuery,
                object: nil,
                userInfo: ["query": trimmed])
            switch source {
            case .library:
                await runLocalSearch(trimmed)
                guard !Task.isCancelled else { return }
                guard trimmed.count >= 2 else { return }
                if hits.isEmpty {
                    isSearching = true
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await runNetworkSearch(trimmed)
            case .spotify:
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                await runSpotifySearch(trimmed)
            }
        }
    }

    private func runLocalSearch(_ q: String) async {
        let serverKey = session.account.serverKey
        let index = session.library
        let db = session.database
        let wantLyrics = includeLyrics
        let ranked = await Task.detached(priority: .userInitiated) {
            let metadata = (try? index.search(serverKey: serverKey, query: q))
                ?? SearchResult3(artist: nil, album: nil, song: nil)
            let lyrics: [LyricsSearchMatch]
            if wantLyrics {
                lyrics = (try? db.searchLyrics(serverKey: serverKey, query: q)) ?? []
            } else {
                lyrics = []
            }
            return SearchRanker.rank(query: q, result: metadata, lyrics: lyrics)
        }.value
        guard !Task.isCancelled else { return }
        hits = ranked
        if !ranked.isEmpty || q.count < 2 {
            hasCompletedSearch = true
        }
    }

    private func runNetworkSearch(_ q: String) async {
        isSearching = true
        error = nil
        defer {
            isSearching = false
            hasCompletedSearch = true
        }
        do {
            let serverKey = session.account.serverKey
            let db = session.database
            let wantLyrics = includeLyrics
            let client = session.client
            let ranked = try await Task.detached(priority: .userInitiated) {
                let metadata = try await client.search(q, artistCount: 20, albumCount: 20, songCount: 40)
                let lyrics: [LyricsSearchMatch]
                if wantLyrics {
                    lyrics = (try? db.searchLyrics(serverKey: serverKey, query: q)) ?? []
                } else {
                    lyrics = []
                }
                return (SearchRanker.rank(query: q, result: metadata, lyrics: lyrics), metadata.songs)
            }.value
            guard !Task.isCancelled else { return }
            hits = ranked.0
            let songs = ranked.1
            Task { @MainActor in
                await Task.yield()
                session.ratings.ingest(songs)
            }
        } catch {
            if hits.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func runSpotifySearch(_ q: String) async {
        guard let wishlist = session.wishlist else { return }
        isSearching = true
        error = nil
        defer {
            isSearching = false
            hasCompletedSearch = true
        }
        do {
            let hits = try await wishlist.search(query: q, types: "track,album,playlist", limit: 10)
            spotifyHits = hits
            await resolveLibraryMatches(hits)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resolveLibraryMatches(_ hits: [SpotifySearchHit]) async {
        let client = session.client
        var songs: [String: Song] = [:]
        var albums: [String: Album] = [:]
        await withTaskGroup(of: (String, Song?, Album?).self) { group in
            for hit in hits {
                group.addTask {
                    switch hit.kind {
                    case "album":
                        let album = await LibraryMatcher.matchedAlbum(for: hit, client: client)
                        return (hit.spotifyId, nil, album)
                    case "track", "":
                        let song = await LibraryMatcher.matchedSong(for: hit, client: client)
                        return (hit.spotifyId, song, nil)
                    default:
                        return (hit.spotifyId, nil, nil)
                    }
                }
            }
            for await (id, song, album) in group {
                if let song { songs[id] = song }
                if let album { albums[id] = album }
            }
        }
        matchedSongs = songs
        matchedAlbums = albums
    }

    private func addToWishlist(_ hit: SpotifySearchHit) async {
        guard let wishlist = session.wishlist else { return }
        addingSpotifyIDs.insert(hit.spotifyId)
        defer { addingSpotifyIDs.remove(hit.spotifyId) }
        do {
            _ = try await wishlist.add(spotifyLink: hit.spotifyUrl)
            addedSpotifyIDs.insert(hit.spotifyId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playLyricsHit(_ hit: LyricsSearchMatch) async {
        do {
            let song = try await session.client.song(id: hit.songId)
            session.player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Lyrics search", kind: .search))
            NowPlayingPresenter.open()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Type-erased Shape so we can pick Circle vs RoundedRectangle in one call site.
private struct AnyShape: Shape {
    private let builder: (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        builder = { shape.path(in: $0) }
    }
    func path(in rect: CGRect) -> Path { builder(rect) }
}
