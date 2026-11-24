import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.tabPopToRootTrigger) private var tabPopToRootTrigger
    @Environment(\.tabScrollToTopTrigger) private var tabScrollToTopTrigger
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var recentEntries: [RecentPlayEntry] = []
    @State private var homePlaylists: [Playlist] = []
    @State private var newest: [Album] = []
    @State private var dailyMixes: [DailyMix] = []
    @State private var dailyMixesDate: String?
    /// Start true so the rail shows placeholders instead of the generic empty
    /// copy before `.task` assigns a real `mixesError`.
    @State private var mixesLoading = true
    @State private var mixesError: String?
    @State private var madeForYou: [DailyMix] = []
    @State private var madeForYouLoading = true
    /// Start true so rails reserve space instead of popping in after network.
    @State private var isLoading = true
    @State private var error: String?
    @State private var showSettings = false
    @State private var scrollToTopToken = 0

    private var hasCompanion: Bool { session.wishlist != nil }
    private var onPublicDemo: Bool { session.account.isPublicDemo }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 0).id("home-top")

                    // Compact brand — Vibe Tuner is the hero immediately under it.
                    homeBrandRow

                    if onPublicDemo && !hasCompanion {
                        streamingOnlyBanner
                    }

                    VibeTuner()

                    // On-device Made for you — works without a companion server.
                    if !madeForYou.isEmpty || madeForYouLoading || MadeForYouPreferences.anyShelfEnabled {
                        DailyMixRail(
                            mixes: madeForYou,
                            title: "Made for you",
                            subtitle: "Daypart, vibes, genres, Nonstop, and fresh finds — rebuilds through the day.",
                            isLoading: madeForYouLoading,
                            loadError: madeForYou.isEmpty && !madeForYouLoading
                                ? "Couldn’t build mixes yet."
                                : nil,
                            onRetry: { Task { await loadMadeForYou(force: true) } }
                        )
                    }

                    // Companion taste clusters — ratings / similar artists on the wishlist server.
                    if hasCompanion {
                        DailyMixRail(
                            mixes: dailyMixes,
                            title: "Daily Mixes",
                            subtitle: "From ratings, plays, and similar artists — refreshes daily.",
                            isLoading: mixesLoading,
                            loadError: mixesError,
                            onRetry: { Task { await loadMixes() } }
                        )
                        // Temporarily hidden — revisit OutsidePicksRail / "Get these".
                        // OutsidePicksRail()
                    }

                    if !recentEntries.isEmpty {
                        HorizontalRecentRail(
                            title: "Continue",
                            entries: recentEntries,
                            dailyMixes: hasCompanion ? dailyMixes : [])
                    } else if isLoading {
                        HomeRailPlaceholder(title: "Continue")
                    }

                    if !homePlaylists.isEmpty {
                        HorizontalPlaylistRail(title: "Playlists", playlists: homePlaylists)
                    } else if isLoading {
                        HomeRailPlaceholder(title: "Playlists")
                    }

                    if !newest.isEmpty {
                        HorizontalAlbumRail(title: "New in your library", albums: newest)
                    } else if isLoading {
                        HomeRailPlaceholder(title: "New in your library")
                    }

                    if let error, recentEntries.isEmpty && newest.isEmpty {
                        if dynamicTypeSize.isAccessibilitySize {
                            ErrorStateView(message: error, expandsToFill: false) {
                                Task { await loadAll() }
                            }
                        } else {
                            ErrorStateView(message: error) { Task { await loadAll() } }
                        }
                    } else if !isLoading && recentEntries.isEmpty
                                && newest.isEmpty && dailyMixes.isEmpty {
                        if dynamicTypeSize.isAccessibilitySize {
                            EmptyStateView(title: "Your library is empty",
                                           message: "Add music to Navidrome and pull to refresh.")
                                .padding(.vertical, 24)
                        } else {
                            EmptyStateView(title: "Your library is empty",
                                           message: "Add music to Navidrome and pull to refresh.")
                                .frame(height: 220)
                        }
                    }
                }
                .padding(.top, 0)
                .padding(.bottom, 12)
                // Cross-fade content into reserved rails — avoid layout animation jumps.
                .animation(nil, value: isLoading)
                .animation(nil, value: recentEntries.count)
                .animation(nil, value: homePlaylists.count)
                .animation(nil, value: newest.count)
                .animation(nil, value: dailyMixes.count)
                .animation(nil, value: madeForYou.count)
            }
            .onChange(of: scrollToTopToken) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("home-top", anchor: .top)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            stickySettingsButton
        }
        .task(id: session.id) { await loadAll() }
        .refreshable { await loadAll() }
        .onChange(of: tabPopToRootTrigger) { _, trigger in
            guard trigger > 0 else { return }
            dismissHomeSheets()
        }
        .onChange(of: tabScrollToTopTrigger) { _, trigger in
            guard trigger > 0 else { return }
            dismissHomeSheets()
            scrollToTopToken += 1
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .dromeSession(session)
                .environmentObject(env)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                // Avoid the post-present content inset settle that nudges the page down.
                .presentationContentInteraction(.scrolls)
                .presentationBackground(DromeTheme.background)
        }
    }

    /// Fixed top-trailing Settings — does not scroll with Home content.
    private var stickySettingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DromeTheme.accent)
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.top, 0)
        .accessibilityIdentifier("drome.home.settings")
        .accessibilityLabel("Settings")
    }

    private var homeBrandRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("DROME")
                .font(.system(size: 30, weight: .heavy, design: .default))
                .foregroundStyle(DromeTheme.accent)
                .tracking(1.6)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            // Reserve the gear’s footprint so DROME lines up beside it at rest.
            Color.clear
                .frame(width: 48, height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, 2)
    }

    private var streamingOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(DromeTheme.accent)
            Text("Demo mode — streaming only. Wishlist and Spotify search stay off without a companion. Made for you still works from the library.")
                .font(.caption)
                .foregroundStyle(DromeTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DromeTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("drome.home.demo-banner")
    }

    private func dismissHomeSheets() {
        showSettings = false
    }

    private func loadAll() async {
        // Run mixes on this MainActor task (not only via `async let`) so the
        // first failure always lands in `mixesError` before the rail paints
        // its generic empty fallback.
        async let home: Void = loadHome()
        async let mfy: Void = loadMadeForYou(force: false)
        await loadMixes()
        await home
        await mfy
    }

    private func loadMadeForYou(force: Bool) async {
        let userKey = session.account.userKey
        if madeForYou.isEmpty {
            madeForYou = MadeForYouStore.cached(userKey: userKey)
        }
        if madeForYou.isEmpty { madeForYouLoading = true }
        defer { madeForYouLoading = false }
        guard MadeForYouPreferences.anyShelfEnabled else {
            madeForYou = []
            return
        }
        if force {
            madeForYou = await MadeForYouStore.regenerate(session: session)
        } else {
            madeForYou = await MadeForYouStore.refreshIfNeeded(session: session)
        }
        let urls = madeForYou.prefix(8).flatMap { $0.coverArtIds.prefix(4) }
            .compactMap { session.artworkURL(id: $0, size: 300) }
        ImageLoader.shared.prefetch(urls, limit: 24, priority: .userInitiated)
    }

    private func loadHome() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let userKey = session.account.userKey
        let db = AppEnvironment.shared.database

        // Paint Continue from disk first so the rail doesn’t wait on network.
        let recent = await Task.detached(priority: .utility) {
            (try? db.recentPlayEntries(userKey: userKey, limit: 40)) ?? []
        }.value
        recentEntries = recent

        do {
            async let n = session.client.albumList(type: .newest, size: 20)
            async let p = session.client.playlists()
            let (neu, lists) = try await (n, p)
            newest = neu
            let visible = lists.filter {
                !PlaylistOrderStore.isHidden($0.id, userKey: userKey)
            }
            homePlaylists = Self.rankedHomePlaylists(visible, recent: recent)
            warmHomeCovers(recent: recent, albums: neu, playlists: homePlaylists)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMixes() async {
        guard let client = session.wishlist else {
            dailyMixes = []
            mixesLoading = false
            mixesError = nil
            return
        }
        if dailyMixes.isEmpty { mixesLoading = true }
        defer { mixesLoading = false }
        if session.rotation.songIDs.isEmpty {
            await session.rotation.refresh()
        }
        // OOR only for display fetch — play history applies on the next day's
        // build, not by shrinking today's cached mixes after each listen.
        let exclude = Array(session.rotation.excludedIDs)
        do {
            let response = try await client.dailyMixes(
                excludeSongIDs: exclude, recencyHours: PlaybackPreferences.autoplayRecencyHours
            )
            guard !response.mixes.isEmpty else {
                if dailyMixes.isEmpty {
                    dailyMixes = []
                    dailyMixesDate = nil
                    mixesError = "No mixes yet"
                }
                return
            }
            let cleaned = Self.withoutOutOfRotation(
                response.mixes, excluded: session.rotation.excludedIDs)
            if dailyMixesDate == response.date,
               !dailyMixes.isEmpty,
               cleaned.count < dailyMixes.count {
                return
            }
            dailyMixes = cleaned
            dailyMixesDate = response.date
            mixesError = nil
            let mixCovers = cleaned.flatMap { $0.coverArtIds.prefix(4) }
            let mixURLs = mixCovers.compactMap { session.artworkURL(id: $0, size: 300) }
            ImageLoader.shared.prefetch(mixURLs, limit: 24, priority: .userInitiated)
        } catch is CancellationError {
            return
        } catch {
            // Always record the failure on an empty rail — including the first
            // `.task` load, not only Retry — so DailyMixRail doesn't fall back
            // to the generic "Couldn't load" copy.
            guard dailyMixes.isEmpty else { return }
            dailyMixes = []
            dailyMixesDate = nil
            mixesError = CompanionNetworkError.shortReason(for: error)
        }
    }

    /// Prefer recently played playlists, then frequently updated / larger ones.
    private static func rankedHomePlaylists(_ playlists: [Playlist],
                                            recent: [RecentPlayEntry]) -> [Playlist] {
        var recentIDs: [String] = []
        var seen = Set<String>()
        for entry in recent {
            if case .playlist(let id, _, _) = entry, seen.insert(id).inserted {
                recentIDs.append(id)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        var ordered: [Playlist] = recentIDs.compactMap { byID[$0] }
        let rest = playlists
            .filter { !seen.contains($0.id) && $0.name != RotationManager.playlistName }
            .sorted { a, b in
                let ac = a.songCount ?? 0
                let bc = b.songCount ?? 0
                if ac != bc { return ac > bc }
                return (a.changed ?? "") > (b.changed ?? "")
            }
        ordered.append(contentsOf: rest)
        return Array(ordered.prefix(20))
    }

    /// Start the covers that are about to be on screen before the rails mount.
    private func warmHomeCovers(recent: [RecentPlayEntry], albums: [Album], playlists: [Playlist]) {
        var urls: [URL] = []
        func add(_ id: String?) {
            guard let url = session.artworkURL(id: id, size: 300) else { return }
            urls.append(url)
        }
        for album in albums.prefix(14) {
            add(album.coverArt ?? album.id)
        }
        for playlist in playlists.prefix(14) {
            add(playlist.coverArt ?? playlist.id)
        }
        for entry in recent.prefix(14) {
            switch entry {
            case .song(let song):
                add(song.coverArt ?? song.albumId ?? song.id)
            case .album(_, _, let song), .playlist(_, _, let song), .mix(_, _, let song, _):
                add(song.coverArt ?? song.albumId ?? song.id)
            }
        }
        ImageLoader.shared.prefetch(urls, limit: 40, priority: .userInitiated)
    }

    /// Drop Out of Rotation tracks from mixes; keep the mix card even if short.
    private static func withoutOutOfRotation(_ mixes: [DailyMix],
                                             excluded: Set<String>) -> [DailyMix] {
        guard !excluded.isEmpty else { return mixes }
        return mixes.compactMap { mix in
            let songs = mix.songs.filter { !excluded.contains($0.id) }
            guard !songs.isEmpty else { return nil }
            var cleaned = mix
            cleaned.songs = songs
            return cleaned
        }
    }
}

/// Horizontal rail skeleton — same footprint as album/playlist/continue cards.
struct HomeRailPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(DromeTheme.headlineFont)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(DromeTheme.elevated2)
                                .aspectRatio(1, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DromeTheme.elevated2)
                                .frame(width: 100, height: 12)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DromeTheme.elevated2)
                                .frame(width: 80, height: 10)
                        }
                        .frame(width: 148, alignment: .topLeading)
                        .redacted(reason: .placeholder)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Songs the companion found that are not in Navidrome yet.
