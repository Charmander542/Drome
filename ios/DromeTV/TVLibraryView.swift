import SwiftUI

/// Library — Aura-inspired section picker with cover grids (Albums first).
struct TVLibraryView: View {
    private enum Shelf: String, CaseIterable {
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"
        case genres = "Genres"
    }

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @State private var shelf: Shelf = .albums
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var genres: [Genre] = []
    @State private var error: String?
    @State private var loading = false

    private let columns = [
        GridItem(
            .adaptive(minimum: TVTheme.posterCell, maximum: TVTheme.posterCell),
            spacing: TVTheme.posterGap,
            alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                TVScreenTitle(title: "Library")
                Spacer()
                Picker("Shelf", selection: $shelf) {
                    ForEach(Shelf.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 980)
            }
            .padding(.horizontal, TVTheme.gutter)
            .padding(.top, 8)

            if let error {
                Text(error).foregroundStyle(.red).padding(.horizontal, TVTheme.gutter)
            }

            ScrollView {
                Group {
                    switch shelf {
                    case .albums, .artists, .playlists:
                        LazyVGrid(columns: columns, spacing: TVTheme.posterGap + 24) {
                            switch shelf {
                            case .albums:
                                ForEach(albums) { album in
                                    TVPosterLink(
                                        title: album.name,
                                        subtitle: album.artist,
                                        coverArt: album.coverArt,
                                        fallbackId: album.id)
                                    {
                                        TVAlbumDetailView(albumID: album.id, name: album.name)
                                    }
                                }
                            case .artists:
                                ForEach(artists) { artist in
                                    TVPosterLink(
                                        title: artist.name,
                                        subtitle: artist.albumCount.map { "\($0) albums" },
                                        coverArt: artist.coverArt,
                                        fallbackId: artist.id)
                                    {
                                        TVArtistDetailView(artistID: artist.id, name: artist.name)
                                    }
                                }
                            case .playlists:
                                ForEach(playlists) { playlist in
                                    TVPosterLink(
                                        title: playlist.name,
                                        subtitle: playlist.songCountLabel,
                                        coverArt: playlist.coverArt,
                                        fallbackId: playlist.id)
                                    {
                                        TVPlaylistDetailView(
                                            playlistID: playlist.id, name: playlist.name)
                                    }
                                }
                            case .genres:
                                EmptyView()
                            }
                        }
                        .padding(.horizontal, TVTheme.gutter)
                    case .genres:
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 40), count: 4),
                            spacing: 40)
                        {
                            ForEach(genres) { genre in
                                Button {
                                    Task { await playGenre(genre) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(genre.value)
                                            .font(.system(size: 30, weight: .bold))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        if let count = genre.songCount {
                                            Text("\(count) songs")
                                                .font(.system(size: 22))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(28)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.horizontal, TVTheme.gutter)
                    }
                }
                .padding(.vertical, TVTheme.focusPad)
                .padding(.bottom, 50)

                if isEmpty {
                    Group {
                        if loading {
                            ProgressView()
                        } else {
                            Text("Nothing here yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .scrollClipDisabled()
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .task(id: session.id) { await load() }
        .task(id: shelf) {
            if shelf == .genres, genres.isEmpty {
                await loadGenres()
            }
        }
    }

    private var isEmpty: Bool {
        switch shelf {
        case .albums: return albums.isEmpty
        case .artists: return artists.isEmpty
        case .playlists: return playlists.isEmpty
        case .genres: return genres.isEmpty
        }
    }

    private func load() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            async let p = session.client.playlists()
            async let a = session.client.albumList(type: .alphabeticalByName, size: 80)
            async let indexes = session.client.artists()
            playlists = try await p
            albums = try await a
            artists = try await indexes.flatMap(\.artists)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadGenres() async {
        loading = true
        defer { loading = false }
        do {
            genres = try await session.client.genres()
                .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playGenre(_ genre: Genre) async {
        let songs = (try? await session.client.songsByGenre(genre.value, count: 100)) ?? []
        guard !songs.isEmpty else { return }
        player.play(
            songs,
            startAt: 0,
            context: PlaybackContext(label: genre.value, kind: .mix))
        NowPlayingPresenter.open()
    }
}
