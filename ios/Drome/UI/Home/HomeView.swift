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
    @State private var isLoading = false
    @State private var error: String?
    @State private var showSettings = false
    @State private var scrollToTopToken = 0

    private var hasCompanion: Bool { session.wishlist != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 0).id("home-top")

                    // Compact brand — Vibe Tuner is the hero immediately under it.
                    homeBrandRow

                    VibeTuner()

                    if hasCompanion {
                        DailyMixRail(
                            mixes: dailyMixes,
                            isLoading: mixesLoading,
                            loadError: mixesError,
                            onRetry: { Task { await loadMixes() } }
                        )
                    }

                    if !recentEntries.isEmpty {
                        HorizontalRecentRail(
                            title: "Continue",
                            entries: recentEntries,
                            dailyMixes: dailyMixes)
                    }
                    if !homePlaylists.isEmpty {
                        HorizontalPlaylistRail(title: "Playlists", playlists: homePlaylists)
                    }
                    if !newest.isEmpty {
                        HorizontalAlbumRail(title: "New in your library", albums: newest)
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

    private func dismissHomeSheets() {
        showSettings = false
    }

    private func loadAll() async {
        // Run mixes on this MainActor task (not only via `async let`) so the
        // first failure always lands in `mixesError` before the rail paints
        // its generic empty fallback.
        async let home: Void = loadHome()
        await loadMixes()
        await home
    }

    private func loadHome() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let userKey = session.account.userKey
            let db = AppEnvironment.shared.database
            async let recentTask = Task.detached(priority: .utility) {
                (try? db.recentPlayEntries(userKey: userKey, limit: 40)) ?? []
            }.value
            async let n = session.client.albumList(type: .newest, size: 20)
            async let p = session.client.playlists()
            let (recent, neu, lists) = try await (recentTask, n, p)
            recentEntries = recent
            newest = neu
            let visible = lists.filter {
                !PlaylistOrderStore.isHidden($0.id, userKey: userKey)
            }
            homePlaylists = Self.rankedHomePlaylists(visible, recent: recent)
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
