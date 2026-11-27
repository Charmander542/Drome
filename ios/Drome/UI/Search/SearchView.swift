import SwiftUI
import UIKit

struct SearchView: View {
    private enum Source: String, CaseIterable {
        case library = "Library"
        case spotify = "Spotify"
        case podcasts = "Podcasts"

        init(_ mode: AppNavigationRouter.SearchMode) {
            switch mode {
            case .library: self = .library
            case .spotify: self = .spotify
            case .podcasts: self = .podcasts
            }
        }

        var asMode: AppNavigationRouter.SearchMode {
            switch self {
            case .library: return .library
            case .spotify: return .spotify
            case .podcasts: return .podcasts
            }
        }

        /// Spotify search needs the wishlist companion — hide it in streaming-only mode.
        static func available(hasCompanion: Bool) -> [Source] {
            hasCompanion ? allCases : [.library, .podcasts]
        }
    }

    private var hasCompanion: Bool { session.wishlist != nil }

    @Environment(AppNavigationRouter.self) private var router
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var podcastManager: PodcastManager
    @EnvironmentObject private var podcastPlayer: PodcastPlayer
    @Environment(\.songNavigator) private var songNavigator
    @Environment(\.tabPopToRootTrigger) private var tabPopToRootTrigger
    @Environment(\.tabScrollToTopTrigger) private var tabScrollToTopTrigger
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var source: Source = .library
    @State private var resultFilter: AppNavigationRouter.SearchResultFilter = .all
    @State private var query = ""
    @State private var isSearching = false
    @State private var hasCompletedSearch = false
    @State private var hits: [SearchHit] = []
    @State private var spotifyHits: [SpotifySearchHit] = []
    @State private var podcastHits: [PodcastDiscoverResult] = []
    @State private var podcastFeedCandidate: PodcastShow?
    @State private var subscribingFeedURLs: Set<String> = []
    @State private var addingSpotifyIDs: Set<String> = []
    @State private var addedSpotifyIDs: Set<String> = []
    @State private var error: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSearchPresented = false
    /// Browse landing (Aura/Apple Music) vs focused text-search mode.
    @State private var isBrowseMode = true
    /// Block scroll-to-dismiss while browse→results layout settles (that offset
    /// jump was killing the keyboard the instant it appeared).
    @State private var ignoreScrollKeyboardDismissUntil: Date = .distantPast
    @State private var recentItems: [RecentSearchItem] = []
    @State private var matchedSongs: [String: Song] = [:]
    @State private var matchedAlbums: [String: Album] = [:]
    @State private var expandedSections: Set<String> = []
    /// Cached getPlaylists() — Subsonic has no playlist search API.
    @State private var playlistCache: [Playlist] = []

    /// Keep the prompt stable — swapping it on mode change rebuilds the
    /// system search field and makes typed text blink out.
    private var searchPrompt: String { "Artists, songs, albums, playlists…" }

    /// Gap between filter chrome and the first list section (“Recently Searched”).
    private static let resultsTopSpacing: CGFloat = 16

    private var filteredHits: [SearchHit] {
        switch resultFilter {
        case .all:
            return hits
        case .songs:
            return hits.filter { $0.kind == .song }
        case .albums:
            return hits.filter { $0.kind == .album }
        case .artists:
            return hits.filter { $0.kind == .artist }
        case .playlists:
            return hits.filter { $0.kind == .playlist }
        }
    }

    private var filteredRecentItems: [RecentSearchItem] {
        switch resultFilter {
        case .all:
            return recentItems
        case .songs:
            return recentItems.filter { $0.kind == .song }
        case .albums:
            return recentItems.filter { $0.kind == .album }
        case .artists:
            return recentItems.filter { $0.kind == .artist }
        case .playlists:
            return recentItems.filter { $0.kind == .playlist }
        }
    }

