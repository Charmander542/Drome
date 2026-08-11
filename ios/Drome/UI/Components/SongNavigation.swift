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

        init(artistId: String, name: String) {
            self.artistId = artistId
            self.name = name
        }

        init(song: Song) {
            if let credit = ArtistCredits.credits(for: song).first(where: { $0.artistId != nil }),
               let id = credit.artistId {
                artistId = id
                name = credit.name
            } else {
                artistId = song.artistId ?? ""
                name = song.artist ?? song.displayArtist
            }
        }
    }

    static func albumRoute(for song: Song) -> AlbumRoute? {
        guard let id = song.albumId, !id.isEmpty else { return nil }
        return AlbumRoute(song: song)
    }

    static func artistRoute(for song: Song) -> ArtistRoute? {
        if let credit = ArtistCredits.credits(for: song).first(where: { ($0.artistId ?? "").isEmpty == false }),
           let id = credit.artistId {
            return ArtistRoute(artistId: id, name: credit.name)
        }
        guard let id = song.artistId, !id.isEmpty else { return nil }
        return ArtistRoute(artistId: id, name: song.artist ?? song.displayArtist)
    }

    static func artistRoutes(for song: Song) -> [ArtistRoute] {
        ArtistCredits.credits(for: song).compactMap { credit in
            guard let id = credit.artistId, !id.isEmpty else { return nil }
            return ArtistRoute(artistId: id, name: credit.name)
        }
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

    func viewArtist(id: String, name: String) {
        guard !id.isEmpty else { return }
        let route = SongNavigation.ArtistRoute(artistId: id, name: name)
        // Clearing first forces `navigationDestination(item:)` to fire even when
        // tapping the same artist again; also avoids stale presentation races.
        if artistRoute?.artistId == route.artistId {
            artistRoute = nil
            DispatchQueue.main.async { self.artistRoute = route }
        } else {
            artistRoute = route
        }
    }
}

private struct SongNavigatorKey: EnvironmentKey {
    static let defaultValue: SongNavigator? = nil
}

extension EnvironmentValues {
    /// Optional accessor so artist taps never hard-crash if a stack forgot to inject.
    var songNavigator: SongNavigator? {
        get { self[SongNavigatorKey.self] }
        set { self[SongNavigatorKey.self] = newValue }
    }
}

extension View {
    /// Register once on the `NavigationStack` root (outside any lazy container).
    /// Apply to the `NavigationStack` itself (not only its root content) so pushed
    /// album/playlist pages inherit `SongNavigator`.
    func songNavigationDestinations(navigator: SongNavigator) -> some View {
        self
            .environmentObject(navigator)
            .environment(\.songNavigator, navigator)
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
        // Critical: inject on the stack, not only the root page, so pushed
        // Album/Playlist/Artist detail views still see SongNavigator.
        .environmentObject(navigator)
        .environment(\.songNavigator, navigator)
    }
}
