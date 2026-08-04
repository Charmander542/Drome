import SwiftUI
import Combine

struct SearchView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var ratings: RatingsStore

    @State private var query = ""
    @State private var includeLyrics = false
    @State private var isSearching = false
    @State private var hits: [SearchHit] = []
    @State private var error: String?
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        results
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Artists, songs, albums…")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        includeLyrics.toggle()
                        scheduleSearch(query)
                    } label: {
                        Image(systemName: includeLyrics ? "text.quote" : "text.quote")
                            .symbolVariant(includeLyrics ? .fill : .none)
                            .foregroundStyle(includeLyrics ? DromeTheme.accent : Color.white.opacity(0.7))
                    }
                    .accessibilityLabel(includeLyrics ? "Lyrics search on" : "Lyrics search off")
                }
            }
            .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var results: some View {
        if isSearching && hits.isEmpty {
            LoadingStateView(message: "Searching…")
        } else if let error {
            ErrorStateView(message: error)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(title: "Find your music",
                           systemImage: "magnifyingglass",
                           message: "Try an artist, album, song, or a line of lyrics.")
        } else if hits.isEmpty && !isSearching {
            EmptyStateView(title: "No results", message: "Try a different query.")
        } else {
            rankedList
        }
    }

    private var rankedList: some View {
        List {
            ForEach(hits) { hit in
                hitRow(hit)
                    .listRowBackground(DromeTheme.background)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { _ in
                searchFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        )
    }

    @ViewBuilder
    private func hitRow(_ hit: SearchHit) -> some View {
        switch hit.kind {
        case .artist:
            if let artist = hit.artist {
                NavigationLink {
                    ArtistDetailView(artistID: artist.id, placeholderName: artist.name)
                } label: {
                    hitLabel(hit, shape: .circle)
                }
            }
        case .album:
            if let album = hit.album {
                NavigationLink {
                    AlbumDetailView(albumID: album.id, placeholder: album)
                } label: {
                    hitLabel(hit, shape: .rounded)
                }
            }
        case .song:
            if let song = hit.song {
                Button {
                    let songs = hits.compactMap(\.song)
                    let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                    player.play(songs.isEmpty ? [song] : songs, startAt: start,
                                context: PlaybackContext(label: "Search", kind: .search))
                } label: {
                    hitLabel(hit, shape: .rounded)
                }
                .buttonStyle(.plain)
                .songSwipeActions(for: song)
                .contextMenu {
                    Button { player.playNext(song) } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button { player.addToQueue(song) } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                }
            }
        case .lyrics:
            if let lyric = hit.lyrics {
                Button {
                    Task { await playLyricsHit(lyric) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        hitLabel(hit, shape: .rounded, showsCover: false)
                        Text(lyric.snippet)
                            .font(.caption)
                            .foregroundStyle(DromeTheme.accent)
                            .lineLimit(2)
                            .padding(.leading, 60)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private enum CoverShape { case circle, rounded }

    private func hitLabel(_ hit: SearchHit, shape: CoverShape, showsCover: Bool = true) -> some View {
        HStack(spacing: 12) {
            if showsCover {
                Group {
                    RemoteImage(url: session.client.coverArtURL(id: hit.coverArt, size: 120),
                                placeholderSymbol: placeholder(for: hit.kind))
                }
                .frame(width: 44, height: 44)
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(DromeTheme.elevated2)
                    Image(systemName: "text.quote")
                        .foregroundStyle(DromeTheme.muted)
                }
                .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if hit.kind == .song, let song = hit.song {
                        RatingBadge(rating: ratings.rating(for: song))
                    } else if hit.kind == .album, let album = hit.album, let rating = album.userRating, rating > 0 {
                        RatingBadge(rating: rating)
                    }
                }
                Text(hit.subtitle)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(kindBadge(hit.kind))
                .font(.caption2.weight(.bold))
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func kindBadge(_ kind: SearchHit.Kind) -> String {
        switch kind {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .song: return "SONG"
        case .lyrics: return "LYRICS"
        }
    }

    private func placeholder(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .artist: return "person.crop.circle"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .lyrics: return "text.quote"
        }
    }

    private func scheduleSearch(_ raw: String) {
        debounceTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            error = nil
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ q: String) async {
        isSearching = true
        error = nil
        defer { isSearching = false }
        do {
            async let metadataTask = session.client.search(q, artistCount: 20, albumCount: 20, songCount: 40)
            let lyrics: [LyricsSearchMatch]
            if includeLyrics {
                lyrics = (try? AppEnvironment.shared.database.searchLyrics(
                    serverKey: session.account.serverKey, query: q)) ?? []
            } else {
                lyrics = []
            }
            let metadata = try await metadataTask
            ratings.ingest(metadata.songs)
            hits = SearchRanker.rank(query: q, result: metadata, lyrics: lyrics)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playLyricsHit(_ hit: LyricsSearchMatch) async {
        do {
            let song = try await session.client.song(id: hit.songId)
            player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Lyrics search", kind: .search))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Type-erased Shape so we can pick Circle vs RoundedRectangle in one call site.
private struct AnyShape: Shape {
    private let builder: (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        builder = { shape.path(in: $0) }
    }
    func path(in rect: CGRect) -> Path { builder(rect) }
}
