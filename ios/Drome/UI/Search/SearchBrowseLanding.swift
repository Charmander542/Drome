import SwiftUI

/// In-memory browse grid so push/pop / cancelled `.task` reloads never blank tiles.
@MainActor
enum SearchBrowseCache {
    struct Snapshot {
        var ranked: [NormalizedGenre]
        var visibleCount: Int
        var genreArt: [String: URL]
        var genreColors: [String: Color]
        var usedCoverIds: Set<String>
    }

    private static var byServer: [String: Snapshot] = [:]

    static func cached(serverKey: String) -> Snapshot? {
        byServer[serverKey]
    }

    static func store(_ snapshot: Snapshot, serverKey: String) {
        byServer[serverKey] = snapshot
    }

    static func invalidate(serverKey: String) {
        byServer.removeValue(forKey: serverKey)
    }
}

/// Search home: color-washed genre grid. The `.searchable` field lives on `SearchView`.
struct SearchBrowseLanding: View {
    @EnvironmentObject private var session: AppSession

    /// Full ranked list — every tile is shown; artwork pages in as you scroll.
    @State private var ranked: [NormalizedGenre] = []
    /// How many leading genres have had artwork requested (tiles still show without it).
    @State private var artFetchedCount = 0
    @State private var genreArt: [String: URL] = [:]
    @State private var genreColors: [String: Color] = [:]
    @State private var usedCoverIds = Set<String>()
    @State private var isLoadingGenres = true
    @State private var isLoadingMoreArt = false
    @State private var selectedGenre: NormalizedGenre?

    private let artworkPageSize = 12

