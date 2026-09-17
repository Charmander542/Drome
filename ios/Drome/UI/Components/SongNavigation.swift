import SwiftUI
import UIKit

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

        init(album: Album) {
            albumId = album.id
            name = album.name
            artist = album.artist
            artistId = album.artistId
            coverArt = album.coverArt
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
        guard let route = SongNavigation.albumRoute(for: song) else { return }
        presentAlbum(route)
    }

    func viewAlbum(_ album: Album) {
        guard !album.id.isEmpty else { return }
        presentAlbum(SongNavigation.AlbumRoute(album: album))
    }

    private func presentAlbum(_ route: SongNavigation.AlbumRoute) {
        if albumRoute?.albumId == route.albumId {
            albumRoute = nil
            DispatchQueue.main.async { self.albumRoute = route }
        } else {
            albumRoute = route
        }
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

    func popToRoot() {
        albumRoute = nil
        artistRoute = nil
    }
}

private struct SongNavigatorKey: EnvironmentKey {
    static let defaultValue: SongNavigator? = nil
}

private struct TabPopToRootTriggerKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private struct TabScrollToTopTriggerKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Optional accessor so artist taps never hard-crash if a stack forgot to inject.
    var songNavigator: SongNavigator? {
        get { self[SongNavigatorKey.self] }
        set { self[SongNavigatorKey.self] = newValue }
    }

    /// Bumped when the user re-taps the selected tab (used to reset root chrome).
    var tabPopToRootTrigger: Int {
        get { self[TabPopToRootTriggerKey.self] }
        set { self[TabPopToRootTriggerKey.self] = newValue }
    }

    /// Bumped only when the selected tab is already at its root — scroll to top.
    var tabScrollToTopTrigger: Int {
        get { self[TabScrollToTopTriggerKey.self] }
        set { self[TabScrollToTopTriggerKey.self] = newValue }
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
    /// Bumped by the tab bar when the user re-taps the selected tab.
    var popToRootTrigger: Int = 0
    @StateObject private var navigator = SongNavigator()
    @State private var path = NavigationPath()
    /// Remount clears destination `NavigationLink` pushes (playlists, etc.) that
    /// are not reflected in `path`.
    @State private var stackID = UUID()
    @State private var navigationDepth = 0
    @State private var scrollToTopTrigger = 0
    @ViewBuilder var content: () -> Content

    init(popToRootTrigger: Int = 0, @ViewBuilder content: @escaping () -> Content) {
        self.popToRootTrigger = popToRootTrigger
        self.content = content
    }

    private var isDeep: Bool {
        navigationDepth > 0
            || !path.isEmpty
            || navigator.albumRoute != nil
            || navigator.artistRoute != nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .background {
                    NavigationDepthReader(depth: $navigationDepth)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
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
        .id(stackID)
        // Critical: inject on the stack, not only the root page, so pushed
        // Album/Playlist/Artist detail views still see SongNavigator.
        .environmentObject(navigator)
        .environment(\.songNavigator, navigator)
        .environment(\.tabPopToRootTrigger, popToRootTrigger)
        .environment(\.tabScrollToTopTrigger, scrollToTopTrigger)
        // TabView + outer safeAreaInset often fails to extend List scroll insets;
        // pad here only while the mini player is visible.
        .dromeMiniPlayerClearance()
        .onChange(of: popToRootTrigger) { _, trigger in
            guard trigger > 0 else { return }
            if isDeep {
                // Destination NavigationLinks (playlists, downloads, …) are not in
                // `path` — remount when UIKit reports pushed pages. Album/artist
                // item routes clear via the navigator alone when depth is 0.
                let shouldRemount = navigationDepth > 0 || !path.isEmpty
                path = NavigationPath()
                navigator.popToRoot()
                if shouldRemount {
                    stackID = UUID()
                }
                navigationDepth = 0
            } else {
                scrollToTopTrigger += 1
            }
        }
    }
}

/// Reports how many pages are pushed on the hosting `UINavigationController`.
private struct NavigationDepthReader: UIViewControllerRepresentable {
    @Binding var depth: Int

    func makeUIViewController(context: Context) -> ProbeController {
        ProbeController(depth: $depth)
    }

    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.depth = $depth
        DispatchQueue.main.async { controller.publish() }
    }

    final class ProbeController: UIViewController {
        var depth: Binding<Int>
        private var observation: NSKeyValueObservation?

        init(depth: Binding<Int>) {
            self.depth = depth
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            publish()
            startObserving()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            publish()
            startObserving()
        }

        func publish() {
            let count = navigationController?.viewControllers.count ?? 1
            let next = max(0, count - 1)
            if depth.wrappedValue != next {
                depth.wrappedValue = next
            }
        }

        private func startObserving() {
            observation?.invalidate()
            observation = navigationController?.observe(\.viewControllers, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.publish() }
            }
        }

        deinit {
            observation?.invalidate()
        }
    }
}
