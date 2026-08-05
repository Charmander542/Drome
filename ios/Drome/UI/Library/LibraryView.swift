import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case downloads = "Downloaded"
    case outOfRotation = "Out of Rotation"

    var id: String { rawValue }

    /// Short label for the compact segmented bar.
    var shortTitle: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .downloads: return "Downloaded"
        case .outOfRotation: return "Rotation"
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
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var playlistToDelete: Playlist?
    @State private var scanStatusText: String?

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
        .task(id: filter) { await load() }
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
            ForEach(LibraryFilter.allCases) { item in
                Button {
                    filter = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.shortTitle)
                            .font(.caption.weight(filter == item ? .bold : .semibold))
                            .foregroundStyle(filter == item ? Color.white : Color.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Capsule()
                            .fill(filter == item ? DromeTheme.accent : Color.clear)
                            .frame(height: 2)
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
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && isEmpty {
            LoadingStateView()
        } else if let error, isEmpty {
            ErrorStateView(message: error) { Task { await load() } }
        } else {
            switch filter {
            case .playlists: playlistsList
            case .albums: albumsList
            case .artists: artistsList
            case .songs: songsList
            case .downloads:
                DownloadsView()
            case .outOfRotation:
                outOfRotationContent
            }
        }
    }

    private var isEmpty: Bool {
        switch filter {
        case .playlists: return playlists.isEmpty
        case .albums: return albums.isEmpty
        case .artists: return artistIndexes.isEmpty
        case .songs: return songs.isEmpty
        case .downloads, .outOfRotation: return false
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
                    GenreBrowserView()
                } label: {
                    Label("Genres", systemImage: "guitars")
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
                                    RemoteImage(url: session.client.coverArtURL(id: playlist.coverArt ?? playlist.id, size: 120),
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
            List {
                ForEach(albumSections, id: \.letter) { section in
                    Section {
                        ForEach(section.albums) { album in
                            NavigationLink {
                                AlbumDetailView(albumID: album.id, placeholder: album)
                            } label: {
                                HStack(spacing: 12) {
                                    RemoteImage(url: session.client.coverArtURL(id: album.coverArt ?? album.id, size: 120))
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name).font(DromeTheme.rowTitle)
                                        Text(album.artist ?? "Unknown Artist")
                                            .font(.caption)
                                            .foregroundStyle(DromeTheme.muted)
                                    }
                                }
                            }
                            .listRowBackground(DromeTheme.background)
                        }
                    } header: {
                        Text(section.letter)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                            .id(section.letter)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(letters: albumSections.map(\.letter)) { letter in
                    proxy.scrollTo(letter, anchor: .top)
                }
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
        }
    }

    private var albumSections: [(letter: String, albums: [Album])] {
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
            List {
                ForEach(artistSections, id: \.letter) { section in
                    Section {
                        ForEach(section.artists) { artist in
                            NavigationLink {
                                ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                            } label: {
                                HStack(spacing: 12) {
                                    ArtistAvatar(artistId: artist.id, name: artist.name,
                                                 navidromeCoverArt: artist.coverArt)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name).font(DromeTheme.rowTitle)
                                        if let count = artist.albumCount {
                                            Text("\(count) albums")
                                                .font(.caption)
                                                .foregroundStyle(DromeTheme.muted)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(DromeTheme.background)
                        }
                    } header: {
                        Text(section.letter)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                            .id(section.letter)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(letters: artistSections.map(\.letter)) { letter in
                    proxy.scrollTo(letter, anchor: .top)
                }
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
        }
    }

    private var artistSections: [(letter: String, artists: [Artist])] {
        var buckets: [String: [Artist]] = [:]
        for index in artistIndexes {
            let letter = LibrarySortLetter.sectionLetter(for: index.name, preferWholeIfSingle: true)
            buckets[letter, default: []].append(contentsOf: index.artists)
        }
        return buckets.keys.sorted(by: LibrarySortLetter.sectionLetterSort).compactMap { letter in
            guard var artists = buckets[letter], !artists.isEmpty else { return nil }
            var seen = Set<String>()
            artists = artists.filter { seen.insert($0.id).inserted }
            artists.sort {
                LibrarySortLetter.sortableName($0.name)
                    .localizedCaseInsensitiveCompare(LibrarySortLetter.sortableName($1.name)) == .orderedAscending
            }
            return (letter: letter, artists: artists)
        }
    }

    private var songsList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(songSections, id: \.letter) { section in
                    Section {
                        ForEach(Array(section.songs.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, showAlbum: true)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let flat = songSections.flatMap(\.songs)
                                    let start = flat.firstIndex(where: { $0.id == song.id }) ?? 0
                                    playerPlay(flat, startAt: start)
                                }
                                .listRowBackground(DromeTheme.background)
                        }
                    } header: {
                        Text(section.letter)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                            .id(section.letter)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay(alignment: .trailing) {
                AlphabetScrubber(letters: songSections.map(\.letter)) { letter in
                    proxy.scrollTo(letter, anchor: .top)
                }
                .padding(.vertical, 8)
                .padding(.trailing, 1)
            }
        }
    }

    private var songSections: [(letter: String, songs: [Song])] {
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

    private func playerPlay(_ songs: [Song], startAt: Int) {
        player.play(songs, startAt: startAt, context: PlaybackContext(label: "Songs", kind: .mix))
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        var parts: [String] = []
        if let owner = playlist.owner { parts.append(owner) }
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if playlist.isPublic == true { parts.append("Shared") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard filter != .downloads else { return }
        if filter == .outOfRotation {
            await rotation.refresh()
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch filter {
            case .playlists:
                playlists = try await session.client.playlists()
                await rotation.refresh()
            case .albums:
                albums = try await session.client.albumList(type: .alphabeticalByName, size: 500)
            case .artists:
                artistIndexes = try await session.client.artists()
            case .songs:
                songs = try await loadSongCatalog()
            case .downloads, .outOfRotation:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Best-effort flat song catalog for the Songs tab.
    private func loadSongCatalog() async throws -> [Song] {
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
        await load()
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
            await load()
            if !playlists.contains(where: { $0.id == created.id }) {
                playlists.insert(created.asPlaylist, at: 0)
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
            await load()
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lightweight genres browser (moved off the top tab bar).
struct GenreBrowserView: View {
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
            }
        }
        .navigationTitle("Genres")
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