    var body: some View {
        ZStack {
            // Genre grid stays mounted (eager tiles) but hidden while results
            // cover it — otherwise a keyboard-safe-area shrink of the cover
            // flash-reveals Browse Genres under the dark blocker.
            SearchBrowseLanding()
                .opacity(isBrowseMode ? 1 : 0)
                .allowsHitTesting(isBrowseMode)
                .accessibilityHidden(!isBrowseMode)
                .zIndex(0)

            // VStack (not `.safeAreaInset`) keeps filter chrome at intrinsic
            // height above the list. `searchable` + top safeAreaInset left a
            // ~180pt dead band above “Recently Searched” on first keyboard.
            VStack(spacing: 0) {
                searchControls
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Solid fill behind list rows so empty regions stay opaque.
            .background(DromeTheme.background)
            // Don’t let the keyboard lift this cover — the system inset was
            // sliding the dark blocker up and exposing categories beneath.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .opacity(isBrowseMode ? 0 : 1)
            .allowsHitTesting(!isBrowseMode)
            .accessibilityHidden(isBrowseMode)
            .zIndex(1)
        }
        // `.all` includes keyboard so any gap under the cover stays Drome black.
        .background(DromeTheme.background.ignoresSafeArea(.all))
        .transaction { $0.animation = nil }
        // Keep “Search” pinned — system `.searchable` hides the nav title on
        // focus; a principal toolbar label stays visible either way.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Search")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .toolbarBackground(DromeTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchPrompt)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .background(SearchChromeOpaqueFix())
        .onChange(of: query) { _, newValue in
            expandedSections = []
            scheduleSearch(newValue)
            // Field clear (mini ✕): stay in text-search with the keyboard up.
            // Only Cancel / the far-right dismiss returns to genre browse.
            let newTrim = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isBrowseMode, newTrim.isEmpty, !isSearchPresented {
                ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
                isSearchPresented = true
            }
        }
        .onChange(of: isSearchPresented) { _, presented in
            if presented {
                // Results List mounting shifts contentOffset — ignore that.
                ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
                if isBrowseMode {
                    // Yield so the search field can finish focusing before we
                    // swap browse → results (avoids a second chrome animation).
                    Task { @MainActor in
                        await Task.yield()
                        guard isSearchPresented, isBrowseMode else { return }
                        ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
                        enterTextSearch(
                            mode: source.asMode,
                            filter: resultFilter,
                            focus: false)
                    }
                }
                return
            }
            // Cancel / far-right ✕ → genre browse landing.
            // Mini field clear keeps isSearchPresented true and does not hit this.
            if !isBrowseMode {
                returnToBrowse()
            }
        }
        .onChange(of: source) { _, newValue in
            // Don’t wipe prior hits — swapping modes used to blank the list
            // (and blink the search field) before the next response landed.
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                error = nil
                if newValue != .podcasts {
                    podcastFeedCandidate = nil
                }
                if newValue != .library {
                    resultFilter = .all
                }
            }
            if !isBrowseMode {
                scheduleSearch(query)
                // Segmented control steals focus from `.searchable`; put it back
                // so the keyboard (and chrome) don’t bounce on every mode tap.
                if isSearchPresented {
                    ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
                    DispatchQueue.main.async {
                        guard !isBrowseMode else { return }
                        isSearchPresented = true
                    }
                }
            }
        }
        .onChange(of: tabPopToRootTrigger) { _, trigger in
            guard trigger > 0 else { return }
            returnToBrowse()
        }
        .onChange(of: tabScrollToTopTrigger) { _, trigger in
            guard trigger > 0 else { return }
            enterTextSearch(mode: source.asMode, filter: resultFilter, focus: true)
        }
        .onChange(of: router.pendingSearchIntent) { _, intent in
            consumePendingSearchIntent(intent)
        }
        .onAppear {
            consumePendingSearchIntent(router.pendingSearchIntent)
        }
        .task {
            let loaded = await Task.detached(priority: .utility) {
                RecentSearchesStore.load()
            }.value
            recentItems = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .dromeFocusCarPlaySearch)) { _ in
            enterTextSearch(mode: .library, filter: .all, focus: true)
        }
        // Custom scroll-dismiss only — system `.immediately` fires on List layout
        // and was collapsing the keyboard the moment search focused.
        .scrollDismissesKeyboard(.never)
    }

    /// Hide the keyboard on scroll but keep the searchable field (query + ✕)
    /// mounted — collapsing `isSearchPresented` was swapping to the bare
    /// “Search” title and dropping the typed text from the chrome.
    private func dismissSearchKeyboardOnScroll() {
        guard !isBrowseMode else { return }
        guard Date() >= ignoreScrollKeyboardDismissUntil else { return }
        dismissKeyboard()
    }

    private func enterTextSearch(
        mode: AppNavigationRouter.SearchMode,
        filter: AppNavigationRouter.SearchResultFilter,
        focus: Bool
    ) {
        source = Source(mode)
        resultFilter = mode == .library ? filter : .all
        ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
        // Instant content swap — let the system search field / keyboard animate alone.
        setBrowseMode(false)
        if focus, !isSearchPresented {
            DispatchQueue.main.async {
                ignoreScrollKeyboardDismissUntil = Date().addingTimeInterval(0.75)
                isSearchPresented = true
            }
        }
    }

    private func returnToBrowse() {
        guard !isBrowseMode || isSearchPresented || !query.isEmpty else { return }
        debounceTask?.cancel()
        // Reveal genres first (already painted underneath), then drop the
        // keyboard — avoids a black void while the field/keyboard animate out.
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            isBrowseMode = true
            query = ""
            isSearching = false
            hasCompletedSearch = false
            hits = []
            spotifyHits = []
            podcastHits = []
            podcastFeedCandidate = nil
            error = nil
            matchedSongs = [:]
            matchedAlbums = [:]
            expandedSections = []
            source = .library
            resultFilter = .all
        }
        isSearchPresented = false
    }

    private func setBrowseMode(_ browse: Bool) {
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            isBrowseMode = browse
        }
    }

    private func resetToDefault() {
        returnToBrowse()
    }

    /// Apply a cross-tab handoff once. Focus is one-shot so returning to Search
    /// later does not re-open the keyboard.
    private func consumePendingSearchIntent(_ intent: AppNavigationRouter.SearchIntent?) {
        guard let intent else { return }
        enterTextSearch(
            mode: intent.mode,
            filter: intent.mode == .library ? intent.filter : .all,
            focus: intent.shouldFocus
        )
        // Clear after apply so a later appear / tab return does not re-focus.
        router.pendingSearchIntent = nil
    }

    /// Source + type chips while in text-search mode.
    /// Library keeps All/Songs/… chips; Spotify & Podcasts drop that row so
    /// results sit directly under the source segmented control.
    private var searchControls: some View {
        let showChips = source == .library
        return VStack(alignment: .leading, spacing: showChips ? 8 : 0) {
            sourcePicker
            if showChips {
                resultFilterChips
                    .frame(height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(DromeTheme.background)
        .transaction { $0.animation = nil }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $source) {
            ForEach(Source.available(hasCompanion: hasCompanion), id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .onAppear { clampSourceToCompanion() }
        .onChange(of: hasCompanion) { _, _ in clampSourceToCompanion() }
    }

    private func clampSourceToCompanion() {
        if !hasCompanion, source == .spotify {
            source = .library
        }
    }

    /// Horizontally scrolling chips so AX5 labels stay readable without wrapping.
    private var resultFilterChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppNavigationRouter.SearchResultFilter.allCases) { filter in
                        let selected = resultFilter == filter
                        Button {
                            // Re-tap clears back to All (All stays All).
                            resultFilter = selected && filter != .all ? .all : filter
                        } label: {
                            Text(filter.title)
                                .font(.subheadline.weight(selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? DromeTheme.accent : DromeTheme.elevated2,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .id(filter)
                        .accessibilityLabel(filter.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint(
                            selected && filter != .all
                                ? "Double tap to show all result types"
                                : "Filters search results"
                        )
                        .accessibilityIdentifier(filter.accessibilityIdentifier)
                    }
                }
            }
            .onAppear {
                scrollFilterChip(proxy, to: resultFilter)
            }
            .onChange(of: resultFilter) { _, filter in
                scrollFilterChip(proxy, to: filter)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result type filter")
    }

    private func scrollFilterChip(
        _ proxy: ScrollViewProxy,
        to filter: AppNavigationRouter.SearchResultFilter
    ) {
        var transaction = Transaction()
        transaction.animation = .easeOut(duration: 0.2)
        withTransaction(transaction) {
            proxy.scrollTo(filter, anchor: .center)
        }
    }

    private var libraryEmptyTitle: String {
        switch resultFilter {
        case .all: return "Search your library"
        case .songs: return "Search songs"
        case .albums: return "Search albums"
        case .artists: return "Search artists"
        case .playlists: return "Search playlists"
        }
    }

    private var libraryEmptyMessage: String {
        switch resultFilter {
        case .all:
            return "Find artists, albums, songs, and playlists. Recent picks show up here."
        case .songs:
            return "Try a song title or artist."
        case .albums:
            return "Try an album or artist name."
        case .artists:
            return "Try an artist name."
        case .playlists:
            return "Try a playlist name."
        }
    }

    private var collapsedSectionLimit: Int { 5 }

    private var artistsHits: [SearchHit] { filteredHits.filter { $0.kind == .artist } }
    private var albumsHits: [SearchHit] { filteredHits.filter { $0.kind == .album } }
    private var songsHits: [SearchHit] { filteredHits.filter { $0.kind == .song } }
    private var playlistsHits: [SearchHit] { filteredHits.filter { $0.kind == .playlist } }
    private var topHit: SearchHit? {
        guard resultFilter == .all else { return nil }
        return filteredHits.first
    }

    /// Keep all three result trees mounted — switching source only flips
    /// opacity so “Recently Searched” / lists don’t remount and flicker.
    /// Top-aligned equal frames stop panes of different heights from recentering.
    private var results: some View {
        ZStack(alignment: .top) {
            libraryResults
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(source == .library ? 1 : 0)
                .allowsHitTesting(source == .library)
                .accessibilityHidden(source != .library)
            spotifyResults
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(source == .spotify ? 1 : 0)
                .allowsHitTesting(source == .spotify)
                .accessibilityHidden(source != .spotify)
            podcastResults
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(source == .podcasts ? 1 : 0)
                .allowsHitTesting(source == .podcasts)
                .accessibilityHidden(source != .podcasts)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private var libraryResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleHits = filteredHits
        let visibleRecents = filteredRecentItems
        let libraryEmpty = visibleHits.isEmpty
        List {
            if trimmed.isEmpty {
                if visibleRecents.isEmpty {
                    Section {
                        ContentUnavailableView(
                            libraryEmptyTitle,
                            systemImage: "magnifyingglass",
                            description: Text(libraryEmptyMessage)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 48, leading: 16, bottom: 48, trailing: 16))
                    }
                } else {
                    recentSearchesSection(items: visibleRecents)
                }
            } else if let error, libraryEmpty {
                Section {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(DromeTheme.background)
                }
            } else if libraryEmpty && hasCompletedSearch && !isSearching {
                Section {
                    ContentUnavailableView.search(text: trimmed)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !visibleHits.isEmpty {
                if resultFilter == .all {
                    groupedLibraryResults
                } else {
                    Section {
                        ForEach(visibleHits) { hit in
                            hitRow(hit)
                                .listRowBackground(DromeTheme.background)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(6)
        .environment(\.defaultMinListHeaderHeight, 0)
        .contentMargins(.top, Self.resultsTopSpacing, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.never)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { oldY, newY in
            // Ignore tiny layout settles; only real user scrolls dismiss the keyboard.
            guard abs(newY - oldY) > 8 else { return }
            dismissSearchKeyboardOnScroll()
        }
        .overlay {
            if !trimmed.isEmpty && libraryEmpty && isSearching {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(DromeTheme.muted)
                    Text("Searching…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DromeTheme.muted)
                }
            }
        }
        .overlay(alignment: .top) {
            if isSearching && !libraryEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DromeTheme.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
        }
        .animation(nil, value: query)
        .animation(nil, value: resultFilter)
        .animation(nil, value: source)
        .animation(nil, value: recentItems.count)
    }

    @ViewBuilder
    private var spotifyResults: some View {
        if session.wishlist == nil {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollableEmptyState {
                        EmptyStateView(
                            title: "Wishlist not configured",
                            systemImage: "heart",
                            message: "Set your companion server URL in Settings to search Spotify and add tracks to your wishlist.")
                    }
                } else {
                    EmptyStateView(
                        title: "Wishlist not configured",
                        systemImage: "heart",
                        message: "Set your companion server URL in Settings to search Spotify and add tracks to your wishlist.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let ax = dynamicTypeSize.isAccessibilitySize
            List {
                if trimmed.isEmpty {
                    if ax {
                        Section {
                            EmptyStateView(
                                title: "Search Spotify",
                                systemImage: "magnifyingglass",
                                message: "Find tracks to add to your wishlist.")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 48, trailing: 16))
                        }
                    } else {
                        Section { EmptyView() }
                    }
                } else if let error, spotifyHits.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(DromeTheme.muted)
                            Button("Retry") {
                                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else { return }
                                Task { await runSpotifySearch(q) }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DromeTheme.accent)
                        }
                        .listRowBackground(DromeTheme.background)
                    }
                } else if spotifyHits.isEmpty && hasCompletedSearch && !isSearching {
                    Section {
                        Text("No results")
                            .font(.subheadline)
                            .foregroundStyle(DromeTheme.muted)
                            .listRowBackground(DromeTheme.background)
                    }
                } else {
                    ForEach(spotifyHits) { hit in
                        Group {
                            if hit.kind == "track", let song = matchedSongs[hit.spotifyId] {
                                spotifyRow(hit)
                                    .songSwipeActions(for: song)
                            } else {
                                spotifyRow(hit)
                            }
                        }
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(8)
            .contentMargins(.top, Self.resultsTopSpacing, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.never)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { oldY, newY in
                guard abs(newY - oldY) > 8 else { return }
                dismissSearchKeyboardOnScroll()
            }
            .overlay {
                if trimmed.isEmpty && !ax {
                    EmptyStateView(
                        title: "Search Spotify",
                        systemImage: "magnifyingglass",
                        message: "Find tracks to add to your wishlist.")
                    .allowsHitTesting(false)
                } else if spotifyHits.isEmpty && isSearching {
                    ProgressView()
                        .tint(DromeTheme.muted)
                }
            }
            .animation(nil, value: query)
            .animation(nil, value: source)
        }
    }

    @ViewBuilder
    private var podcastResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ax = dynamicTypeSize.isAccessibilitySize
        List {
            if let podcastFeedCandidate {
                Section {
                    podcastFeedURLRow(podcastFeedCandidate)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                } header: {
                    Text("Feed URL")
                }
            }

            if trimmed.isEmpty {
                if ax {
                    Section {
                        EmptyStateView(
                            title: "Find podcasts",
                            systemImage: "headphones",
                            message: "Search by show name, or paste an RSS feed URL to subscribe.")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 48, trailing: 16))
                    }
                } else {
                    Section { EmptyView() }
                }
            } else if let error, podcastHits.isEmpty, podcastFeedCandidate == nil {
                Section {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(DromeTheme.background)
                }
            } else if podcastHits.isEmpty && hasCompletedSearch && !isSearching && podcastFeedCandidate == nil {
                Section {
                    Text("No results")
                        .font(.subheadline)
                        .foregroundStyle(DromeTheme.muted)
                        .listRowBackground(DromeTheme.background)
                }
            } else {
                ForEach(podcastHits) { hit in
                    podcastNavigatingRow(hit)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(8)
        .contentMargins(.top, Self.resultsTopSpacing, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.never)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { oldY, newY in
            guard abs(newY - oldY) > 8 else { return }
            dismissSearchKeyboardOnScroll()
        }
        .overlay {
            if trimmed.isEmpty && !ax {
                EmptyStateView(
                    title: "Find podcasts",
                    systemImage: "headphones",
                    message: "Search by show name, or paste an RSS feed URL to subscribe.")
                .allowsHitTesting(false)
            } else if podcastHits.isEmpty && podcastFeedCandidate == nil && isSearching {
                ProgressView()
                    .tint(DromeTheme.muted)
            }
        }
        .animation(nil, value: query)
        .animation(nil, value: source)
    }

    private func podcastNavigatingRow(_ hit: PodcastDiscoverResult) -> some View {
        NavigationLink {
            PodcastShowView(show: hit.show)
        } label: {
            podcastRowContent(hit.show, feedURLHint: false)
        }
        .buttonStyle(.plain)
        // Subscribe owns the trailing chrome — hide the default disclosure chevron.
        .navigationLinkIndicatorVisibility(.hidden)
        .overlay(alignment: .trailing) {
            podcastSubscribeButton(feedURL: hit.show.feedURL)
                .padding(.trailing, 4)
        }
    }

    private func podcastRowContent(_ show: PodcastShow, feedURLHint: Bool) -> some View {
        HStack(spacing: 12) {
            RemoteImage(
                url: show.imageURL,
                placeholderSymbol: feedURLHint ? "link" : "headphones",
                holdImageWhileLoading: true)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title.isEmpty ? "Podcast feed" : show.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(feedURLHint ? show.feedURL : podcastSubtitle(show))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }

            // Room for the 44pt Subscribe control without crowding the title.
            Spacer(minLength: 52)
        }
    }

    private func podcastSubscribeButton(feedURL: String) -> some View {
        let subscribed = podcastManager.isSubscribed(feedURL: feedURL)
        return Group {
            if subscribed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DromeTheme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Subscribed")
            } else {
                Button {
                    Task { await subscribeToPodcast(feedURL: feedURL) }
                } label: {
                    Group {
                        if subscribingFeedURLs.contains(feedURL) {
                            ProgressView()
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(DromeTheme.accent)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(subscribingFeedURLs.contains(feedURL))
                .accessibilityLabel("Subscribe")
            }
        }
    }

    private func podcastFeedURLRow(_ show: PodcastShow) -> some View {
        NavigationLink {
            PodcastShowView(show: show)
        } label: {
            podcastRowContent(show, feedURLHint: true)
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .overlay(alignment: .trailing) {
            podcastSubscribeButton(feedURL: show.feedURL)
                .padding(.trailing, 4)
        }
    }

    private func podcastSubtitle(_ show: PodcastShow) -> String {
        [show.author, show.category].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func subscribeToPodcast(feedURL: String) async {
        subscribingFeedURLs.insert(feedURL)
        defer { subscribingFeedURLs.remove(feedURL) }
        do {
            try await podcastManager.subscribe(to: feedURL)
            if let url = podcastHits.first(where: { $0.show.feedURL == feedURL })?.show.imageURL
                ?? podcastFeedCandidate?.imageURL {
                ImageLoader.shared.prefetch([url], limit: 1)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func recentSearchesSection(items: [RecentSearchItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    recentItemRow(item)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                RecentSearchesStore.remove(item)
                                recentItems = RecentSearchesStore.load()
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recently Searched")
                    Spacer()
                    Button("Clear") {
                        RecentSearchesStore.clear()
                        recentItems = []
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
                    .textCase(nil)
                }
                .padding(.top, 0)
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private var groupedLibraryResults: some View {
        if let top = topHit {
            Section {
                hitRow(top)
                    .listRowBackground(DromeTheme.background)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("Top result")
            }
        }

        resultSection(title: "Artists", key: "artists", hits: artistsHits, excludingTop: true)
        resultSection(title: "Albums", key: "albums", hits: albumsHits, excludingTop: true)
        resultSection(title: "Songs", key: "songs", hits: songsHits, excludingTop: true)
        resultSection(title: "Playlists", key: "playlists", hits: playlistsHits, excludingTop: true)
    }

    @ViewBuilder
    private func resultSection(
        title: String,
        key: String,
        hits: [SearchHit],
        excludingTop: Bool
    ) -> some View {
        let topID = excludingTop ? topHit?.id : nil
        let rows = hits.filter { $0.id != topID }
        if !rows.isEmpty {
            let expanded = expandedSections.contains(key)
            let visible = expanded ? rows : Array(rows.prefix(collapsedSectionLimit))
            Section {
                ForEach(visible) { hit in
                    hitRow(hit)
                        .listRowBackground(DromeTheme.background)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                if rows.count > collapsedSectionLimit {
                    Button {
                        if expanded {
                            expandedSections.remove(key)
                        } else {
                            expandedSections.insert(key)
                        }
                    } label: {
                        Text(expanded ? "Show less" : "See all \(rows.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DromeTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(DromeTheme.background)
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func recentItemRow(_ item: RecentSearchItem) -> some View {
        switch item.kind {
        case .artist:
            NavigationLink {
                ArtistDetailView(
                    artistID: item.entityId,
                    placeholderName: item.title)
            } label: {
                recentItemLabel(item, shape: .circle)
            }
            .simultaneousGesture(TapGesture().onEnded {
                bumpRecent(item)
            })

        case .album:
            AlbumMediaRow(
                album: item.decodedAlbum() ?? Album(
                    id: item.entityId, name: item.title,
                    artist: item.subtitle.isEmpty ? nil : item.subtitle,
                    artistId: nil, coverArt: item.coverArt,
                    songCount: nil, duration: nil, playCount: nil,
                    created: nil, year: nil, genre: nil, userRating: nil),
                trailing: AnyView(
                    Text("ALBUM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DromeTheme.muted)
                )
            ) {
                dismissKeyboard()
                bumpRecent(item)
            }

        case .song:
            Group {
                if let song = item.decodedSong() {
                    SongRow(
                        song: song,
                        showAlbum: true,
                        trailing: AnyView(
                            Text("SONG")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DromeTheme.muted)
                        ),
                        lightweight: true
                    ) {
                        playRecentSongItem(item, song: song)
                    }
                } else {
                    recentItemLabel(item, shape: .rounded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            playRecentSongItem(item, song: nil)
                        })
                }
            }

        case .playlist:
            NavigationLink {
                PlaylistDetailView(
                    playlistID: item.entityId,
                    placeholder: item.decodedPlaylist() ?? Playlist(
                        id: item.entityId,
                        name: item.title,
                        coverArt: item.coverArt))
            } label: {
                recentItemLabel(item, shape: .rounded)
            }
            .simultaneousGesture(TapGesture().onEnded {
                bumpRecent(item)
            })
        }
    }

    private func recentItemLabel(_ item: RecentSearchItem, shape: CoverShape) -> some View {
        HStack(spacing: 12) {
            RemoteImage(
                url: session.artworkURL(id: item.coverArt ?? item.entityId, size: 120),
                placeholderSymbol: recentPlaceholder(for: item.kind))
                .frame(width: 44, height: 44)
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(item.kind.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(DromeTheme.muted)
        }
    }

    private func recentPlaceholder(for kind: RecentSearchItem.Kind) -> String {
        switch kind {
        case .artist: return "person.crop.circle"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .playlist: return "music.note.list"
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func playRecentSongItem(_ item: RecentSearchItem, song: Song?) {
        dismissKeyboard()
        bumpRecent(item)
        if let song {
            session.player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Search", kind: .search))
            NowPlayingPresenter.open()
            return
        }
        Task { await playRecentSong(id: item.entityId) }
    }

    private func bumpRecent(_ item: RecentSearchItem) {
        RecentSearchesStore.remember(item)
        recentItems = RecentSearchesStore.load()
    }

    private func playRecentSong(id: String) async {
        do {
            let song = try await session.client.song(id: id)
            RecentSearchesStore.remember(song: song)
            recentItems = RecentSearchesStore.load()
            session.player.play([song], startAt: 0,
                        context: PlaybackContext(label: "Search", kind: .search))
            NowPlayingPresenter.open()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func spotifyRow(_ hit: SpotifySearchHit) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: hit.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(white: 0.16)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: hit.kind == "artist" ? 22 : 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(DromeTheme.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(spotifySubtitle(hit))
                    .font(.caption)
                    .foregroundStyle(DromeTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            spotifyTrailing(hit)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if hit.kind == "album", let album = matchedAlbums[hit.spotifyId] {
                dismissKeyboard()
                songNavigator?.viewAlbum(album)
            } else if let song = matchedSongs[hit.spotifyId] {
                dismissKeyboard()
                session.player.play([song], startAt: 0,
                            context: PlaybackContext(label: "Library", kind: .search))
                NowPlayingPresenter.open()
            }
        })
    }

    private func spotifySubtitle(_ hit: SpotifySearchHit) -> String {
        switch hit.kind {
        case "album":
            return [hit.artist, "Album"].filter { !$0.isEmpty }.joined(separator: " · ")
        case "playlist":
            let count = hit.trackCount.map { "\($0) tracks" }
            return [hit.artist, count].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "artist":
            return "Artist"
        default:
            return [hit.artist, hit.album].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private func spotifyTrailing(_ hit: SpotifySearchHit) -> some View {
        switch hit.kind {
        case "playlist":
            Button {
                if let url = URL(string: hit.spotifyUrl) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DromeTheme.accent)
            }
            .buttonStyle(.plain)
        case "album":
            if let album = matchedAlbums[hit.spotifyId] {
                Button {
                    LibraryPlayback.play(album: album, session: session)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DromeTheme.accent)
                }
                .buttonStyle(.plain)
            } else {
                wishlistAddButton(hit)
            }
        case "artist":
            EmptyView()
        default:
            if let song = matchedSongs[hit.spotifyId] {
                Button {
                    session.player.play([song], startAt: 0,
                                context: PlaybackContext(label: "Library", kind: .search))
                    NowPlayingPresenter.open()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DromeTheme.accent)
                }
                .buttonStyle(.plain)
            } else {
                wishlistAddButton(hit)
            }
        }
    }

    private func wishlistAddButton(_ hit: SpotifySearchHit) -> some View {
        Button {
            Task { await addToWishlist(hit) }
        } label: {
            if addingSpotifyIDs.contains(hit.spotifyId) {
                ProgressView()
            } else if addedSpotifyIDs.contains(hit.spotifyId) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DromeTheme.accent)
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DromeTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(addingSpotifyIDs.contains(hit.spotifyId)
                  || addedSpotifyIDs.contains(hit.spotifyId))
        .accessibilityLabel("Add to Wishlist")
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
                .simultaneousGesture(TapGesture().onEnded {
                    rememberHit(hit)
                })
            }
        case .album:
            if let album = hit.album {
                AlbumMediaRow(
                    album: album,
                    trailing: AnyView(
                        Text("ALBUM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                    )
                ) {
                    dismissKeyboard()
                    rememberHit(hit)
                }
            }
        case .song:
            if let song = hit.song {
                SongRow(
                    song: song,
                    showAlbum: true,
                    trailing: AnyView(
                        Text("SONG")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DromeTheme.muted)
                    ),
                    lightweight: true
                ) {
                    dismissKeyboard()
                    rememberHit(hit)
                    let songs = filteredHits.compactMap(\.song)
                    let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                    session.player.play(songs.isEmpty ? [song] : songs, startAt: start,
                                context: PlaybackContext(label: "Search", kind: .search))
                    NowPlayingPresenter.open()
                }
            }
        case .playlist:
            if let playlist = hit.playlist {
                NavigationLink {
                    PlaylistDetailView(playlistID: playlist.id, placeholder: playlist)
                } label: {
                    hitLabel(hit, shape: .rounded)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    rememberHit(hit)
                })
            }
        }
    }

    private func rememberHit(_ hit: SearchHit) {
        RecentSearchesStore.remember(hit: hit)
        recentItems = RecentSearchesStore.load()
    }

    private enum CoverShape { case circle, rounded }

    private func hitLabel(_ hit: SearchHit, shape: CoverShape) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: session.artworkURL(id: hit.coverArt, size: 120),
                        placeholderSymbol: placeholder(for: hit.kind))
                .frame(width: 44, height: 44)
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(DromeTheme.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if hit.kind == .song, let song = hit.song {
                        // Don't remount on every ratings.revision — that made
                        // search feel like a hang when ingest published.
                        RatingBadge(rating: session.ratings.rating(for: song))
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
        case .playlist: return "PLAYLIST"
        }
    }

    private func placeholder(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .artist: return "person.crop.circle"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .playlist: return "music.note.list"
        }
    }

    private func scheduleSearch(_ raw: String) {
        debounceTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            spotifyHits = []
            podcastHits = []
            podcastFeedCandidate = nil
            error = nil
            isSearching = false
            hasCompletedSearch = false
            NotificationCenter.default.post(
                name: .dromeCarPlaySearchQuery,
                object: nil,
                userInfo: ["query": ""])
            return
        }
        error = nil
        isSearching = true
        hasCompletedSearch = false
        debounceTask = Task {
            // Local index first so the first character isn't waiting on the network.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: .dromeCarPlaySearchQuery,
                object: nil,
                userInfo: ["query": trimmed])
            switch source {
            case .library:
                podcastHits = []
                await runLocalSearch(trimmed)
                guard !Task.isCancelled else { return }
                guard trimmed.count >= 2 else {
                    isSearching = false
                    hasCompletedSearch = true
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                async let music: Void = runNetworkSearch(trimmed)
                async let podcasts: Void = runLibraryPodcastSearch(trimmed)
                _ = await (music, podcasts)
            case .spotify:
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                await runSpotifySearch(trimmed)
            case .podcasts:
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await runPodcastSearch(trimmed)
            }
        }
    }

    /// Side-channel podcast hits while searching Library — failures stay quiet
    /// so a flaky iTunes lookup never blanks music results.
    private func runLibraryPodcastSearch(_ q: String) async {
        guard PodcastManager.httpURL(from: q) == nil else { return }
        do {
            let results = try await PodcastManager.searchPodcasts(query: q, limit: 8)
            guard !Task.isCancelled else { return }
            podcastHits = results
            ImageLoader.shared.prefetch(results.compactMap(\.show.imageURL), limit: 8, priority: .userInitiated)
        } catch {
            guard !Task.isCancelled else { return }
            podcastHits = []
        }
    }

    private func runPodcastSearch(_ q: String) async {
        isSearching = true
        error = nil
        defer {
            isSearching = false
            hasCompletedSearch = true
        }

        // Paste path: treat an http(s) URL as a direct RSS subscribe candidate.
        if let feedURL = PodcastManager.httpURL(from: q) {
            do {
                let show = try await PodcastManager.discover(from: feedURL)
                guard !Task.isCancelled else { return }
                podcastFeedCandidate = show
                podcastHits = []
                if let art = show.imageURL {
                    ImageLoader.shared.prefetch([art], limit: 1, priority: .userInitiated)
                }
            } catch {
                podcastFeedCandidate = nil
                self.error = error.localizedDescription
            }
            return
        }

        podcastFeedCandidate = nil
        do {
            let results = try await PodcastManager.searchPodcasts(query: q)
            guard !Task.isCancelled else { return }
            podcastHits = results
            ImageLoader.shared.prefetch(results.compactMap(\.show.imageURL), limit: 24, priority: .userInitiated)
        } catch {
            self.error = error.localizedDescription
            podcastHits = []
        }
    }

    private func runLocalSearch(_ q: String) async {
        let serverKey = session.account.serverKey
        let index = session.library
        let playlists = await cachedPlaylists()
        let ownership = await session.artistOwnershipStats()
        let songsIndexed = await session.songsIndexComplete()
        let hideCredits = LibraryArtistFilter.hideCreditOnlyArtists
        let ranked = await Task.detached(priority: .userInitiated) {
            let metadata = (try? index.search(serverKey: serverKey, query: q))
                ?? SearchResult3(artist: nil, album: nil, song: nil)
            let artistFilter: ((Artist) -> Bool)? = hideCredits
                ? { LibraryArtistFilter.isVisible($0, ownership: ownership[$0.id], songsIndexed: songsIndexed) }
                : nil
            return SearchRanker.rank(
                query: q, result: metadata, playlists: playlists, artistFilter: artistFilter)
        }.value
        guard !Task.isCancelled else { return }
        hits = ranked
        if !ranked.isEmpty || q.count < 2 {
            hasCompletedSearch = true
        }
    }

    private func runNetworkSearch(_ q: String) async {
        isSearching = true
        error = nil
        defer {
            isSearching = false
            hasCompletedSearch = true
        }
        do {
            let client = session.client
            let ownership = await session.artistOwnershipStats()
            let songsIndexed = await session.songsIndexComplete()
            let hideCredits = LibraryArtistFilter.hideCreditOnlyArtists
            let artistFilter: ((Artist) -> Bool)? = hideCredits
                ? { LibraryArtistFilter.isVisible($0, ownership: ownership[$0.id], songsIndexed: songsIndexed) }
                : nil

            async let metadataTask = client.search(q, artistCount: 20, albumCount: 20, songCount: 40)
            async let playlistsTask = refreshPlaylists()

            let metadata = try await metadataTask
            let playlists = await playlistsTask
            guard !Task.isCancelled else { return }
            hits = SearchRanker.rank(
                query: q, result: metadata, playlists: playlists, artistFilter: artistFilter)
            let songs = metadata.songs
            Task { @MainActor in
                await Task.yield()
                session.ratings.ingest(songs)
            }
        } catch {
            if hits.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    /// Prefer a warm cache so the first keystroke can rank playlists offline.
    private func cachedPlaylists() async -> [Playlist] {
        if !playlistCache.isEmpty { return playlistCache }
        return await refreshPlaylists()
    }

    private func refreshPlaylists() async -> [Playlist] {
        let list = (try? await session.client.playlists()) ?? playlistCache
        playlistCache = list
        return list
    }

    private func runSpotifySearch(_ q: String) async {
        guard let wishlist = session.wishlist else { return }
        isSearching = true
        error = nil
        defer {
            isSearching = false
            hasCompletedSearch = true
        }
        do {
            let hits = try await wishlist.search(query: q, types: "track,album,playlist", limit: 10)
            spotifyHits = hits
            await resolveLibraryMatches(hits)
        } catch {
            self.error = CompanionNetworkError.shortReason(for: error)
        }
    }

    private func resolveLibraryMatches(_ hits: [SpotifySearchHit]) async {
        let client = session.client
        var songs: [String: Song] = [:]
        var albums: [String: Album] = [:]
        await withTaskGroup(of: (String, Song?, Album?).self) { group in
            for hit in hits {
                group.addTask {
                    switch hit.kind {
                    case "album":
                        let album = await LibraryMatcher.matchedAlbum(for: hit, client: client)
                        return (hit.spotifyId, nil, album)
                    case "track", "":
                        let song = await LibraryMatcher.matchedSong(for: hit, client: client)
                        return (hit.spotifyId, song, nil)
                    default:
                        return (hit.spotifyId, nil, nil)
                    }
                }
            }
            for await (id, song, album) in group {
                if let song { songs[id] = song }
                if let album { albums[id] = album }
            }
        }
        matchedSongs = songs
        matchedAlbums = albums
    }

    private func addToWishlist(_ hit: SpotifySearchHit) async {
        guard let wishlist = session.wishlist else { return }
        addingSpotifyIDs.insert(hit.spotifyId)
        defer { addingSpotifyIDs.remove(hit.spotifyId) }
        do {
            _ = try await wishlist.add(spotifyLink: hit.spotifyUrl)
            addedSpotifyIDs.insert(hit.spotifyId)
        } catch {
            self.error = CompanionNetworkError.shortReason(for: error)
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

/// Forces the system `.searchable` field opaque so genre tiles can’t show through.
/// Applies once — re-hardening on every mode change rebuilt the field and
/// made typed text appear/disappear.
private struct SearchChromeOpaqueFix: UIViewRepresentable {
    final class Coordinator {
        var didApply = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard !context.coordinator.didApply else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.didApply else { return }
            if Self.apply(from: uiView) {
                context.coordinator.didApply = true
            }
        }
    }

    @discardableResult
    private static func apply(from seed: UIView) -> Bool {
        var responder: UIView? = seed
        var nav: UINavigationController?
        while let current = responder {
            if let found = current.next as? UINavigationController {
                nav = found
                break
            }
            if let vc = current.next as? UIViewController {
                nav = vc.navigationController
                if nav != nil { break }
            }
            responder = current.superview
        }
        guard let nav else { return false }

        let bg = UIColor(DromeTheme.background)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bg
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        // Scope opacity to Search's navigationItem only — setting the bar
        // globally left a black strip on pushed artist heroes (toolbarBackground
        // .hidden couldn't undo isTranslucent = false).
        if let item = nav.topViewController?.navigationItem {
            item.standardAppearance = appearance
            item.scrollEdgeAppearance = appearance
            item.compactAppearance = appearance
        }

        hardenSearchBars(in: nav.view, background: bg)
        if let search = nav.topViewController?.navigationItem.searchController?.searchBar {
            harden(searchBar: search, background: bg)
        }
        return true
    }

    private static func hardenSearchBars(in root: UIView, background: UIColor) {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let bar = view as? UISearchBar {
                harden(searchBar: bar, background: background)
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    private static func harden(searchBar: UISearchBar, background: UIColor) {
        searchBar.isTranslucent = false
        searchBar.backgroundImage = UIImage()
        searchBar.barTintColor = background
        searchBar.backgroundColor = background
        let field = searchBar.searchTextField
        field.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        var parent: UIView? = searchBar
        while let view = parent {
            if view is UINavigationBar { break }
            view.backgroundColor = background
            parent = view.superview
        }
    }
}
