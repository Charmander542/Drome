import SwiftUI

/// Auto collections driven by Subsonic ratings (not server playlists).
enum RatedCollection: String, CaseIterable, Identifiable {
    case fiveStars = "5 Stars"
    case fourPlus = "4 Stars & Up"
    case topAlbums = "Top Rated Albums"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .fiveStars: return "star.fill"
        case .fourPlus: return "star.leadinghalf.filled"
        case .topAlbums: return "rectangle.stack.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .fiveStars: return "Your absolute favorites"
        case .fourPlus: return "Highly rated tracks"
        case .topAlbums: return "Albums ranked by your ratings"
        }
    }

    var accent: Color {
        switch self {
        case .fiveStars, .fourPlus: return .yellow
        case .topAlbums: return DromeTheme.accent
        }
    }
}

struct RatedLibraryView: View {
    var body: some View {
        List {
            Section {
                Text("Auto playlists from your ratings. They update as you rate tracks.")
                    .font(.subheadline)
                    .foregroundStyle(DromeTheme.muted)
                    .listRowBackground(DromeTheme.background)
            }

            Section {
                ForEach(RatedCollection.allCases) { collection in
                    NavigationLink {
                        RatedCollectionDetailView(collection: collection)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(collection.accent.opacity(0.22))
                                Image(systemName: collection.systemImage)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(collection.accent)
                            }
                            .frame(width: 52, height: 52)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.rawValue)
                                    .font(DromeTheme.rowTitle)
                                    .foregroundStyle(.white)
                                Text(collection.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(DromeTheme.muted)
                            }
                        }
                    }
                    .listRowBackground(DromeTheme.background)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
    }
}

struct RatedCollectionDetailView: View {
    let collection: RatedCollection

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore

    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if isLoading && songs.isEmpty && albums.isEmpty {
                LoadingStateView()
            } else if let error, songs.isEmpty && albums.isEmpty {
                ErrorStateView(message: error) { Task { await load(forceDiscover: true) } }
            } else if collection == .topAlbums {
                albumsContent
            } else {
                songsContent
            }
        }
        .navigationTitle(collection.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.play(songs, startAt: 0,
                                    context: PlaybackContext(label: collection.rawValue, kind: .mix))
                    } label: {
                        Image(systemName: "play.fill")
                    }
                }
            }
        }
        .task {
            await load(forceDiscover: false)
        }
        .onChange(of: ratings.revision) { _, _ in
            applyLocalCache()
        }
        .refreshable { await load(forceDiscover: true) }
    }

    private var songsContent: some View {
        Group {
            if songs.isEmpty {
                EmptyStateView(
                    title: "Nothing here yet",
                    systemImage: collection.systemImage,
                    message: emptyMessage
                )
            } else {
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, showAlbum: true) {
                            player.play(songs, startAt: index,
                                        context: PlaybackContext(label: collection.rawValue, kind: .mix))
                        }
                        .listRowBackground(DromeTheme.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
                .overlay(alignment: .top) {
                    if isRefreshing {
                        ProgressView()
                            .padding(8)
                    }
                }
            }
        }
    }

    private var albumsContent: some View {
        Group {
            if albums.isEmpty {
                EmptyStateView(
                    title: "No rated albums yet",
                    systemImage: "rectangle.stack",
                    message: "Rate albums or tracks and they’ll show up here."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                        ForEach(albums) { album in
                            AlbumCard(album: album)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 72)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch collection {
        case .fiveStars: return "Give tracks five stars on the Now Playing screen."
        case .fourPlus: return "Rate tracks 4 or 5 stars to fill this list."
        case .topAlbums: return "Rate the album itself (not just its tracks) to see it here."
        }
    }

    private func load(forceDiscover: Bool) async {
        error = nil

        if collection == .topAlbums {
            isLoading = albums.isEmpty
            defer { isLoading = false }
            do {
                let remote = try await session.client.albumList(type: .highest, size: 100)
                // Only albums that themselves have a star rating — not ones
                // where only individual tracks were rated.
                albums = remote
                    .filter { ($0.userRating ?? 0) > 0 }
                    .sorted {
                        let r0 = $0.userRating ?? 0
                        let r1 = $1.userRating ?? 0
                        if r0 != r1 { return r0 > r1 }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                songs = []
            } catch {
                self.error = error.localizedDescription
            }
            return
        }

        applyLocalCache()
        isLoading = songs.isEmpty
        defer { isLoading = false }

        if forceDiscover || songs.isEmpty {
            isRefreshing = true
            defer { isRefreshing = false }
            await ratings.discoverFromServer()
            applyLocalCache()
        }
    }

    private func applyLocalCache() {
        switch collection {
        case .fiveStars:
            songs = ratings.cachedSongs(minRating: 5)
            albums = []
        case .fourPlus:
            songs = ratings.cachedSongs(minRating: 4)
            albums = []
        case .topAlbums:
            albums = []
            songs = []
        }
    }
}
