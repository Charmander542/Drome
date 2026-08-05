import SwiftUI

/// Shared “View Album” / “View Artist” destinations for song context menus.
enum SongNavigation {
    struct AlbumRoute: Hashable, Identifiable {
        var id: String { albumId }
        let albumId: String
        let name: String
        let artist: String?
        let artistId: String?
        let coverArt: String?

        init(song: Song) {
            albumId = song.albumId ?? ""
            name = song.album ?? song.title
            artist = song.artist
            artistId = song.artistId
            coverArt = song.coverArt
        }

        var album: Album {
            Album(
                id: albumId,
                name: name,
                artist: artist,
                artistId: artistId,
                coverArt: coverArt,
                songCount: nil, duration: nil, playCount: nil,
                created: nil, year: nil, genre: nil, userRating: nil
            )
        }
    }

    struct ArtistRoute: Hashable, Identifiable {
        var id: String { artistId }
        let artistId: String
        let name: String

        init(song: Song) {
            artistId = song.artistId ?? ""
            name = song.artist ?? song.displayArtist
        }
    }

    static func albumRoute(for song: Song) -> AlbumRoute? {
        guard let id = song.albumId, !id.isEmpty else { return nil }
        return AlbumRoute(song: song)
    }

    static func artistRoute(for song: Song) -> ArtistRoute? {
        guard let id = song.artistId, !id.isEmpty else { return nil }
        return ArtistRoute(song: song)
    }
}

/// Owns album/artist push routes for a single `NavigationStack`.
/// Destinations must be registered on the stack root — never inside a `List` row.
@MainActor
final class SongNavigator: ObservableObject {
    @Published var albumRoute: SongNavigation.AlbumRoute?
    @Published var artistRoute: SongNavigation.ArtistRoute?

    func viewAlbum(for song: Song) {
        albumRoute = SongNavigation.albumRoute(for: song)
    }

    func viewArtist(for song: Song) {
        artistRoute = SongNavigation.artistRoute(for: song)
    }
}

extension View {
    /// Register once on the `NavigationStack` root (outside any lazy container).
    func songNavigationDestinations(navigator: SongNavigator) -> some View {
        self
            .environmentObject(navigator)
            .navigationDestination(item: Binding(
                get: { navigator.albumRoute },
                set: { navigator.albumRoute = $0 }
            )) { route in
                AlbumDetailView(albumID: route.albumId, placeholder: route.album)
            }
            .navigationDestination(item: Binding(
                get: { navigator.artistRoute },
                set: { navigator.artistRoute = $0 }
            )) { route in
                ArtistDetailView(artistID: route.artistId, placeholderName: route.name)
            }
    }

    /// Convenience when the caller already holds `@StateObject` bindings.
    func songNavigationDestinations(
        album: Binding<SongNavigation.AlbumRoute?>,
        artist: Binding<SongNavigation.ArtistRoute?>
    ) -> some View {
        self
            .navigationDestination(item: album) { route in
                AlbumDetailView(albumID: route.albumId, placeholder: route.album)
            }
            .navigationDestination(item: artist) { route in
                ArtistDetailView(artistID: route.artistId, placeholderName: route.name)
            }
    }
}

/// Wraps tab/root content so song Go-to destinations live outside Lists.
struct SongNavigationStack<Content: View>: View {
    @StateObject private var navigator = SongNavigator()
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .songNavigationDestinations(navigator: navigator)
        }
    }
}
