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
    @State private var albumWindow: [LibraryLetterSection<Album>] = []
    @State private var albumLetters: [String] = []
    @State private var albumRevealCount = 80
    @State private var artistWindow: [LibraryLetterSection<Artist>] = []
    @State private var artistLetters: [String] = []
    @State private var songWindow: [LibraryLetterSection<Song>] = []
    @State private var songLetters: [String] = []
    @State private var songRevealCount = 80
    @State private var isLoading = false
    @State private var albumsHasMore = false
    @State private var albumsLoadingMore = false
    @State private var albumsOffset = 0
    @State private var albumsFillTask: Task<Void, Never>?
    @State private var pendingAlbumLetter: String?
    @State private var albumScrollTarget: String?
    @State private var albumWindowBusy = false
    @State private var albumIgnoreRetreatUntil = Date.distantPast
    @State private var artistsFillTask: Task<Void, Never>?
    @State private var pendingArtistLetter: String?
    @State private var artistScrollTarget: String?
    @State private var artistWindowBusy = false
    @State private var artistIgnoreRetreatUntil = Date.distantPast
    @State private var songHasMore = false
    @State private var songLoadingMore = false
    @State private var songNativeOffset = 0
    @State private var songsFillTask: Task<Void, Never>?
    @State private var pendingSongLetter: String?
    @State private var songScrollTarget: String?
    @State private var songWindowBusy = false
    @State private var songIgnoreRetreatUntil = Date.distantPast
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
            await importLegacyLibraryIndexIfNeeded()
            await hydratePlaylistsFromCache()
            await ensureActiveTabReady(forceNetwork: false)
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
                        if artistWindow.isEmpty && isLoading && filter == .artists {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            artistsList
                        }
                    }
                }
                if visitedFilters.contains(.albums) {
                    keepAlivePane(.albums) {
                        if albumWindow.isEmpty && isLoading && filter == .albums {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            albumsList
                        }
                    }
                }
                if visitedFilters.contains(.songs) {
                    keepAlivePane(.songs) {
                        if songWindow.isEmpty && isLoading && filter == .songs {
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
            || !albumWindow.isEmpty
            || !artistWindow.isEmpty
            || !songWindow.isEmpty
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
        case .albums: return albumWindow.isEmpty
        case .artists: return artistWindow.isEmpty
        case .songs: return songWindow.isEmpty
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
                    ForEach(albumWindow) { section in
                        Section {
                            let isLast = section.letter == albumWindow.last?.letter
                            let rows = isLast
                                ? Array(section.items.prefix(albumRevealCount))
                                : section.items
                            ForEach(rows) { album in
                                AlbumMediaRow(album: album, showsChevron: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 56)

                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 84)
                            }
                            if isLast && albumRevealCount < section.items.count {
                                ProgressView()
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity)
                                    .onAppear {
                                        albumRevealCount = min(
                                            section.items.count,
                                            albumRevealCount + Self.letterRevealPage)
                                    }
                            } else if isLast {
                                letterEdgeRow(hasMore: Self.nextLetter(after: section.letter, in: albumLetters) != nil) {
                                    Task { await appendAlbumLetter(after: section.letter) }
                                }
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

                    if albumsHasMore && albumWindow.isEmpty {
                        ProgressView()
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 72)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y <= geo.contentInsets.top + 24
            } action: { wasNearTop, isNearTop in
                guard isNearTop, !wasNearTop, let first = albumWindow.first?.letter else { return }
                Task { await prependAlbumLetter(before: first) }
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
        }
    }

    private var artistsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(artistWindow) { section in
                        Section {
                            let isLast = section.letter == artistWindow.last?.letter
                            ForEach(section.items) { artist in
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
                            if isLast {
                                letterEdgeRow(hasMore: Self.nextLetter(after: section.letter, in: artistLetters) != nil) {
                                    Task { await appendArtistLetter(after: section.letter) }
                                }
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
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y <= geo.contentInsets.top + 24
            } action: { wasNearTop, isNearTop in
                guard isNearTop, !wasNearTop, let first = artistWindow.first?.letter else { return }
                Task { await prependArtistLetter(before: first) }
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
        }
    }

    private var songsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(songWindow) { section in
                        Section {
                            let isLast = section.letter == songWindow.last?.letter
                            let rows = isLast
                                ? Array(section.items.prefix(songRevealCount))
                                : section.items
                            ForEach(rows, id: \.id) { song in
                                SongRow(song: song, showAlbum: true, lightweight: true) {
                                    playSongFromLibrary(song)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)

                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 76)
                            }
                            if isLast && songRevealCount < section.items.count {
                                ProgressView()
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity)
                                    .onAppear {
                                        songRevealCount = min(
                                            section.items.count,
                                            songRevealCount + Self.letterRevealPage)
                                    }
                            } else if isLast {
                                letterEdgeRow(hasMore: Self.nextLetter(after: section.letter, in: songLetters) != nil) {
                                    Task { await appendSongLetter(after: section.letter) }
                                }
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

                    if songHasMore && songWindow.isEmpty {
                        ProgressView()
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 72)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y <= geo.contentInsets.top + 24
            } action: { wasNearTop, isNearTop in
                guard isNearTop, !wasNearTop, let first = songWindow.first?.letter else { return }
                Task { await prependSongLetter(before: first) }
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
        }
    }

    @ViewBuilder
    private func letterEdgeRow(hasMore: Bool, load: @escaping () -> Void) -> some View {
        if hasMore {
            Color.clear
                .frame(height: 1)
                .onAppear(perform: load)
        }
    }

    /// Shared list thumbnail size — small & sharp enough for 48pt rows.
    private static let listArtSize = 96
    private static let letterReveal = 80
    private static let letterRevealPage = 80
    private static let playFromHereLimit = 500
    private static let maxWindowLetters = 4
    /// Don't drop a short letter that's likely still on screen.
    private static let hardMaxWindowLetters = 10
    private static let trimIfLetterLongerThan = 40

    private static func nextLetter(after letter: String, in letters: [String]) -> String? {
        guard let idx = letters.firstIndex(of: letter), idx + 1 < letters.count else { return nil }
        return letters[idx + 1]
    }

    private static func previousLetter(before letter: String, in letters: [String]) -> String? {
        guard let idx = letters.firstIndex(of: letter), idx > 0 else { return nil }
        return letters[idx - 1]
    }

    /// Letters around a jump target so scrolling up or down stays on one list.
    private static func neighborhood(center: String, in letters: [String]) -> [String] {
        guard let idx = letters.firstIndex(of: center) else { return [center] }
        var from = idx
        var to = idx
        while to - from + 1 < maxWindowLetters {
            let canBefore = from > 0
            let canAfter = to + 1 < letters.count
            if !canBefore && !canAfter { break }
            let beforeDist = idx - from
            let afterDist = to - idx
            if canBefore && (!canAfter || beforeDist <= afterDist) {
                from -= 1
            } else {
                to += 1
            }
        }
        return Array(letters[from...to])
    }

    private static func trimLetterWindow<Item: Identifiable>(
        _ window: inout [LibraryLetterSection<Item>],
        droppingFromStart: Bool
    ) {
        while window.count > maxWindowLetters {
            let far = droppingFromStart ? window.first : window.last
            let farIsLong = (far?.items.count ?? 0) >= trimIfLetterLongerThan
            if window.count > hardMaxWindowLetters || farIsLong {
                if droppingFromStart {
                    window.removeFirst()
                } else {
                    window.removeLast()
                }
            } else {
                break
            }
        }
    }

    private func playSongFromLibrary(_ song: Song) {
        let key = session.account.serverKey
        let index = session.library
        Task {
            let queue = await Task.detached(priority: .userInitiated) {
                (try? index.songs(serverKey: key, startingAt: song.id, limit: Self.playFromHereLimit)) ?? [song]
            }.value
            player.play(queue, startAt: 0, context: PlaybackContext(label: "Songs", kind: .mix))
        }
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

    private func importLegacyLibraryIndexIfNeeded() async {
        let key = session.account.serverKey
        let index = session.library
        await Task.detached(priority: .utility) {
            index.importLegacyJSONIfNeeded(serverKey: key)
        }.value
    }

    private func hydratePlaylistsFromCache() async {
        let serverKey = session.account.serverKey
        if playlists.isEmpty,
           let cached = LibraryListCatalog.playlists(serverKey: serverKey),
           !cached.isEmpty {
            playlists = cached
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

    // MARK: - SQLite letter windows (Albums / Artists / Songs)

    private func serverKey() -> String { session.account.serverKey }

    private func indexLetters(_ kind: LibraryIndexKind) async -> [String] {
        let key = serverKey()
        let index = session.library
        return await Task.detached(priority: .utility) {
            (try? index.letters(kind: kind, serverKey: key)) ?? []
        }.value
    }

    private func indexCount(_ kind: LibraryIndexKind) async -> Int {
        let key = serverKey()
        let index = session.library
        return await Task.detached(priority: .utility) {
            (try? index.count(kind: kind, serverKey: key)) ?? 0
        }.value
    }

    private func indexComplete(_ kind: LibraryIndexKind) async -> Bool {
        let key = serverKey()
        let index = session.library
        return await Task.detached(priority: .utility) {
            (try? index.isComplete(kind: kind, serverKey: key)) ?? false
        }.value
    }

    private func showAlbumLetter(_ letter: String) async {
        albumIgnoreRetreatUntil = Date().addingTimeInterval(0.55)
        let sections = await loadAlbumSections(Self.neighborhood(center: letter, in: albumLetters))
        albumRevealCount = Self.letterReveal
        albumWindow = sections
        if let items = sections.first(where: { $0.letter == letter })?.items
            ?? sections.first?.items {
            warmAlbumCovers(Array(items.prefix(24)))
        }
        albumScrollTarget = letter
    }

    private func showArtistLetter(_ letter: String) async {
        artistIgnoreRetreatUntil = Date().addingTimeInterval(0.55)
        let sections = await loadArtistSections(Self.neighborhood(center: letter, in: artistLetters))
        artistWindow = sections
        if let items = sections.first(where: { $0.letter == letter })?.items
            ?? sections.first?.items {
            warmArtistCovers(Array(items.prefix(24)))
        }
        artistScrollTarget = letter
    }

    private func showSongLetter(_ letter: String) async {
        songIgnoreRetreatUntil = Date().addingTimeInterval(0.55)
        let sections = await loadSongSections(Self.neighborhood(center: letter, in: songLetters))
        songRevealCount = Self.letterReveal
        songWindow = sections
        if let items = sections.first(where: { $0.letter == letter })?.items
            ?? sections.first?.items {
            warmSongCovers(Array(items.prefix(24)))
        }
        songScrollTarget = letter
    }

    private func loadAlbumSections(_ letters: [String]) async -> [LibraryLetterSection<Album>] {
        let key = serverKey()
        let index = session.library
        var loaded: [(Int, LibraryLetterSection<Album>)] = []
        await withTaskGroup(of: (Int, String, [Album]).self) { group in
            for (offset, letter) in letters.enumerated() {
                group.addTask {
                    let items = (try? index.albums(serverKey: key, letter: letter)) ?? []
                    return (offset, letter, items)
                }
            }
            for await (offset, letter, items) in group where !items.isEmpty {
                loaded.append((offset, LibraryLetterSection(letter: letter, items: items)))
            }
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func loadArtistSections(_ letters: [String]) async -> [LibraryLetterSection<Artist>] {
        let key = serverKey()
        let index = session.library
        var loaded: [(Int, LibraryLetterSection<Artist>)] = []
        await withTaskGroup(of: (Int, String, [Artist]).self) { group in
            for (offset, letter) in letters.enumerated() {
                group.addTask {
                    let items = (try? index.artists(serverKey: key, letter: letter)) ?? []
                    return (offset, letter, items)
                }
            }
            for await (offset, letter, items) in group where !items.isEmpty {
                loaded.append((offset, LibraryLetterSection(letter: letter, items: items)))
            }
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func loadSongSections(_ letters: [String]) async -> [LibraryLetterSection<Song>] {
        let key = serverKey()
        let index = session.library
        var loaded: [(Int, LibraryLetterSection<Song>)] = []
        await withTaskGroup(of: (Int, String, [Song]).self) { group in
            for (offset, letter) in letters.enumerated() {
                group.addTask {
                    let items = (try? index.songs(serverKey: key, letter: letter)) ?? []
                    return (offset, letter, items)
                }
            }
            for await (offset, letter, items) in group where !items.isEmpty {
                loaded.append((offset, LibraryLetterSection(letter: letter, items: items)))
            }
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func appendAlbumLetter(after letter: String) async {
        guard !albumWindowBusy,
              let next = Self.nextLetter(after: letter, in: albumLetters),
              !albumWindow.contains(where: { $0.letter == next }) else { return }
        albumWindowBusy = true
        defer { albumWindowBusy = false }
        let sections = await loadAlbumSections([next])
        guard let section = sections.first,
              !albumWindow.contains(where: { $0.letter == section.letter }) else { return }
        albumRevealCount = Self.letterReveal
        albumWindow.append(section)
        Self.trimLetterWindow(&albumWindow, droppingFromStart: true)
    }

    private func prependAlbumLetter(before letter: String) async {
        guard Date() >= albumIgnoreRetreatUntil,
              albumScrollTarget == nil,
              !albumWindowBusy,
              let prev = Self.previousLetter(before: letter, in: albumLetters),
              !albumWindow.contains(where: { $0.letter == prev }) else { return }
        albumWindowBusy = true
        defer { albumWindowBusy = false }
        let sections = await loadAlbumSections([prev])
        guard let section = sections.first,
              !albumWindow.contains(where: { $0.letter == section.letter }) else { return }
        let anchor = albumWindow.first?.letter
        albumWindow.insert(section, at: 0)
        Self.trimLetterWindow(&albumWindow, droppingFromStart: false)
        if let anchor {
            albumScrollTarget = anchor
        }
    }

    private func appendArtistLetter(after letter: String) async {
        guard !artistWindowBusy,
              let next = Self.nextLetter(after: letter, in: artistLetters),
              !artistWindow.contains(where: { $0.letter == next }) else { return }
        artistWindowBusy = true
        defer { artistWindowBusy = false }
        let sections = await loadArtistSections([next])
        guard let section = sections.first,
              !artistWindow.contains(where: { $0.letter == section.letter }) else { return }
        artistWindow.append(section)
        Self.trimLetterWindow(&artistWindow, droppingFromStart: true)
    }

    private func prependArtistLetter(before letter: String) async {
        guard Date() >= artistIgnoreRetreatUntil,
              artistScrollTarget == nil,
              !artistWindowBusy,
              let prev = Self.previousLetter(before: letter, in: artistLetters),
              !artistWindow.contains(where: { $0.letter == prev }) else { return }
        artistWindowBusy = true
        defer { artistWindowBusy = false }
        let sections = await loadArtistSections([prev])
        guard let section = sections.first,
              !artistWindow.contains(where: { $0.letter == section.letter }) else { return }
        let anchor = artistWindow.first?.letter
        artistWindow.insert(section, at: 0)
        Self.trimLetterWindow(&artistWindow, droppingFromStart: false)
        if let anchor {
            artistScrollTarget = anchor
        }
    }

    private func appendSongLetter(after letter: String) async {
        guard !songWindowBusy,
              let next = Self.nextLetter(after: letter, in: songLetters),
              !songWindow.contains(where: { $0.letter == next }) else { return }
        songWindowBusy = true
        defer { songWindowBusy = false }
        let sections = await loadSongSections([next])
        guard let section = sections.first,
              !songWindow.contains(where: { $0.letter == section.letter }) else { return }
        songRevealCount = Self.letterReveal
        songWindow.append(section)
        Self.trimLetterWindow(&songWindow, droppingFromStart: true)
    }

    private func prependSongLetter(before letter: String) async {
        guard Date() >= songIgnoreRetreatUntil,
              songScrollTarget == nil,
              !songWindowBusy,
              let prev = Self.previousLetter(before: letter, in: songLetters),
              !songWindow.contains(where: { $0.letter == prev }) else { return }
        songWindowBusy = true
        defer { songWindowBusy = false }
        let sections = await loadSongSections([prev])
        guard let section = sections.first,
              !songWindow.contains(where: { $0.letter == section.letter }) else { return }
        let anchor = songWindow.first?.letter
        songWindow.insert(section, at: 0)
        Self.trimLetterWindow(&songWindow, droppingFromStart: false)
        if let anchor {
            songScrollTarget = anchor
        }
    }

    private func refreshVisibleIfNeeded(
        kind: LibraryIndexKind,
        pageLetters: Set<String>,
        pending: String?
    ) async {
        let letters = await indexLetters(kind)
        let pendingHit = pending.map { pageLetters.contains($0) } ?? false

        switch kind {
        case .albums:
            albumLetters = letters
            if pendingHit, let pending {
                await showAlbumLetter(pending)
            } else if let current = albumWindow.first?.letter, pageLetters.contains(current) {
                await reloadAlbumLetter(current)
            } else if albumWindow.isEmpty, let first = letters.first {
                await showAlbumLetter(first)
            }
        case .artists:
            artistLetters = letters
            if pendingHit, let pending {
                await showArtistLetter(pending)
            } else if artistWindow.isEmpty, let first = letters.first {
                await showArtistLetter(first)
            }
        case .songs:
            songLetters = letters
            if pendingHit, let pending {
                await showSongLetter(pending)
            } else if let current = songWindow.first?.letter, pageLetters.contains(current) {
                await reloadSongLetter(current)
            } else if songWindow.isEmpty, let first = letters.first {
                await showSongLetter(first)
            }
        }
    }

    private func reloadAlbumLetter(_ letter: String) async {
        let key = serverKey()
        let index = session.library
        let items = await Task.detached(priority: .utility) {
            (try? index.albums(serverKey: key, letter: letter)) ?? []
        }.value
        if let idx = albumWindow.firstIndex(where: { $0.letter == letter }) {
            albumWindow[idx] = LibraryLetterSection(letter: letter, items: items)
        }
    }

    private func reloadSongLetter(_ letter: String) async {
        let key = serverKey()
        let index = session.library
        let items = await Task.detached(priority: .utility) {
            (try? index.songs(serverKey: key, letter: letter)) ?? []
        }.value
        if let idx = songWindow.firstIndex(where: { $0.letter == letter }) {
            songWindow[idx] = LibraryLetterSection(letter: letter, items: items)
        }
    }

    private func loadAlbumsCatalog(forceNetwork: Bool = false) async {
        albumsFillTask?.cancel()
        pendingAlbumLetter = nil

        if !forceNetwork, !albumWindow.isEmpty {
            isLoading = false
            albumLetters = await indexLetters(.albums)
            albumsHasMore = !(await indexComplete(.albums))
            albumsOffset = await indexCount(.albums)
            if albumsHasMore {
                albumsFillTask = Task { @MainActor in
                    await fillAlbumsInBackground()
                }
            }
            return
        }

        let count = await indexCount(.albums)
        if !forceNetwork, count > 0 {
            albumLetters = await indexLetters(.albums)
            albumsHasMore = !(await indexComplete(.albums))
            albumsOffset = count
            isLoading = false
            if let first = albumLetters.first {
                await showAlbumLetter(first)
            }
            if albumsHasMore {
                albumsFillTask = Task { @MainActor in
                    await fillAlbumsInBackground()
                }
            }
            return
        }

        if forceNetwork {
            let key = serverKey()
            let index = session.library
            try? await Task.detached {
                try index.clear(kind: .albums, serverKey: key)
            }.value
            albumWindow = []
            albumLetters = []
        }
        albumsOffset = 0
        albumsHasMore = true
        await loadMoreAlbums(isInitial: true, replace: true)
        guard !Task.isCancelled else { return }
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
        albumLetters = await indexLetters(.albums)
        if let pending = pendingAlbumLetter, albumLetters.contains(pending) {
            pendingAlbumLetter = nil
            await showAlbumLetter(pending)
        }
    }

    private func snapScroll(_ proxy: ScrollViewProxy, to letter: String) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(letter, anchor: .top)
        }
    }

    private func jumpAlbums(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let resolved = albumLetters.contains(letter)
            ? letter
            : LibrarySortLetter.nearestSectionLetter(letter, in: albumLetters)

        if let resolved, albumWindow.contains(where: { $0.letter == resolved }) {
            snapScroll(proxy, to: resolved)
            if !dragging { pendingAlbumLetter = nil }
            return
        }

        if dragging { return }

        if let resolved, albumLetters.contains(resolved) {
            pendingAlbumLetter = nil
            Task { await showAlbumLetter(resolved) }
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
            let key = serverKey()
            let index = session.library
            if page.isEmpty {
                albumsHasMore = false
                try? await Task.detached {
                    try index.appendAlbums([], serverKey: key, isComplete: true)
                }.value
                return
            }

            albumsOffset = offset + page.count
            albumsHasMore = page.count >= pageSize && albumsOffset < 50_000
            let complete = !albumsHasMore
            try? await Task.detached(priority: .utility) {
                if replace {
                    try index.replaceAlbums(page, serverKey: key, isComplete: complete)
                } else {
                    try index.appendAlbums(page, serverKey: key, isComplete: complete)
                }
            }.value

            isLoading = false
            let pageLetters = Set(page.map { LibrarySortLetter.sectionLetter(for: $0.name) })
            await refreshVisibleIfNeeded(kind: .albums, pageLetters: pageLetters, pending: pendingAlbumLetter)
            if let pending = pendingAlbumLetter, albumLetters.contains(pending) {
                pendingAlbumLetter = nil
            }
        } catch {
            if albumWindow.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadArtistsCatalog(forceNetwork: Bool = false) async throws {
        artistsFillTask?.cancel()

        if !forceNetwork, !artistWindow.isEmpty {
            isLoading = false
            artistLetters = await indexLetters(.artists)
            return
        }

        let count = await indexCount(.artists)
        if !forceNetwork, count > 0 {
            artistLetters = await indexLetters(.artists)
            isLoading = false
            if let first = artistLetters.first {
                await showArtistLetter(first)
            }
            return
        }

        let indexes = try await session.client.artists()
        guard !Task.isCancelled else { return }
        let artists = indexes.flatMap(\.artists)
        let key = serverKey()
        let index = session.library
        try? await Task.detached(priority: .utility) {
            try index.replaceArtists(artists, serverKey: key)
        }.value
        artistLetters = await indexLetters(.artists)
        isLoading = false
        let pending = pendingArtistLetter
        pendingArtistLetter = nil
        let letter = pending.flatMap { artistLetters.contains($0) ? $0 : nil }
            ?? artistLetters.first
        if let letter {
            await showArtistLetter(letter)
        }
    }

    private func jumpArtists(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let resolved = artistLetters.contains(letter)
            ? letter
            : LibrarySortLetter.nearestSectionLetter(letter, in: artistLetters)

        if let resolved, artistWindow.contains(where: { $0.letter == resolved }) {
            snapScroll(proxy, to: resolved)
            if !dragging { pendingArtistLetter = nil }
            return
        }

        if dragging { return }

        if let resolved, artistLetters.contains(resolved) {
            pendingArtistLetter = nil
            Task { await showArtistLetter(resolved) }
            return
        }

        pendingArtistLetter = letter
    }

    private func loadFullSongCatalog(forceNetwork: Bool = false) async {
        songsFillTask?.cancel()
        pendingSongLetter = nil

        if !forceNetwork, !songWindow.isEmpty {
            isLoading = false
            songLetters = await indexLetters(.songs)
            songHasMore = !(await indexComplete(.songs))
            songNativeOffset = await indexCount(.songs)
            if songHasMore {
                songsFillTask = Task { @MainActor in
                    await fillSongsInBackground()
                }
            }
            return
        }

        let count = await indexCount(.songs)
        if !forceNetwork, count > 0 {
            songLetters = await indexLetters(.songs)
            songHasMore = !(await indexComplete(.songs))
            songNativeOffset = count
            isLoading = false
            if let first = songLetters.first {
                await showSongLetter(first)
            }
            if songHasMore {
                songsFillTask = Task { @MainActor in
                    await fillSongsInBackground()
                }
            }
            return
        }

        if forceNetwork {
            let key = serverKey()
            let index = session.library
            try? await Task.detached {
                try index.clear(kind: .songs, serverKey: key)
            }.value
            songWindow = []
            songLetters = []
        }
        songNativeOffset = 0
        songHasMore = true
        await loadMoreSongs(isInitial: true, replace: true)
        guard !Task.isCancelled else { return }
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
        songLetters = await indexLetters(.songs)
        if let pending = pendingSongLetter, songLetters.contains(pending) {
            pendingSongLetter = nil
            await showSongLetter(pending)
        }
    }

    private func jumpSongs(to letter: String, proxy: ScrollViewProxy, dragging: Bool) {
        let resolved = songLetters.contains(letter)
            ? letter
            : LibrarySortLetter.nearestSectionLetter(letter, in: songLetters)

        if let resolved, songWindow.contains(where: { $0.letter == resolved }) {
            snapScroll(proxy, to: resolved)
            if !dragging { pendingSongLetter = nil }
            return
        }

        if dragging { return }

        if let resolved, songLetters.contains(resolved) {
            pendingSongLetter = nil
            Task { await showSongLetter(resolved) }
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
            let key = serverKey()
            let index = session.library

            if page.isEmpty {
                songHasMore = false
                try? await Task.detached {
                    try index.appendSongs([], serverKey: key, isComplete: true)
                }.value
                return
            }

            songNativeOffset = start + page.count
            songHasMore = page.count >= pageSize && songNativeOffset < 80_000
            let complete = !songHasMore
            try? await Task.detached(priority: .utility) {
                if replace {
                    try index.replaceSongs(page, serverKey: key, isComplete: complete)
                } else {
                    try index.appendSongs(page, serverKey: key, isComplete: complete)
                }
            }.value

            isLoading = false
            let pageLetters = Set(page.map { LibrarySortLetter.sectionLetter(for: $0.title) })
            await refreshVisibleIfNeeded(kind: .songs, pageLetters: pageLetters, pending: pendingSongLetter)
            if let pending = pendingSongLetter, songLetters.contains(pending) {
                pendingSongLetter = nil
            }

            if complete {
                Task {
                    await Task.yield()
                    session.ratings.ingest(page)
                }
            }
        } catch {
            if songWindow.isEmpty {
                await loadSongsViaAlbumsFallback()
            } else {
                songHasMore = false
            }
        }
    }

    /// Legacy path when `/api/song` isn't available.
    private func loadSongsViaAlbumsFallback() async {
        songHasMore = false
        var collected: [Song] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 40
        let key = serverKey()
        let index = session.library

        while !Task.isCancelled {
            let albumsPage: [Album]
            do {
                albumsPage = try await session.client.albumList(
                    type: .alphabeticalByName, size: pageSize, offset: offset)
            } catch {
                if collected.isEmpty, let fallback = try? await loadSongCatalogFallback() {
                    try? await Task.detached {
                        try index.replaceSongs(fallback, serverKey: key, isComplete: true)
                    }.value
                    songLetters = await indexLetters(.songs)
                    isLoading = false
                    if let first = songLetters.first {
                        await showSongLetter(first)
                    }
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

            try? await Task.detached {
                try index.replaceSongs(collected, serverKey: key, isComplete: false)
            }.value
            songLetters = await indexLetters(.songs)
            isLoading = false
            if songWindow.isEmpty, let first = songLetters.first {
                await showSongLetter(first)
            }

            offset += albumsPage.count
            if albumsPage.count < pageSize { break }
            await Task.yield()
        }

        if !collected.isEmpty {
            try? await Task.detached {
                try index.replaceSongs(collected, serverKey: key, isComplete: true)
            }.value
            session.ratings.ingest(collected)
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
        let key = serverKey()
        let index = session.library
        try? await Task.detached {
            try index.clearAll(serverKey: key)
        }.value
        albumsFillTask?.cancel()
        artistsFillTask?.cancel()
        songsFillTask?.cancel()
        albumWindow = []
        albumLetters = []
        artistWindow = []
        artistLetters = []
        songWindow = []
        songLetters = []
        playlists = []
        await load(forceNetwork: true)
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
