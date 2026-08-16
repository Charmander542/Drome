import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    var id: String { rawValue }

    /// Tabs shown in the Library filter bar (Downloads lives under Playlists).
    static var topBarCases: [LibraryFilter] {
        [.playlists, .artists, .albums, .songs, .genres]
    }

    /// Short label for the compact segmented bar.
    var shortTitle: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .genres: return "Genres"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerEngine

    @State private var filter: LibraryFilter = .playlists
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artistIndexes: [ArtistIndex] = []
    @State private var songs: [Song] = []
    @State private var albumSectionsCache: [(letter: String, albums: [Album])] = []
    @State private var artistSectionsCache: [(letter: String, artists: [Artist])] = []
    @State private var songSectionsCache: [(letter: String, songs: [Song])] = []
    /// Flat play order for the Songs tab — avoid rebuilding on every tap.
    @State private var flatSongsCache: [Song] = []
    @State private var songIndexByID: [String: Int] = [:]
    @State private var isLoading = false
    @State private var albumsHasMore = false
    @State private var albumsLoadingMore = false
    @State private var albumsOffset = 0
    @State private var albumsFillTask: Task<Void, Never>?
    @State private var pendingAlbumLetter: String?
    @State private var albumScrollTarget: String?
    @State private var artistsFillTask: Task<Void, Never>?
    @State private var artistSectionsRemaining: [(letter: String, artists: [Artist])] = []
    @State private var artistsHasMore = false
    @State private var pendingArtistLetter: String?
    @State private var artistScrollTarget: String?
    @State private var songHasMore = false
    @State private var songLoadingMore = false
    @State private var songNativeOffset = 0
    @State private var songsFillTask: Task<Void, Never>?
    @State private var pendingSongLetter: String?
    @State private var songScrollTarget: String?
    @State private var error: String?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var playlistToDelete: Playlist?
    @State private var scanStatusText: String?
    @Namespace private var filterUnderlineNamespace
    /// Tabs the user has opened — kept mounted so switches stay instant.
    @State private var visitedFilters: Set<LibraryFilter> = [.playlists]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if let scanStatusText {
                Text(scanStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            content
        }
        .navigationTitle("Your Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    WishlistView()
                } label: {
                    Image(systemName: "heart")
                }
                .accessibilityLabel("Wishlist")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if filter == .playlists {
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
        }
        .task {
            await hydrateAllTabsFromCache()
            await ensureActiveTabReady(forceNetwork: false)
            visitedFilters.formUnion([.artists, .albums, .songs])
        }
        .task(id: filter) {
            await ensureActiveTabReady(forceNetwork: false)
        }
        .refreshable {
            await refreshLibrary(triggerScan: true)
        }
        .alert("New Playlist", isPresented: $showCreatePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") { Task { await createPlaylist() } }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Creates a playlist on your Navidrome server.")
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { playlistToRename != nil },
            set: { if !$0 { playlistToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await renamePlaylist() } }
            Button("Cancel", role: .cancel) { playlistToRename = nil }
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete “\(playlistToDelete?.name ?? "")”", role: .destructive) {
                if let playlist = playlistToDelete {
                    Task { await deletePlaylist(playlist) }
                }
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            Text("This removes the playlist from Navidrome. Songs stay in your library.")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(LibraryFilter.topBarCases) { item in
                Button {
                    filter = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.shortTitle)
                            .font(.caption.weight(filter == item ? .bold : .semibold))
                            .foregroundStyle(filter == item ? Color.white : Color.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 2)
                            if filter == item {
                                Capsule()
                                    .fill(DromeTheme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(
                                        id: "libraryFilterUnderline",
                                        in: filterUnderlineNamespace)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(DromeTheme.background)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: filter)
    }

    @ViewBuilder
    private var content: some View {
        // Only block the whole Library on first paint — never replace keep-alive
        // tabs with a spinner when flipping to a tab that still needs a fetch.
        if isLoading && !hasAnyTabContent {
            LoadingStateView()
        } else if let error, !hasAnyTabContent {
            ErrorStateView(message: error) { Task { await load(forceNetwork: true) } }
        } else {
            ZStack {
                if visitedFilters.contains(.playlists) {
                    keepAlivePane(.playlists) { playlistsList }
                }
                if visitedFilters.contains(.artists) {
                    keepAlivePane(.artists) {
                        if artistSectionsCache.isEmpty && isLoading && filter == .artists {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            artistsList
                        }
                    }
                }
                if visitedFilters.contains(.albums) {
                    keepAlivePane(.albums) {
                        if albums.isEmpty && isLoading && filter == .albums {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            albumsList
                        }
                    }
                }
                if visitedFilters.contains(.songs) {
                    keepAlivePane(.songs) {
                        if songs.isEmpty && isLoading && filter == .songs {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            songsList
                        }
                    }
                }
                if filter == .genres {
                    GenreBrowserView(showsTitle: false)
                }
            }
            .animation(nil, value: filter)
            .onAppear { visitedFilters.insert(filter) }
            .onChange(of: filter) { _, newValue in
                visitedFilters.insert(newValue)
            }
        }
    }

    private var hasAnyTabContent: Bool {
        !playlists.isEmpty
            || !albums.isEmpty
            || !artistSectionsCache.isEmpty
            || !songs.isEmpty
            || !flatSongsCache.isEmpty
    }

    /// Keep visited tabs mounted so flips don't rebuild lists / re-fetch art.
    @ViewBuilder
    private func keepAlivePane<Content: View>(
        _ tab: LibraryFilter,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(filter == tab ? 1 : 0)
            .allowsHitTesting(filter == tab)
            .accessibilityHidden(filter != tab)
            .zIndex(filter == tab ? 1 : 0)
            .transaction { $0.animation = nil }
    }

    private var isEmpty: Bool {
        switch filter {
        case .playlists: return playlists.isEmpty
        case .albums: return albums.isEmpty
        case .artists: return artistSectionsCache.isEmpty
        case .songs: return songs.isEmpty
        case .genres: return false
        }
    }

    @ViewBuilder
    private var outOfRotationContent: some View {
        if let playlist = rotation.playlist {
            PlaylistDetailView(playlistID: playlist.id, placeholder: playlist, prefersInlineTitle: true)
        } else {
            EmptyStateView(
                title: "Out of Rotation",
                systemImage: "lock.fill",
                message: "Tracks rated 2 stars or lower land here automatically. Add songs manually from any track menu.")
            .task { await rotation.refresh() }
        }
    }

    private var playlistsList: some View {
        List {
            Section {
                Button {
                    newPlaylistName = ""
                    showCreatePlaylist = true
                } label: {
                    Label("Create playlist", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DromeTheme.accent)
                }
                .listRowBackground(DromeTheme.elevated)

                NavigationLink {
                    DownloadsView()
                } label: {
                    HStack {
                        Label("Downloaded", systemImage: "arrow.down.circle.fill")
                            .font(.body.weight(.semibold))
                        Spacer()
                        if downloads.downloadedCount > 0 {
                            Text("\(downloads.downloadedCount)")
                                .foregroundStyle(DromeTheme.muted)
                        }
                    }
                }
                .listRowBackground(DromeTheme.elevated)

                NavigationLink {
                    WishlistView()
                } label: {
                    Label("Wishlist", systemImage: "heart.fill")
                        .font(.body.weight(.semibold))
                }
                .listRowBackground(DromeTheme.elevated)

                NavigationLink {
                    RatedLibraryView()
                } label: {
                    Label("Top Rated", systemImage: "star.fill")
                        .font(.body.weight(.semibold))
                }
                .listRowBackground(DromeTheme.elevated)

                NavigationLink {
                    outOfRotationContent
                } label: {
                    Label("Out of Rotation", systemImage: "lock.fill")
                        .font(.body.weight(.semibold))
                }
                .listRowBackground(DromeTheme.elevated)
            }

            Section {
                if playlists.isEmpty && !isLoading {
                    Text("No playlists yet.")
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlistID: playlist.id, placeholder: playlist) {
                            playlists.removeAll { $0.id == playlist.id }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DromeTheme.elevated2)
                                if rotation.isSystemPlaylist(playlist) {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(DromeTheme.muted)
                                } else {
                                    RemoteImage(url: session.client.coverArtURL(id: playlist.coverArt ?? playlist.id, size: 96),
                                                placeholderSymbol: "music.note.list")
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(playlist.name)
                                        .font(DromeTheme.rowTitle)
                                    if rotation.isSystemPlaylist(playlist) {
                                        Image(systemName: "lock.fill")
                                            .font(.caption2)
                                            .foregroundStyle(DromeTheme.muted)
                                    }
                                    if downloads.isPlaylistFullyDownloaded(
                                        playlistId: playlist.id,
                                        expectedCount: playlist.songCount ?? 0)
                                    {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(DromeTheme.accent)
                                            .accessibilityLabel("Downloaded")
                                    }
                                }
                                Text(playlistSubtitle(playlist))
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.background)
                    .contextMenu {
                        if !rotation.isSystemPlaylist(playlist) {
                            Button {
                                renameText = playlist.name
                                playlistToRename = playlist
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                playlistToDelete = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !rotation.isSystemPlaylist(playlist) {
                            Button(role: .destructive) {
                                playlistToDelete = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = playlist.name
                                playlistToRename = playlist
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(DromeTheme.accent)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    private var albumsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(albumSectionsCache, id: \.letter) { section in
                        Section {
                            ForEach(section.albums) { album in
                                AlbumMediaRow(album: album, showsChevron: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 56)

                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 84)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(DromeTheme.background.opacity(0.94))
                                .id(section.letter)
                        }
                    }

                    if albumsHasMore {
                        ProgressView()
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 72)
            }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(
                    letters: LibrarySortLetter.scrubberLetters,
                    onSelect: { jumpAlbums(to: $0, proxy: proxy, dragging: true) },
                    onEnded: { jumpAlbums(to: $0, proxy: proxy, dragging: false) }
                )
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
            .onChange(of: albumScrollTarget) { _, letter in
                guard let letter else { return }
                snapScroll(proxy, to: letter)
                albumScrollTarget = nil
            }
            .onChange(of: albumSectionsCache.map(\.letter)) { _, letters in
                guard let pending = pendingAlbumLetter,
                      letters.contains(pending) else { return }
                pendingAlbumLetter = nil
                albumScrollTarget = pending
            }
        }
    }

    private func rebuildAlbumSections(from albums: [Album]) -> [(letter: String, albums: [Album])] {
        let grouped = Dictionary(grouping: albums) { album -> String in
            LibrarySortLetter.sectionLetter(for: album.name)
        }
        return grouped.keys.sorted(by: LibrarySortLetter.sectionLetterSort).compactMap { letter in
            guard let items = grouped[letter], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                LibrarySortLetter.sortableName($0.name)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.name)) == .orderedAscending
            }
            return (letter: letter, albums: sorted)
        }
    }

    private var artistsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Same LazyVStack pattern as Albums — eager VStack mounted every
                // artist + avatar on tab flip and made Artists feel uniquely slow.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(artistSectionsCache, id: \.letter) { section in
                        Section {
                            ForEach(section.artists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                                } label: {
                                    HStack(spacing: 12) {
                                        RemoteImage(
                                            url: session.client.coverArtURL(
                                                id: artist.coverArt ?? artist.id,
                                                size: Self.listArtSize),
                                            placeholderSymbol: "person.crop.circle")
                                            .frame(width: 48, height: 48)
                                            .clipShape(Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artist.name).font(DromeTheme.rowTitle)
                                                .foregroundStyle(.white)
                                            if let count = artist.albumCount {
                                                Text("\(count) albums")
                                                    .font(.caption)
                                                    .foregroundStyle(DromeTheme.muted)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(DromeTheme.muted.opacity(0.6))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 76)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(DromeTheme.background.opacity(0.94))
                                .id(section.letter)
                        }
                    }
                }
                .padding(.bottom, 72)
            }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(
                    letters: LibrarySortLetter.scrubberLetters,
                    onSelect: { jumpArtists(to: $0, proxy: proxy, dragging: true) },
                    onEnded: { jumpArtists(to: $0, proxy: proxy, dragging: false) }
                )
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
            .onChange(of: artistScrollTarget) { _, letter in
                guard let letter else { return }
                snapScroll(proxy, to: letter)
                artistScrollTarget = nil
            }
            .onChange(of: artistSectionsCache.map(\.letter)) { _, letters in
                guard let pending = pendingArtistLetter else { return }
                pendingArtistLetter = nil
                if let target = LibrarySortLetter.nearestSectionLetter(pending, in: letters) {
                    artistScrollTarget = target
                }
            }
        }
    }

    private nonisolated static func buildArtistSections(
        from indexes: [ArtistIndex]
    ) -> [(letter: String, artists: [Artist])] {
        buildArtistSections(fromArtists: indexes.flatMap(\.artists))
    }

    /// Bucket by artist name so A–Z matches the scrubber (not server index labels).
    private nonisolated static func buildArtistSections(
        fromArtists artists: [Artist]
    ) -> [(letter: String, artists: [Artist])] {
        var buckets: [String: [Artist]] = [:]
        var seen = Set<String>()
        for artist in artists where seen.insert(artist.id).inserted {
            let letter = LibrarySortLetter.sectionLetter(for: artist.name)
            buckets[letter, default: []].append(artist)
        }
        return buckets.keys.sorted(by: LibrarySortLetter.sectionLetterSort).compactMap { letter in
            guard var items = buckets[letter], !items.isEmpty else { return nil }
            items.sort {
                LibrarySortLetter.sortableName($0.name)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.name)) == .orderedAscending
            }
            return (letter: letter, artists: items)
        }
    }

    private func rebuildArtistSections(from indexes: [ArtistIndex]) -> [(letter: String, artists: [Artist])] {
        Self.buildArtistSections(from: indexes)
    }

    private var songsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(songSectionsCache, id: \.letter) { section in
                        Section {
                            ForEach(section.songs, id: \.id) { song in
                                SongRow(song: song, showAlbum: true, lightweight: true) {
                                        let start = songIndexByID[song.id] ?? 0
                                        playerPlay(flatSongsCache, startAt: start)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)

                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 76)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(DromeTheme.background.opacity(0.94))
                                .id(section.letter)
                        }
                    }

                    if songHasMore {
                        ProgressView()
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 72)
            }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(
                    letters: LibrarySortLetter.scrubberLetters,
                    onSelect: { jumpSongs(to: $0, proxy: proxy, dragging: true) },
                    onEnded: { jumpSongs(to: $0, proxy: proxy, dragging: false) }
                )
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
            .onChange(of: songScrollTarget) { _, letter in
                guard let letter else { return }
                snapScroll(proxy, to: letter)
                songScrollTarget = nil
            }
            .onChange(of: songSectionsCache.map(\.letter)) { _, letters in
                guard let pending = pendingSongLetter,
                      letters.contains(pending) else { return }
                pendingSongLetter = nil
                songScrollTarget = pending
            }
        }
    }

    private func applySongCatalog(_ songs: [Song]) async {
        let shouldWarm = flatSongsCache.isEmpty
        let built = await Task.detached(priority: .userInitiated) {
            let sections = Self.buildSongSections(from: songs)
            let flat = sections.flatMap(\.songs)
            var index: [String: Int] = [:]
            index.reserveCapacity(flat.count)
            for (i, song) in flat.enumerated() {
                index[song.id] = i
            }
            return (sections: sections, flat: flat, index: index)
        }.value
        guard !Task.isCancelled else { return }
        songSectionsCache = built.sections
        flatSongsCache = built.flat
        songIndexByID = built.index
        self.songs = built.flat
        if shouldWarm {
            warmSongCovers(Array(built.flat.prefix(48)))
        }
    }

    /// Pure section builder — safe to run off the main actor.
    private nonisolated static func buildSongSections(
        from songs: [Song]
    ) -> [(letter: String, songs: [Song])] {
        let grouped = Dictionary(grouping: songs) { song -> String in
            LibrarySortLetter.sectionLetter(for: song.title)
        }
        return grouped.keys.sorted(by: LibrarySortLetter.sectionLetterSort).compactMap { letter in
            guard let items = grouped[letter], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                LibrarySortLetter.sortableName($0.title)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.title)) == .orderedAscending
            }
            return (letter: letter, songs: sorted)
        }
    }

    private nonisolated static func buildAlbumSections(
        from albums: [Album]
    ) -> [(letter: String, albums: [Album])] {
        let grouped = Dictionary(grouping: albums) { album -> String in
            LibrarySortLetter.sectionLetter(for: album.name)
        }
        return grouped.keys.sorted(by: LibrarySortLetter.sectionLetterSort).compactMap { letter in
            guard let items = grouped[letter], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                LibrarySortLetter.sortableName($0.name)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.name)) == .orderedAscending
            }
            return (letter: letter, albums: sorted)
        }
    }

    /// Shared list thumbnail size — small & sharp enough for 48pt rows.
    private static let listArtSize = 96

    private func applyAlbumCatalog(_ albums: [Album]) async {
        let shouldWarm = self.albums.isEmpty
        let sections = await Task.detached(priority: .userInitiated) {
            Self.buildAlbumSections(from: albums)
        }.value
        guard !Task.isCancelled else { return }
        self.albums = albums
        albumSectionsCache = sections
        // Only warm on first paint — re-warming every page steals bandwidth
        // from the A–Z fill.
        if shouldWarm {
            warmAlbumCovers(Array(albums.prefix(48)))
        }
    }

    private func playerPlay(_ songs: [Song], startAt: Int) {
        player.play(songs, startAt: startAt, context: PlaybackContext(label: "Songs", kind: .mix))
    }

    private func warmAlbumCovers(_ albums: [Album]) {
        let urls = albums.compactMap {
            session.artworkURL(id: $0.coverArt ?? $0.id, size: Self.listArtSize)
        }
        ImageLoader.shared.prefetch(urls, limit: 48)
    }

    private func warmArtistCovers(_ artists: [Artist]) {
        let urls = artists.compactMap {
            session.client.coverArtURL(id: $0.coverArt ?? $0.id, size: Self.listArtSize)
        }
        ImageLoader.shared.prefetch(urls, limit: 48)
    }

    private func warmSongCovers(_ songs: [Song]) {
        let urls = songs.compactMap { session.artworkURL(for: $0, size: Self.listArtSize) }
        ImageLoader.shared.prefetch(urls, limit: 48)
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        var parts: [String] = []
        if let owner = playlist.owner { parts.append(owner) }
        if playlist.songCount != nil { parts.append(playlist.songCountLabel) }
        if playlist.isPublic == true { parts.append("Shared") }
        return parts.joined(separator: " · ")
    }

    /// Pull every tab’s cached tops into `@State` once so filter flips are free.
    private func hydrateAllTabsFromCache() async {
        let serverKey = session.account.serverKey

        if playlists.isEmpty,
           let cached = LibraryListCatalog.playlists(serverKey: serverKey),
           !cached.isEmpty {
            playlists = cached
        }

        if albums.isEmpty,
           let cached = LibraryListCatalog.albums(serverKey: serverKey),
           !cached.isEmpty {
            await applyAlbumCatalog(cached)
            albumsOffset = cached.count
            albumsHasMore = !LibraryListCatalog.albumsComplete(serverKey: serverKey)
        }

        if artistSectionsCache.isEmpty,
           let cached = LibraryListCatalog.artistSections(serverKey: serverKey),
           !cached.isEmpty {
            applyArtistSections(cached.map { (letter: $0.letter, artists: $0.artists) })
        }

        // Songs catalogs can be huge — hydrate off the first-paint path unless
        // Songs is already selected.
        if flatSongsCache.isEmpty,
           let cached = LibraryListCatalog.songs(serverKey: serverKey),
           !cached.isEmpty {
            if filter == .songs {
                await applySongCatalog(cached)
                songNativeOffset = cached.count
                songHasMore = !LibraryListCatalog.songsComplete(serverKey: serverKey)
            } else {
                let complete = LibraryListCatalog.songsComplete(serverKey: serverKey)
                Task { @MainActor in
                    guard flatSongsCache.isEmpty else { return }
                    await applySongCatalog(cached)
                    songNativeOffset = cached.count
                    songHasMore = !complete
                }
            }
        }
    }

    /// Instant tab switch: if this tab already has rows, do nothing on the
    /// critical path. Network fill / refresh happens only when empty or forced.
    private func ensureActiveTabReady(forceNetwork: Bool) async {
        if filter == .genres {
            return
        }

        parkInactiveFills()

        if !forceNetwork, !isEmpty {
            resumeBackgroundFillIfNeeded()
            return
        }

        await load(forceNetwork: forceNetwork)
    }

    private func parkInactiveFills() {
        if filter != .albums {
            albumsFillTask?.cancel()
            albumsFillTask = nil
            pendingAlbumLetter = nil
        }
        if filter != .artists {
            artistsFillTask?.cancel()
            artistsFillTask = nil
            pendingArtistLetter = nil
        }
        if filter != .songs {
            songsFillTask?.cancel()
            songsFillTask = nil
            pendingSongLetter = nil
        }
    }

    private func resumeBackgroundFillIfNeeded() {
        switch filter {
        case .albums:
            if albumsHasMore, albumsFillTask == nil || albumsFillTask?.isCancelled == true {
                albumsFillTask = Task { @MainActor in
                    await fillAlbumsInBackground()
                }
            }
        case .songs:
            if songHasMore, songsFillTask == nil || songsFillTask?.isCancelled == true {
                songsFillTask = Task { @MainActor in
                    await fillSongsInBackground()
                }
            }
        case .artists, .playlists, .genres:
            break
        }
    }

    private func load(forceNetwork: Bool = false) async {
        if filter == .genres {
            return
        }
        let keepVisible = !isEmpty
        if !keepVisible { isLoading = true }
        error = nil
        // Focus network on the active tab so A–Z fill stays timely.
        if filter != .albums {
            albumsFillTask?.cancel()
            albumsFillTask = nil
            pendingAlbumLetter = nil
        }
        if filter != .artists {
            artistsFillTask?.cancel()
            artistsFillTask = nil
            pendingArtistLetter = nil
            artistSectionsRemaining = []
            artistsHasMore = false
        }
        if filter != .songs {
            songsFillTask?.cancel()
            songsFillTask = nil
            pendingSongLetter = nil
        }
        defer {
            isLoading = false
        }
        do {
            switch filter {
            case .playlists:
                if !forceNetwork,
                   playlists.isEmpty,
                   let cached = LibraryListCatalog.playlists(serverKey: session.account.serverKey),
                   !cached.isEmpty {
                    playlists = cached
                }
                if forceNetwork || playlists.isEmpty {
                    let fresh = try await session.client.playlists()
                    playlists = fresh
                    LibraryListCatalog.storePlaylists(fresh, serverKey: session.account.serverKey)
                }
                await rotation.refresh()
            case .albums:
                await loadAlbumsCatalog(forceNetwork: forceNetwork)
            case .artists:
                try await loadArtistsCatalog(forceNetwork: forceNetwork)
            case .songs:
                await loadFullSongCatalog(forceNetwork: forceNetwork)
            case .genres:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Shared catalog UX (Albums / Artists / Songs)
    // Instant cache → first chunk → background fill → snap scrubber jumps.

    private func loadAlbumsCatalog(forceNetwork: Bool = false) async {
        albumsFillTask?.cancel()
        pendingAlbumLetter = nil

        // Already painted in this session — don't rebuild sections on tab flip.
        if !forceNetwork, !albums.isEmpty {
            isLoading = false
            if albumsHasMore {
                albumsFillTask = Task { @MainActor in
                    await fillAlbumsInBackground()
                }
            }
            return
        }

        let serverKey = session.account.serverKey
        if !forceNetwork,
           let cached = LibraryListCatalog.albums(serverKey: serverKey),
           !cached.isEmpty {
            await applyAlbumCatalog(cached)
            isLoading = false
            albumsOffset = cached.count
            albumsHasMore = !LibraryListCatalog.albumsComplete(serverKey: serverKey)
            if !albumsHasMore {
                return
            }
        } else {
            if forceNetwork {
                albums = []
                albumSectionsCache = []
            }
            albumsOffset = 0
            albumsHasMore = true
            await loadMoreAlbums(isInitial: true, replace: true)
            guard !Task.isCancelled else { return }
            persistAlbumCatalog(complete: !albumsHasMore)
        }

        guard albumsHasMore else { return }
        albumsFillTask = Task { @MainActor in
            await fillAlbumsInBackground()
        }
    }

    private func fillAlbumsInBackground() async {
        while albumsHasMore, !Task.isCancelled {
            await loadMoreAlbums()
            await Task.yield()
        }
        persistAlbumCatalog(complete: !albumsHasMore)
        clearPendingLetterIfMissing(
            pending: &pendingAlbumLetter,
            letters: albumSectionsCache.map(\.letter))
    }

    private func refreshAlbumsFromStartIfNeeded() async {
        do {
            let headSize = min(50, max(albums.count, 1))
            let head = try await session.client.albumList(
                type: .alphabeticalByName, size: headSize, offset: 0)
            guard !Task.isCancelled else { return }

            let cachedHead = Array(albums.prefix(head.count))
            let headChanged = head.map(\.id) != cachedHead.map(\.id)

            var grew = false
            if !headChanged {
                let probe = try await session.client.albumList(
                    type: .alphabeticalByName, size: 1, offset: albums.count)
                grew = !probe.isEmpty
            }

            guard headChanged || grew else { return }

            albumsOffset = headChanged ? 0 : albums.count
            albumsHasMore = true
            if headChanged {
                await loadMoreAlbums(isInitial: true, replace: true)
            }
            if albumsHasMore {
                await fillAlbumsInBackground()
            } else {
                persistAlbumCatalog(complete: true)
            }
        } catch {
            // Keep cached albums.
        }
    }

    private func persistAlbumCatalog(complete: Bool) {
        guard !albums.isEmpty else { return }
        LibraryListCatalog.storeAlbums(
            albums, serverKey: session.account.serverKey, isComplete: complete)
    }

    private func snapScroll(_ proxy: ScrollViewProxy, to letter: String) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(letter, anchor: .top)
        }
    }

    private func jumpAlbums(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let letters = albumSectionsCache.map(\.letter)
        let target = letters.contains(letter)
            ? letter
            : LibrarySortLetter.nearestSectionLetter(letter, in: letters)
        if let target {
            snapScroll(proxy, to: target)
        }
        guard !dragging else { return }
        if letters.contains(letter) {
            pendingAlbumLetter = nil
            return
        }
        pendingAlbumLetter = letter
        if albumsFillTask == nil || albumsFillTask?.isCancelled == true {
            albumsFillTask = Task { @MainActor in
                await fillAlbumsInBackground()
            }
        }
    }

    private func loadMoreAlbums(isInitial: Bool = false, replace: Bool = false) async {
        guard !albumsLoadingMore else { return }
        if !isInitial, !albumsHasMore { return }
        albumsLoadingMore = true
        defer { albumsLoadingMore = false }

        let pageSize: Int
        if pendingAlbumLetter != nil {
            pageSize = 400
        } else if isInitial || replace {
            pageSize = 50
        } else {
            pageSize = 200
        }
        let offset = replace ? 0 : albumsOffset
        do {
            let page = try await session.client.albumList(
                type: .alphabeticalByName, size: pageSize, offset: offset)
            if Task.isCancelled { return }
            if page.isEmpty {
                albumsHasMore = false
                persistAlbumCatalog(complete: true)
                return
            }

            var merged: [Album]
            if replace {
                merged = page
                albumsOffset = page.count
            } else {
                merged = albums
                var seen = Set(merged.map(\.id))
                for album in page where seen.insert(album.id).inserted {
                    merged.append(album)
                }
                albumsOffset = offset + page.count
            }
            albumsHasMore = page.count >= pageSize && merged.count < 10_000

            isLoading = false
            await applyAlbumCatalog(merged)
            persistAlbumCatalog(complete: !albumsHasMore)
        } catch {
            if albums.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadArtistsCatalog(forceNetwork: Bool = false) async throws {
        artistsFillTask?.cancel()

        if !forceNetwork, !artistSectionsCache.isEmpty {
            isLoading = false
            return
        }

        let serverKey = session.account.serverKey
        if !forceNetwork,
           let cached = LibraryListCatalog.artistSections(serverKey: serverKey),
           !cached.isEmpty {
            let sections = cached.map { (letter: $0.letter, artists: $0.artists) }
            applyArtistSections(sections)
            isLoading = false
            return
        }

        artistSectionsCache = []
        artistSectionsRemaining = []
        artistsHasMore = false

        let indexes = try await session.client.artists()
        guard !Task.isCancelled else { return }

        let sections = await Task.detached(priority: .userInitiated) {
            Self.buildArtistSections(from: indexes)
        }.value
        guard !Task.isCancelled else { return }

        isLoading = false
        artistIndexes = indexes
        // Full index is already local after getArtists — publish every letter
        // immediately so scrubber jumps never wait on a fake drip-feed.
        applyArtistSections(sections)
        LibraryListCatalog.storeArtistSections(
            sections, serverKey: serverKey, isComplete: true)

        if let pending = pendingArtistLetter {
            pendingArtistLetter = nil
            if let target = LibrarySortLetter.nearestSectionLetter(
                pending, in: sections.map(\.letter)
            ) {
                artistScrollTarget = target
            }
        }
    }

    private func applyArtistSections(_ sections: [(letter: String, artists: [Artist])]) {
        let shouldWarm = artistSectionsCache.isEmpty
        artistSectionsCache = sections
        artistSectionsRemaining = []
        artistsHasMore = false
        if shouldWarm {
            warmArtistCovers(Array(sections.flatMap(\.artists).prefix(48)))
        }
    }

    private func refreshArtistsQuietly() async {
        do {
            let indexes = try await session.client.artists()
            guard !Task.isCancelled else { return }
            let sections = await Task.detached(priority: .userInitiated) {
                Self.buildArtistSections(from: indexes)
            }.value
            guard !Task.isCancelled else { return }

            let cachedIDs = artistSectionsCache.flatMap(\.artists).map(\.id)
            let freshIDs = sections.flatMap(\.artists).map(\.id)
            guard cachedIDs != freshIDs else { return }

            artistIndexes = indexes
            applyArtistSections(sections)
            LibraryListCatalog.storeArtistSections(
                sections, serverKey: session.account.serverKey, isComplete: true)
        } catch {
            // Keep cached artists.
        }
    }

    private func jumpArtists(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let letters = artistSectionsCache.map(\.letter)

        if let target = LibrarySortLetter.nearestSectionLetter(letter, in: letters) {
            snapScroll(proxy, to: target)
            if dragging { return }
            pendingArtistLetter = nil
            prefetchArtistSection(target)
            return
        }

        if dragging { return }

        if !artistSectionsRemaining.isEmpty {
            artistSectionsCache.append(contentsOf: artistSectionsRemaining)
            artistSectionsCache.sort { LibrarySortLetter.sectionLetterSort($0.letter, $1.letter) }
            artistSectionsRemaining = []
            artistsHasMore = false
            if let target = LibrarySortLetter.nearestSectionLetter(
                letter, in: artistSectionsCache.map(\.letter)
            ) {
                pendingArtistLetter = nil
                prefetchArtistSection(target)
                artistScrollTarget = target
                return
            }
        }

        pendingArtistLetter = letter
    }

    private func prefetchArtistSection(_ letter: String) {
        guard let section = artistSectionsCache.first(where: { $0.letter == letter }) else { return }
        let urls = section.artists.prefix(16).compactMap {
            session.client.coverArtURL(id: $0.coverArt ?? $0.id, size: Self.listArtSize)
        }
        ImageLoader.shared.prefetch(urls, limit: 16)
    }

    private func loadFullSongCatalog(forceNetwork: Bool = false) async {
        songsFillTask?.cancel()
        pendingSongLetter = nil

        if !forceNetwork, !flatSongsCache.isEmpty {
            isLoading = false
            if songHasMore {
                songsFillTask = Task { @MainActor in
                    await fillSongsInBackground()
                }
            }
            return
        }

        let serverKey = session.account.serverKey
        if !forceNetwork,
           let cached = LibraryListCatalog.songs(serverKey: serverKey),
           !cached.isEmpty {
            await applySongCatalog(cached)
            isLoading = false
            songNativeOffset = cached.count
            songHasMore = !LibraryListCatalog.songsComplete(serverKey: serverKey)
            if !songHasMore {
                return
            }
        } else {
            if forceNetwork {
                songs = []
                songSectionsCache = []
                flatSongsCache = []
                songIndexByID = [:]
            }
            songNativeOffset = 0
            songHasMore = true
            await loadMoreSongs(isInitial: true, replace: true)
            guard !Task.isCancelled else { return }
            persistSongCatalog(complete: !songHasMore)
        }

        guard songHasMore else { return }
        songsFillTask = Task { @MainActor in
            await fillSongsInBackground()
        }
    }

    private func fillSongsInBackground() async {
        while songHasMore, !Task.isCancelled {
            await loadMoreSongs()
            await Task.yield()
        }
        persistSongCatalog(complete: !songHasMore)
        clearPendingLetterIfMissing(
            pending: &pendingSongLetter,
            letters: songSectionsCache.map(\.letter))
    }

    private func refreshSongsFromStartIfNeeded() async {
        do {
            let head = try await session.client.nativeSongs(start: 0, end: min(80, flatSongsCache.count))
            guard !Task.isCancelled else { return }

            let cachedHead = Array(flatSongsCache.prefix(head.count))
            let headChanged = head.map(\.id) != cachedHead.map(\.id)

            var grew = false
            if !headChanged {
                let probe = try await session.client.nativeSongs(
                    start: flatSongsCache.count,
                    end: flatSongsCache.count + 1)
                grew = !probe.isEmpty
            }

            guard headChanged || grew else { return }

            songNativeOffset = headChanged ? 0 : flatSongsCache.count
            songHasMore = true
            if headChanged {
                await loadMoreSongs(isInitial: true, replace: true)
            }
            if songHasMore {
                await fillSongsInBackground()
            } else {
                persistSongCatalog(complete: true)
            }
        } catch {
            // Keep the cached list — native refresh is best-effort.
        }
    }

    private func persistSongCatalog(complete: Bool) {
        guard !flatSongsCache.isEmpty else { return }
        LibraryListCatalog.storeSongs(
            flatSongsCache,
            serverKey: session.account.serverKey,
            isComplete: complete)
    }

    private func clearPendingLetterIfMissing(pending: inout String?, letters: [String]) {
        guard let letter = pending, !letters.contains(letter) else { return }
        pending = nil
    }

    private func jumpSongs(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let letters = songSectionsCache.map(\.letter)
        let target = letters.contains(letter)
            ? letter
            : LibrarySortLetter.nearestSectionLetter(letter, in: letters)
        if let target {
            snapScroll(proxy, to: target)
        }
        guard !dragging else { return }
        if letters.contains(letter) {
            pendingSongLetter = nil
            return
        }
        pendingSongLetter = letter
        if songsFillTask == nil || songsFillTask?.isCancelled == true {
            songsFillTask = Task { @MainActor in
                await fillSongsInBackground()
            }
        }
    }

    private func loadMoreSongs(isInitial: Bool = false, replace: Bool = false) async {
        guard songHasMore, !songLoadingMore else { return }
        songLoadingMore = true
        defer { songLoadingMore = false }

        let pageSize: Int
        if pendingSongLetter != nil {
            pageSize = 800
        } else if isInitial {
            pageSize = 120
        } else {
            pageSize = 400
        }
        let start = replace ? 0 : songNativeOffset
        let end = start + pageSize

        do {
            let page = try await session.client.nativeSongs(start: start, end: end)
            if Task.isCancelled { return }

            if page.isEmpty {
                songHasMore = false
                persistSongCatalog(complete: true)
                return
            }

            var merged: [Song]
            if replace {
                merged = page
            } else {
                merged = flatSongsCache
                var seen = Set(merged.map(\.id))
                for song in page where seen.insert(song.id).inserted {
                    merged.append(song)
                }
            }
            songNativeOffset = start + page.count
            songHasMore = page.count >= pageSize && merged.count < 50_000

            isLoading = false
            await applySongCatalog(merged)
            persistSongCatalog(complete: !songHasMore)

            if !songHasMore {
                let snapshot = merged
                Task {
                    await Task.yield()
                    session.ratings.ingest(snapshot)
                }
            }
        } catch {
            if flatSongsCache.isEmpty {
                await loadSongsViaAlbumsFallback()
            } else {
                songHasMore = false
            }
        }
    }

    /// Legacy path when `/api/song` isn't available — still sorts by title
    /// before each publish so the list doesn't thrash.
    private func loadSongsViaAlbumsFallback() async {
        songHasMore = false
        var collected: [Song] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 40

        while !Task.isCancelled {
            let albumsPage: [Album]
            do {
                albumsPage = try await session.client.albumList(
                    type: .alphabeticalByName, size: pageSize, offset: offset)
            } catch {
                if collected.isEmpty, let fallback = try? await loadSongCatalogFallback() {
                    let sorted = fallback.sorted {
                        LibrarySortLetter.sortableName($0.title)
                            .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.title)) == .orderedAscending
                    }
                    await applySongCatalog(sorted)
                    LibraryListCatalog.storeSongs(
                        sorted, serverKey: session.account.serverKey, isComplete: true)
                } else if collected.isEmpty {
                    self.error = error.localizedDescription
                }
                return
            }
            if albumsPage.isEmpty { break }

            await withTaskGroup(of: [Song].self) { group in
                for album in albumsPage {
                    group.addTask {
                        ((try? await session.client.album(id: album.id))?.songs) ?? []
                    }
                }
                for await songs in group {
                    for song in songs where seen.insert(song.id).inserted {
                        collected.append(song)
                    }
                }
            }

            let sorted = collected.sorted {
                LibrarySortLetter.sortableName($0.title)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.title)) == .orderedAscending
            }
            isLoading = false
            await applySongCatalog(sorted)

            offset += albumsPage.count
            if albumsPage.count < pageSize { break }
            await Task.yield()
        }

        if !collected.isEmpty {
            let sorted = collected.sorted {
                LibrarySortLetter.sortableName($0.title)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.title)) == .orderedAscending
            }
            LibraryListCatalog.storeSongs(
                sorted, serverKey: session.account.serverKey, isComplete: true)
            session.ratings.ingest(sorted)
        }
    }

    /// Best-effort flat song catalog when album paging isn't available.
    private func loadSongCatalogFallback() async throws -> [Song] {
        var result = try await session.client.search(
            "", artistCount: 0, albumCount: 0, songCount: 500
        ).song ?? []
        if result.isEmpty {
            result = try await session.client.search(
                "*", artistCount: 0, albumCount: 0, songCount: 500
            ).song ?? []
        }
        if result.isEmpty {
            result = try await session.client.randomSongs(size: 200)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    private func refreshLibrary(triggerScan: Bool) async {
        if triggerScan {
            await runLibraryScan(showBanner: true)
        }
        LibraryListCatalog.invalidate(serverKey: session.account.serverKey)
        albumsFillTask?.cancel()
        artistsFillTask?.cancel()
        songsFillTask?.cancel()
        albums = []
        albumSectionsCache = []
        artistSectionsCache = []
        songs = []
        songSectionsCache = []
        flatSongsCache = []
        songIndexByID = [:]
        playlists = []
        await load(forceNetwork: true)
        // Refresh the other tabs into cache in the background so flips stay instant.
        Task { @MainActor in
            await hydrateSiblingTabsAfterRefresh()
        }
    }

    private func hydrateSiblingTabsAfterRefresh() async {
        let active = filter
        if active != .playlists {
            if let fresh = try? await session.client.playlists() {
                playlists = fresh
                LibraryListCatalog.storePlaylists(fresh, serverKey: session.account.serverKey)
            }
        }
        if active != .artists {
            try? await loadArtistsCatalog(forceNetwork: true)
        }
        if active != .albums {
            await loadAlbumsCatalog(forceNetwork: true)
        }
        // Songs are large — leave them to load when that tab opens, then persist.
    }

    @discardableResult
    private func runLibraryScan(showBanner: Bool) async -> Bool {
        do {
            try await session.client.startScan()
            if showBanner { scanStatusText = "Library scan started…" }
            // Poll briefly so pull-to-refresh feels alive.
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let status = try await session.client.scanStatus()
                if status.scanning != true {
                    if showBanner {
                        let count = status.count.map(String.init) ?? "…"
                        scanStatusText = "Scan complete (\(count) items)"
                        Task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if scanStatusText?.hasPrefix("Scan complete") == true {
                                scanStatusText = nil
                            }
                        }
                    }
                    return true
                }
                if showBanner {
                    let count = status.count.map(String.init) ?? "…"
                    scanStatusText = "Scanning… \(count)"
                }
            }
            if showBanner { scanStatusText = "Scan still running…" }
            return true
        } catch {
            if showBanner { scanStatusText = "Scan failed: \(error.localizedDescription)" }
            return false
        }
    }

    private func createPlaylist() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        do {
            let created = try await session.client.createPlaylist(name: name)
            filter = .playlists
            await load(forceNetwork: true)
            if !playlists.contains(where: { $0.id == created.id }) {
                playlists.insert(created.asPlaylist, at: 0)
                LibraryListCatalog.storePlaylists(playlists, serverKey: session.account.serverKey)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func renamePlaylist() async {
        guard let playlist = playlistToRename else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        playlistToRename = nil
        guard !name.isEmpty, !rotation.isSystemPlaylist(playlist) else { return }
        do {
            try await session.client.updatePlaylist(id: playlist.id, name: name)
            await load(forceNetwork: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deletePlaylist(_ playlist: Playlist) async {
        playlistToDelete = nil
        guard !rotation.isSystemPlaylist(playlist) else { return }
        do {
            try await session.client.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            LibraryListCatalog.storePlaylists(playlists, serverKey: session.account.serverKey)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lightweight genres browser (moved off the top tab bar).
struct GenreBrowserView: View {
    var showsTitle: Bool = true
    @EnvironmentObject private var session: AppSession
    @State private var genreGroups: [NormalizedGenre] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && genreGroups.isEmpty {
                LoadingStateView()
            } else if let error, genreGroups.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }
            } else {
                List(genreGroups) { genre in
                    NavigationLink {
                        GenreDetailView(genre: genre)
                    } label: {
                        HStack {
                            Text(genre.displayName).font(DromeTheme.rowTitle)
                            Spacer()
                            if genre.songCount > 0 {
                                Text("\(genre.songCount)")
                                    .foregroundStyle(DromeTheme.muted)
                            } else if genre.albumCount > 0 {
                                Text("\(genre.albumCount)")
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .dromeMiniPlayerClearance()
            }
        }
        .navigationTitle(showsTitle ? "Genres" : "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let raw = try await session.client.genres()
            genreGroups = GenreNormalizer.shared.groupedGenres(raw)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