    private var serverKey: String { session.account.serverKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse Genres")
                    .font(DromeTheme.sectionFont)
                    .foregroundStyle(.white)

                if isLoadingGenres && ranked.isEmpty {
                    ProgressView()
                        .tint(DromeTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if ranked.isEmpty {
                    Text("Genres from your library will show up here.")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                } else {
                    // Eager grid (not Lazy) so tiles stay in the render tree while
                    // Search covers this landing — Cancel never flashes empty black.
                    let genres = ranked
                    let rows = stride(from: 0, to: genres.count, by: 2).map { start in
                        Array(genres[start..<min(start + 2, genres.count)])
                    }
                    VStack(spacing: 14) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 12) {
                                ForEach(row) { genre in
                                    Button {
                                        selectedGenre = genre
                                    } label: {
                                        SearchGenreTile(
                                            title: genre.displayName,
                                            artworkURL: genreArt[genre.id],
                                            color: genreColors[genre.id]
                                                ?? SearchBrowsePalette.washes[0]
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(genre.displayName)
                                    .frame(maxWidth: .infinity)
                                }
                                if row.count == 1 {
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 104)
                                }
                            }
                            .onAppear {
                                let lastIndex = min((rowIndex + 1) * 2, genres.count) - 1
                                if lastIndex >= artFetchedCount - 4 {
                                    Task { await loadNextArtworkPageIfNeeded() }
                                }
                            }
                        }
                    }

                    if isLoadingMoreArt, artFetchedCount < ranked.count {
                        ProgressView()
                            .tint(DromeTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DromeTheme.background.ignoresSafeArea())
        // Don’t auto-dismiss — parent SearchView owns keyboard focus.
        .scrollDismissesKeyboard(.never)
        .navigationDestination(item: $selectedGenre) { genre in
            GenreDetailView(genre: genre)
        }
        .task(id: serverKey) {
            seedFromCacheIfNeeded()
            await loadInitial(forceNetwork: false)
        }
        .onDisappear {
            // Persist before a remount so back-navigation never flashes empty.
            persistCache()
        }
    }

    private func seedFromCacheIfNeeded() {
        guard ranked.isEmpty,
              let cached = SearchBrowseCache.cached(serverKey: serverKey),
              !cached.ranked.isEmpty else { return }
        apply(cached)
        isLoadingGenres = false
    }

    private func apply(_ snapshot: SearchBrowseCache.Snapshot) {
        ranked = snapshot.ranked
        // Older caches stored a partial visibleCount — always show every ranked tile.
        artFetchedCount = min(max(snapshot.visibleCount, 0), snapshot.ranked.count)
        genreArt = snapshot.genreArt
        genreColors = snapshot.genreColors
        usedCoverIds = snapshot.usedCoverIds
    }

    private func persistCache() {
        guard !ranked.isEmpty else { return }
        SearchBrowseCache.store(
            .init(
                ranked: ranked,
                // Reuse visibleCount slot for art progress so cache shape stays stable.
                visibleCount: max(artFetchedCount, 0),
                genreArt: genreArt,
                genreColors: genreColors,
                usedCoverIds: usedCoverIds
            ),
            serverKey: serverKey
        )
    }

    private func loadInitial(forceNetwork: Bool) async {
        let hadContent = !ranked.isEmpty
        if !hadContent {
            seedFromCacheIfNeeded()
        }
        let showingCached = !ranked.isEmpty
        // Never clear a populated grid for a background refresh.
        if !showingCached { isLoadingGenres = true }
        defer { isLoadingGenres = false }

        if !forceNetwork, showingCached {
            // Still top up art for any tiles missing covers.
            if artFetchedCount < ranked.count {
                await loadNextArtworkPageIfNeeded()
            }
            return
        }

        do {
            let raw = try await session.client.genres()
            let grouped = GenreNormalizer.shared.groupedGenres(raw)
            let picks = selectBrowseGenres(grouped)
            // Empty network must not wipe tiles that were already on screen.
            guard !picks.isEmpty || !hadContent else { return }

            ranked = picks
            genreColors = SearchBrowsePalette.uniqueWashes(for: picks.map(\.id))
            if hadContent, artFetchedCount > 0 {
                artFetchedCount = min(artFetchedCount, picks.count)
            } else {
                artFetchedCount = 0
                usedCoverIds = []
                genreArt = [:]
            }
            await loadNextArtworkPageIfNeeded()
            persistCache()
        } catch is CancellationError {
            // Pushing a genre cancels `.task` — keep whatever we already painted.
            return
        } catch {
            if !showingCached {
                ranked = []
                artFetchedCount = 0
                genreArt = [:]
                genreColors = [:]
            }
        }
    }

    private func loadNextArtworkPageIfNeeded() async {
        guard !isLoadingMoreArt else { return }
        guard artFetchedCount < ranked.count else { return }
        isLoadingMoreArt = true

        let start = artFetchedCount
        let end = min(ranked.count, start + artworkPageSize)
        let page = Array(ranked[start..<end])
        artFetchedCount = end
        await loadGenreArtwork(for: page)
        persistCache()
        isLoadingMoreArt = false

        // Eager VStack fires onAppear while a page is in flight — keep going
        // so later tiles still get covers without another scroll nudge.
        if artFetchedCount < ranked.count {
            await loadNextArtworkPageIfNeeded()
        }
    }

    /// Prefer genres you actually listen to, then strong library buckets —
    /// not alphabetical “first X”.
    private func selectBrowseGenres(_ grouped: [NormalizedGenre]) -> [NormalizedGenre] {
        guard !grouped.isEmpty else { return [] }
        let boost = preferenceBoost()
        return grouped
            .map { genre -> (NormalizedGenre, Double) in
                let library = log1p(Double(max(0, genre.songCount) + max(0, genre.albumCount) * 4))
                let pref = boost[genre.displayName] ?? 0
                return (genre, library * 0.55 + pref * 2.4)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Recency-weighted genre hits from recent plays + player history.
    private func preferenceBoost() -> [String: Double] {
        var boost: [String: Double] = [:]
        let recent = (try? session.database.recentPlays(
            userKey: session.account.userKey, limit: 48
        )) ?? []
        for (index, song) in recent.enumerated() {
            guard let raw = song.genre, !raw.isEmpty,
                  let name = GenreNormalizer.shared.normalize(raw) else { continue }
            boost[name, default: 0] += 1.0 / Double(index + 2)
        }
        for (index, item) in session.player.history.prefix(24).enumerated() {
            guard let raw = item.song.genre, !raw.isEmpty,
                  let name = GenreNormalizer.shared.normalize(raw) else { continue }
            boost[name, default: 0] += 0.55 / Double(index + 2)
        }
        if let raw = session.player.current?.song.genre, !raw.isEmpty,
           let name = GenreNormalizer.shared.normalize(raw) {
            boost[name, default: 0] += 1.2
        }
        return boost
    }

    private func loadGenreArtwork(for genres: [NormalizedGenre]) async {
        let client = session.client
        var candidates: [String: [String]] = [:]
        do {
            try await withThrowingTaskGroup(of: (String, [String]).self) { group in
                for genre in genres {
                    group.addTask {
                        let tag = genre.rawTags.first ?? genre.displayName
                        let albums = (try? await client.albumList(
                            type: .byGenre,
                            size: 16,
                            genre: tag
                        )) ?? []
                        var ids: [String] = []
                        var seen = Set<String>()
                        for album in albums {
                            let coverId = album.coverArt ?? album.id
                            guard !coverId.isEmpty, seen.insert(coverId).inserted else { continue }
                            ids.append(coverId)
                        }
                        return (genre.id, ids)
                    }
                }
                for try await (id, ids) in group {
                    candidates[id] = ids
                }
            }
        } catch is CancellationError {
            // Partial art is fine — titles still show.
            return
        } catch {
            return
        }

        var used = usedCoverIds
        var urls = genreArt
        for genre in genres {
            guard urls[genre.id] == nil else { continue }
            let pick = candidates[genre.id]?.first { !used.contains($0) }
            guard let coverId = pick else { continue }
            used.insert(coverId)
            if let url = session.artworkURL(id: coverId, size: 300) {
                urls[genre.id] = url
            }
        }
        usedCoverIds = used
        genreArt = urls
        ImageLoader.shared.prefetch(Array(urls.values), limit: artworkPageSize)
    }
}

/// Genre card — no blend modes (they were wiping the title inside NavigationLink).
private struct SearchGenreTile: View {
    let title: String
    let artworkURL: URL?
    let color: Color

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background {
                ZStack {
                    color
                    if let artworkURL {
                        RemoteImage(url: artworkURL, holdImageWhileLoading: true)
                            .scaledToFill()
                            .grayscale(1)
                            .opacity(0.58)
                            .colorMultiply(color)
                    }
                }
                .clipped()
            }
            .overlay {
                // Top scrim so white type always reads.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.72),
                        Color.black.opacity(0.28),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

enum SearchBrowsePalette {
    /// Distinct washes — enough for every curated top-level genre.
    static let washes: [Color] = [
        Color(red: 0.78, green: 0.28, blue: 0.34),
        Color(red: 0.22, green: 0.48, blue: 0.92),
        Color(red: 0.92, green: 0.52, blue: 0.14),
        Color(red: 0.16, green: 0.64, blue: 0.48),
        Color(red: 0.62, green: 0.28, blue: 0.82),
        Color(red: 0.12, green: 0.62, blue: 0.74),
        Color(red: 0.86, green: 0.28, blue: 0.52),
        Color(red: 0.42, green: 0.72, blue: 0.28),
        Color(red: 0.92, green: 0.72, blue: 0.18),
        Color(red: 0.36, green: 0.32, blue: 0.78),
        Color(red: 0.78, green: 0.42, blue: 0.28),
        Color(red: 0.22, green: 0.56, blue: 0.62),
        Color(red: 0.70, green: 0.24, blue: 0.40),
        Color(red: 0.30, green: 0.38, blue: 0.58),
        Color(red: 0.55, green: 0.58, blue: 0.22),
        Color(red: 0.48, green: 0.22, blue: 0.48),
        Color(red: 0.18, green: 0.40, blue: 0.36),
        Color(red: 0.84, green: 0.36, blue: 0.22),
        Color(red: 0.28, green: 0.28, blue: 0.68),
        Color(red: 0.58, green: 0.18, blue: 0.28),
        Color(red: 0.20, green: 0.52, blue: 0.28),
        Color(red: 0.72, green: 0.48, blue: 0.16),
        Color(red: 0.40, green: 0.20, blue: 0.56),
        Color(red: 0.16, green: 0.44, blue: 0.56),
    ]

    /// One unique color per id in order — no hash collisions.
    static func uniqueWashes(for ids: [String]) -> [String: Color] {
        var map: [String: Color] = [:]
        for (index, id) in ids.enumerated() {
            map[id] = washes[index % washes.count]
        }
        return map
    }

    static func wash(for key: String) -> Color {
        gradient(for: key)[0]
    }

    static func gradient(for key: String) -> [Color] {
        var hash = 0
        for scalar in key.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        let color = washes[abs(hash) % washes.count]
        return [color, color.opacity(0.65)]
    }
}
