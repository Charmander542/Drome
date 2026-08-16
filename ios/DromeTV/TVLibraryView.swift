import SwiftUI

struct TVLibraryView: View {
    private enum Shelf: String, CaseIterable {
        case playlists = "Playlists"
        case albums = "Albums"
        case artists = "Artists"
    }

    @EnvironmentObject private var session: AppSession
    @State private var shelf: Shelf = .playlists
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var error: String?

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
                .frame(maxWidth: 720)
            }
            .padding(.horizontal, TVTheme.gutter)
            .padding(.top, 8)

            if let error {
                Text(error).foregroundStyle(.red).padding(.horizontal, TVTheme.gutter)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: TVTheme.posterGap + 24) {
                    switch shelf {
                    case .playlists:
                        ForEach(playlists) { playlist in
                            TVPosterLink(
                                title: playlist.name,
                                subtitle: playlist.songCountLabel,
                                coverArt: playlist.coverArt,
                                fallbackId: playlist.id)
                            {
                                TVPlaylistDetailView(playlistID: playlist.id, name: playlist.name)
                            }
                        }
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
                    }
                }
                .padding(.horizontal, TVTheme.gutter)
                .padding(.vertical, TVTheme.focusPad)
                .padding(.bottom, 50)
            }
        }
        .background(TVTheme.canvas.ignoresSafeArea())
        .task(id: session.id) { await load() }
    }

    private func load() async {
        error = nil
        do {
            async let p = session.client.playlists()
            async let a = session.client.albumList(type: .alphabeticalByName, size: 60)
            async let indexes = session.client.artists()
            playlists = try await p
            albums = try await a
            artists = try await indexes.flatMap(\.artists)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
