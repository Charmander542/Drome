import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case rated = "Rated"
    case albums = "Albums"
    case artists = "Artists"
    case genres = "Genres"
    case downloads = "Downloads"
    case wishlist = "Wishlist"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .playlists: return "music.note.list"
        case .rated: return "star.fill"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .genres: return "guitars"
        case .downloads: return "arrow.down.circle"
        case .wishlist: return "heart"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var rotation: RotationManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var filter: LibraryFilter = .playlists
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artistIndexes: [ArtistIndex] = []
    @State private var genres: [Genre] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var playlistToDelete: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            content
        }
        .navigationTitle("Your Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .refreshable { await load() }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(filter == item ? DromeTheme.accent : DromeTheme.elevated)
                            .foregroundStyle(filter == item ? Color.white : Color.white.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled(false)
        .scrollBounceBehavior(.basedOnSize)
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
            case .rated: RatedLibraryView()
            case .albums: albumsList
            case .artists: artistsList
            case .genres: genresList
            case .downloads:
                DownloadsView()
            case .wishlist:
                WishlistView()
            }
        }
    }

    private var isEmpty: Bool {
        switch filter {
        case .playlists: return playlists.isEmpty
        case .rated: return false
        case .albums: return albums.isEmpty
        case .artists: return artistIndexes.isEmpty
        case .genres: return genres.isEmpty
        case .downloads, .wishlist: return false
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.id, placeholder: album)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .hoverEffectDisabled()
                }
            }
            .padding(16)
            .padding(.bottom, 72)
        }
        .scrollClipDisabled(false)
    }

    private var artistsList: some View {
        List {
            ForEach(artistIndexes) { index in
                Section(index.name) {
                    ForEach(index.artists) { artist in
                        NavigationLink {
                            ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                        } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: session.client.coverArtURL(id: artist.coverArt ?? artist.id, size: 120),
                                            placeholderSymbol: "person.crop.circle")
                                    .frame(width: 48, height: 48)
                                    .clipShape(Circle())
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
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    private var genresList: some View {
        List(genres) { genre in
            NavigationLink {
                GenreDetailView(genre: genre)
            } label: {
                HStack {
                    Text(genre.value).font(DromeTheme.rowTitle)
                    Spacer()
                    if let count = genre.albumCount {
                        Text("\(count)")
                            .foregroundStyle(DromeTheme.muted)
                    }
                }
            }
            .listRowBackground(DromeTheme.background)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        var parts: [String] = []
        if let owner = playlist.owner { parts.append(owner) }
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if playlist.isPublic == true { parts.append("Shared") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        // Downloads / wishlist / rated manage their own loading.
        guard filter != .downloads && filter != .wishlist && filter != .rated else { return }
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
            case .genres:
                genres = try await session.client.genres().sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            case .downloads, .wishlist, .rated:
                break
            }
        } catch {
            self.error = error.localizedDescription
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
            // Keep the brand-new playlist visible at the top if the server order differs.
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
