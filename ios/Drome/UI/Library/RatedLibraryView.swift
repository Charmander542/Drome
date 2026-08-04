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
                Text("Auto playlists from your ratings and likes. They update as you rate.")
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

    var body: some View {
        Group {
            if isLoading && songs.isEmpty && albums.isEmpty {
                LoadingStateView()
            } else if let error, songs.isEmpty && albums.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }
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
        .task { await load() }
        .refreshable { await load() }
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
                        Button {
                            player.play(songs, startAt: index,
                                        context: PlaybackContext(label: collection.rawValue, kind: .mix))
                        } label: {
                            SongRow(song: song, showAlbum: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DromeTheme.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
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
                            NavigationLink {
                                AlbumDetailView(albumID: album.id, placeholder: album)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
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
        case .topAlbums: return "Rate albums to see them ranked here."
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch collection {
            case .fiveStars:
                songs = try await loadRatedSongs(minRating: 5)
                albums = []
            case .fourPlus:
                songs = try await loadRatedSongs(minRating: 4)
                albums = []
            case .topAlbums:
                albums = try await session.client.albumList(type: .highest, size: 80)
                songs = []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pulls highly rated tracks from top albums + random samples.
    private func loadRatedSongs(minRating: Int) async throws -> [Song] {
        var byID: [String: Song] = [:]

        func consider(_ batch: [Song]) {
            ratings.ingest(batch)
            for song in batch where ratings.rating(for: song) >= minRating {
                byID[song.id] = song
            }
        }

        let topAlbums = try await session.client.albumList(type: .highest, size: 30)
        for album in topAlbums.prefix(20) {
            let detail = try await session.client.album(id: album.id)
            consider(detail.songs)
        }

        for _ in 0..<2 {
            let batch = try await session.client.randomSongs(size: 100)
            consider(batch)
        }

        return byID.values.sorted {
            let r0 = ratings.rating(for: $0)
            let r1 = ratings.rating(for: $1)
            if r0 != r1 { return r0 > r1 }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}