/// Get posts the Spotify link to the wishlist, which is what downloads them.
struct OutsidePicksRail: View {
    @EnvironmentObject private var session: AppSession

    @State private var picks: [OutsidePick] = []
    @State private var added: Set<String> = []
    @State private var failed: Set<String> = []
    @State private var isLoading = true
    @State private var didLoad = false

    var body: some View {
        Group {
            if isLoading && !didLoad {
                outsidePlaceholder
            } else if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get these")
                            .font(DromeTheme.headlineFont)
                        Text("Not in your library yet. From artists you already play.")
                            .font(.caption)
                            .foregroundStyle(DromeTheme.muted)
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(picks) { pick in
                            HStack(spacing: 12) {
                                RemoteImage(url: URL(string: pick.coverUrl ?? ""))
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pick.title)
                                        .font(DromeTheme.rowTitle)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(pick.artist)
                                        .font(.caption)
                                        .foregroundStyle(DromeTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    Task { await get(pick) }
                                } label: {
                                    Text(buttonTitle(for: pick))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DromeTheme.accent)
                                }
                                .buttonStyle(.plain)
                                .disabled(added.contains(pick.id))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .task(id: session.id) { await load() }
    }

    private var outsidePlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Get these")
                    .font(DromeTheme.headlineFont)
                Text("Not in your library yet. From artists you already play.")
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
            }
            .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DromeTheme.elevated2)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DromeTheme.elevated2)
                                .frame(width: 140, height: 12)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DromeTheme.elevated2)
                                .frame(width: 90, height: 10)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityHidden(true)
    }

    private func buttonTitle(for pick: OutsidePick) -> String {
        if added.contains(pick.id) { return "Added" }
        if failed.contains(pick.id) { return "Retry" }
        return "Get"
    }

    private func load() async {
        defer {
            isLoading = false
            didLoad = true
        }
        guard let client = session.wishlist else {
            picks = []
            return
        }
        isLoading = true
        if session.ratings.memory.topPlayedArtists(limit: 1).isEmpty {
            await session.ratings.rebuildMemory()
        }
        let artists = session.ratings.memory.topPlayedArtists(limit: 6)
        picks = (try? await client.outsidePicks(artists: artists)) ?? []
    }

    private func get(_ pick: OutsidePick) async {
        guard let client = session.wishlist else { return }
        let link = pick.spotifyUrl.isEmpty
            ? "https://open.spotify.com/track/\(pick.spotifyId)"
            : pick.spotifyUrl
        do {
            _ = try await client.add(spotifyLink: link)
            added.insert(pick.id)
            failed.remove(pick.id)
        } catch {
            failed.insert(pick.id)
        }
    }
}
