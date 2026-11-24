import CarPlay
import Foundation
import UIKit

/// CarPlay entry point (`CPTemplateApplicationSceneSessionRoleApplication`).
///
/// Tabs: Home · Search · Your Library · Podcasts. Now Playing is the shared
/// system template (artwork via `MPNowPlayingInfoCenter`; rate toggle /
/// shuffle / repeat / autoplay; Queue + system album/artist actions).
///
/// Home / Library layout is Aura-inspired: section-headered cover rails
/// (Made For You, Recently Played, Jump Back In / Recently Added), Shuffle
/// All on Library, playlists on Library — not stacked on Home.
///
/// Search prefers `CPSearchTemplate` (native keyboard / voice) when the OS
/// allows it for audio apps. Fallback chooser: Voice search · Keyboard.
///
/// Requires `com.apple.developer.carplay-audio` on the App ID / profile.
@MainActor
final class CarPlaySceneDelegate: UIResponder,
                                  CPTemplateApplicationSceneDelegate,
                                  CPTabBarTemplateDelegate,
                                  CPSessionConfigurationDelegate,
                                  CPNowPlayingTemplateObserver,
                                  CPSearchTemplateDelegate {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private weak var homeTabTemplate: CPListTemplate?
    private weak var searchTabTemplate: CPListTemplate?
    private weak var libraryTabTemplate: CPListTemplate?
    private weak var podcastsTabTemplate: CPListTemplate?
    private weak var mirroredResultsTemplate: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?
    private var sessionConfiguration: CPSessionConfiguration?
    private var searchTask: Task<Void, Never>?
    private var homeLoadTask: Task<Void, Never>?
    private var libraryLoadTask: Task<Void, Never>?
    private var searchSongs: [String: Song] = [:]
    private var searchAlbums: [String: Album] = [:]
    private var searchArtists: [String: Artist] = [:]
    private var mirrorQueryObserver: NSObjectProtocol?
    private var listsLimited = false
    private let customKeyboard = CarPlayKeyboard()

    /// Runtime list maxima (respects vehicle Limit UI).
    private var listLimits: CarPlayListPolicy.Limits {
        CarPlayListPolicy.Limits.resolve(
            maximumSectionCount: CPListTemplate.maximumSectionCount,
            maximumItemCount: CPListTemplate.maximumItemCount,
            listsLimited: listsLimited)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        // List artwork must be rasterized for the *car* display scale.
        let scale = interfaceController.carTraitCollection.displayScale
        CarPlayArtwork.carDisplayScale = scale > 0 ? scale : 2.0
        CarPlayArtwork.prepare()
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        configureNowPlayingTemplate()
        rebuildRoot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionChanged),
            name: .dromeSessionChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioFocusChanged),
            name: AudioFocus.didChangeNotification, object: nil)
        DromeDiagnostics.log("carplay connected", category: .session)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        searchTask?.cancel()
        homeLoadTask?.cancel()
        libraryLoadTask?.cancel()
        stopMirrorSearch()
        searchTemplate = nil
        homeTabTemplate = nil
        searchTabTemplate = nil
        libraryTabTemplate = nil
        podcastsTabTemplate = nil
        mirroredResultsTemplate = nil
        queueEditorTemplate = nil
        albumBrowseTemplate = nil
        albumsBrowseOffset = 0
        sessionConfiguration = nil
        customKeyboard.reset()
        self.interfaceController = nil
        tabBar = nil
        NotificationCenter.default.removeObserver(self)
        DromeDiagnostics.log("carplay disconnected", category: .session)
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        let wasLimited = listsLimited
        listsLimited = limitedUserInterfaces.contains(.lists)
        // Rebuild so lists clamp to the shorter vehicle cap when Limit UI toggles.
        if wasLimited != listsLimited {
            rebuildRoot()
        }
    }

    /// Apply sections after clamping to `CPListTemplate` maxima.
    private func applySections(_ sections: [CPListSection], to template: CPListTemplate) {
        template.updateSections(clampSections(sections))
    }

    private func clampSections(_ sections: [CPListSection]) -> [CPListSection] {
        let limits = listLimits
        var remaining = limits.maxItems
        var out: [CPListSection] = []
        for section in sections.prefix(limits.maxSections) {
            guard remaining > 0 else { break }
            let items = Array(section.items.prefix(remaining))
            guard !items.isEmpty else { continue }
            out.append(CPListSection(
                items: items,
                header: section.header,
                sectionIndexTitle: section.sectionIndexTitle))
            remaining -= items.count
        }
        return out.isEmpty && !sections.isEmpty
            ? [CPListSection(items: Array(sections[0].items.prefix(1)))]
            : out
    }

    private func serverErrorSection(retry: @escaping () -> Void) -> CPListSection {
        let message = CPListItem(
            text: "Can't reach your server",
            detailText: "Check Wi‑Fi or your Navidrome URL")
        if let image = UIImage(systemName: "wifi.exclamationmark") {
            message.setImage(image)
        }
        let retryItem = CPListItem(text: "Retry", detailText: "Try loading again")
        if let image = UIImage(systemName: "arrow.clockwise") {
            retryItem.setImage(image)
        }
        retryItem.handler = { _, completion in
            retry()
            completion()
        }
        return CPListSection(items: [message, retryItem])
    }

    private func emptySection(title: String, detail: String) -> CPListSection {
        CPListSection(items: [CPListItem(text: title, detailText: detail)])
    }

    @objc private func sessionChanged() {
        if let key = AppEnvironment.shared?.session?.account.userKey {
            CarPlayHomeCache.prepare(for: key)
        } else {
            CarPlayHomeCache.invalidate(clearingAccount: true)
        }
        rebuildRoot()
    }

    @objc private func audioFocusChanged() {
        refreshNowPlayingButtons()
    }

    // MARK: - Root

    private func rebuildRoot() {
        guard let interfaceController else { return }

        guard let session = AppEnvironment.shared?.session else {
            CarPlayHomeCache.invalidate(clearingAccount: true)
            let list = CPListTemplate(title: "Drome", sections: clampSections([
                CPListSection(items: [
                    CPListItem(text: "Sign in on your iPhone",
                               detailText: "Open Drome and connect to Navidrome")
                ])
            ]))
            interfaceController.setRootTemplate(list, animated: true, completion: nil)
            return
        }

        // Drop stale rails if the account changed while CarPlay was disconnected.
        CarPlayHomeCache.prepare(for: session.account.userKey)

        // Tab bar only accepts list/grid templates (not Now Playing or Search).
        let home = makeHomeTemplate(session: session)
        let search = makeSearchTab(session: session)
        let library = makeLibraryTemplate(session: session)
        let podcasts = makePodcastsTemplate()
        let tabs = CPTabBarTemplate(templates: [home, search, library, podcasts])
        tabs.delegate = self
        tabBar = tabs
        homeTabTemplate = home
        searchTabTemplate = search
        libraryTabTemplate = library
        podcastsTabTemplate = podcasts
        interfaceController.setRootTemplate(tabs, animated: true, completion: nil)
        refreshNowPlayingButtons()
#if DEBUG
        DromeDiagnostics.log(dumpTemplateTree(), category: .session)
#endif
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        // Prefer jumping straight into system search / voice when the Search tab is selected.
        guard selectedTemplate === searchTabTemplate,
              let session = AppEnvironment.shared?.session else { return }
        openSearch(session: session)
    }

#if DEBUG
    /// Full textual dump of the CarPlay tree (tabs, sections, items, NP buttons).
    static func dumpTemplateTree(
        root: CPTemplate?,
        listsLimited: Bool
    ) -> String {
        let limits = CarPlayListPolicy.Limits.resolve(
            maximumSectionCount: CPListTemplate.maximumSectionCount,
            maximumItemCount: CPListTemplate.maximumItemCount,
            listsLimited: listsLimited)
        return CarPlayTemplateDump.dump(root: root, limits: limits)
    }

    func dumpTemplateTree() -> String {
        Self.dumpTemplateTree(root: tabBar ?? interfaceController?.rootTemplate, listsLimited: listsLimited)
    }
#endif

    // MARK: - Now Playing

    private func configureNowPlayingTemplate() {
        // Buttons are rebuilt in refreshNowPlayingButtons based on audio focus
        // (music shuffle/rate vs podcast skip ±30).
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        refreshNowPlayingButtons()
    }

    private func refreshNowPlayingButtons() {
        let np = CPNowPlayingTemplate.shared
        let podcastOwns = AudioFocus.shared.isOwner(.podcast)
            || (AudioFocus.shared.owner == .none
                && AppEnvironment.shared?.podcastPlayer.currentEpisode != nil
                && AppEnvironment.shared?.session?.player.isPlaying != true)

        if podcastOwns {
            // Up Next → Continue Listening (podcasts have no music-style queue).
            np.isUpNextButtonEnabled = true
            np.upNextTitle = "Up Next"
            np.isAlbumArtistButtonEnabled = false
            let backImage = UIImage(systemName: "gobackward.15") ?? UIImage()
            let back = CPNowPlayingImageButton(image: backImage) { _ in
                AppEnvironment.shared?.podcastPlayer.skipBackward(seconds: 15)
            }
            let forwardImage = UIImage(systemName: "goforward.30") ?? UIImage()
            let forward = CPNowPlayingImageButton(image: forwardImage) { _ in
                AppEnvironment.shared?.podcastPlayer.skipForward(seconds: 30)
            }
            let speedImage = UIImage(systemName: "gauge.with.dots.needle.67percent") ?? UIImage()
            let speed = CPNowPlayingImageButton(image: speedImage) { [weak self] _ in
                AppEnvironment.shared?.podcastPlayer.cycleSpeed()
                self?.refreshNowPlayingButtons()
            }
            np.updateNowPlayingButtons([back, forward, speed])
            return
        }

        guard let session = AppEnvironment.shared?.session else {
            np.updateNowPlayingButtons([])
            return
        }
        np.isUpNextButtonEnabled = true
        np.upNextTitle = "Queue"
        // System Album/Artist button covers artist navigation — no custom Artist button.
        np.isAlbumArtistButtonEnabled = true

        let player = session.player
        let rating = player.current.map { session.ratings.rating(for: $0.song) } ?? 0
        // Star reflects the real 1–5 rating; tap opens a one-level picker (never clobber stars).
        let rateSymbol = rating > 0 ? "star.fill" : "star"
        let rateImage = UIImage(systemName: rateSymbol) ?? UIImage()
        let rate = CPNowPlayingImageButton(image: rateImage) { [weak self] _ in
            self?.showRatingPicker()
        }
        rate.isSelected = rating > 0

        let radioImage = UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage()
        let radio = CPNowPlayingImageButton(image: radioImage) { [weak self] _ in
            Task { await self?.startSongRadio(session: session) }
        }

        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            AppEnvironment.shared?.session?.player.cycleShuffleMode()
            self?.refreshNowPlayingButtons()
        }
        shuffle.isSelected = player.shuffleMode != .off

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            AppEnvironment.shared?.session?.player.cycleRepeatMode()
            self?.refreshNowPlayingButtons()
        }
        repeatButton.isSelected = player.repeatMode != .off

        // Set isSelected on the button *before* updateNowPlayingButtons — post-hoc
        // writes on the shared template’s copies do not stick for custom image buttons.
        let autoplayImage = UIImage(systemName: "infinity") ?? UIImage()
        let autoplay = CPNowPlayingImageButton(image: autoplayImage) { [weak self] _ in
            guard let player = AppEnvironment.shared?.session?.player else { return }
            player.autoplayEnabled.toggle()
            self?.refreshNowPlayingButtons()
        }
        autoplay.isSelected = player.autoplayEnabled

        np.updateNowPlayingButtons([rate, radio, shuffle, repeatButton, autoplay])
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        if AudioFocus.shared.isOwner(.podcast)
            || (AudioFocus.shared.owner == .none
                && AppEnvironment.shared?.podcastPlayer.currentEpisode != nil
                && AppEnvironment.shared?.session?.player.isPlaying != true) {
            showPodcastUpNext()
            return
        }
        showQueue()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        if AudioFocus.shared.isOwner(.podcast) { return }
        Task { await openNowPlayingAlbum() }
    }

    /// Star rating via action sheet — never pushes (avoids depth 6 from Now Playing).
    /// Sheet tree from `CarPlayListPolicy.ratingSheetActions` keeps 1–5★ + Clear reachable.
    private func showRatingPicker() {
        guard let session = AppEnvironment.shared?.session,
              let song = session.player.current?.song else { return }
        presentRatingSheet(song: song, session: session, level: .high)
    }

    private func presentRatingSheet(
        song: Song,
        session: AppSession,
        level: CarPlayListPolicy.RatingSheetLevel
    ) {
        guard let interfaceController else { return }
        let current = session.ratings.rating(for: song)
        let message: String = {
            if current > 0 {
                return "Current: \(String(repeating: "★", count: current))"
            }
            return song.title
        }()

        func apply(_ stars: Int) -> (CPAlertAction) -> Void {
            { [weak self] _ in
                session.ratings.setRating(stars, for: song)
                self?.refreshNowPlayingButtons()
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        }

        let actions: [CPAlertAction] = CarPlayListPolicy.ratingSheetActions(level: level).map { action in
            switch action {
            case .setStars(let n):
                let title = String(repeating: "★", count: n)
                return CPAlertAction(title: title, style: .default, handler: apply(n))
            case .clear:
                return CPAlertAction(title: "Clear rating", style: .destructive, handler: apply(0))
            case .more(let next):
                let title: String = {
                    switch next {
                    case .mid: return "1–3★…"
                    case .low: return "★ / Clear…"
                    case .high: return "More…"
                    }
                }()
                return CPAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: false) { _, _ in
                        self?.presentRatingSheet(song: song, session: session, level: next)
                    }
                }
            }
        }

        let sheet = CPActionSheetTemplate(title: "Rate", message: message, actions: actions)
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func showPodcastUpNext() {
        guard AppEnvironment.shared != nil else { return }
        let env = AppEnvironment.shared!
        let player = env.podcastPlayer
        let continuing = env.podcastManager.inProgressEpisodes()
        if continuing.isEmpty {
            let empty = CPListTemplate(title: "Up Next", sections: clampSections([
                emptySection(title: "Nothing queued",
                             detail: "Continue Listening episodes appear here")
            ]))
            pushTemplate(empty, kind: .upNext)
            return
        }
        let items: [CPListItem] = continuing.prefix(listLimits.maxItems).map { entry in
            let item = CPListItem(
                text: entry.episode.title,
                detailText: entry.episode.remainingText ?? entry.episode.durationText)
            item.handler = { [weak self] _, completion in
                player.play(entry.episode, resumeFromSaved: true)
                self?.pushNowPlaying()
                self?.refreshNowPlayingButtons()
                completion()
            }
            return item
        }
        let list = CPListTemplate(
            title: "Up Next",
            sections: clampSections([CPListSection(items: Array(items))]))
        pushTemplate(list, kind: .upNext)
    }

    private func showQueue() {
        guard let session = AppEnvironment.shared?.session else { return }
        let player = session.player
        let upcoming = player.userQueue + player.contextQueue

        if upcoming.isEmpty {
            let empty = CPListTemplate(title: "Queue", sections: [
                CPListSection(items: [
                    CPListItem(text: "Queue is empty", detailText: "Play something to build a queue")
                ])
            ])
            pushTemplate(empty, kind: .upNext)
            return
        }

        let items: [CPListItem] = upcoming.map { item in
            let row = listItem(
                text: item.song.title,
                detail: item.song.artist,
                coverArt: item.song.coverArt,
                fallbackId: item.song.albumId ?? item.song.id,
                session: session)
            row.handler = { [weak self] _, completion in
                let songs = upcoming.map(\.song)
                let start = upcoming.firstIndex(where: { $0.id == item.id }) ?? 0
                player.play(
                    songs,
                    startAt: start,
                    context: player.context ?? PlaybackContext(label: "Queue", kind: .mix))
                self?.pushNowPlaying()
                completion()
            }
            return row
        }

        let manage = CPListItem(text: "Remove songs…", detailText: "Pick tracks to drop from the queue")
        manage.handler = { [weak self] _, completion in
            self?.showQueueEditor()
            completion()
        }

        let capped = Array(items.prefix(max(0, listLimits.maxItems - 1)))
        let list = CPListTemplate(title: "Queue", sections: clampSections([
            CPListSection(items: [manage]),
            CPListSection(items: capped, header: "Up Next", sectionIndexTitle: nil)
        ]))
        pushTemplate(list, kind: .upNext)
    }

    private weak var queueEditorTemplate: CPListTemplate?

    private func showQueueEditor() {
        guard let session = AppEnvironment.shared?.session else { return }
        let player = session.player
        let upcoming = player.userQueue + player.contextQueue
        let items: [CPListItem] = upcoming.map { item in
            let row = listItem(
                text: item.song.title,
                detail: "Tap to remove",
                coverArt: item.song.coverArt,
                fallbackId: item.song.albumId ?? item.song.id,
                session: session)
            row.handler = { [weak self] _, completion in
                player.removeFromQueue(item)
                self?.showQueueEditor()
                completion()
            }
            return row
        }
        let sections = [CPListSection(items: items.isEmpty
                                      ? [CPListItem(text: "Queue is empty", detailText: nil)]
                                      : items)]
        if let existing = queueEditorTemplate {
            applySections(sections, to: existing)
            return
        }
        let list = CPListTemplate(title: "Edit Queue", sections: sections)
        queueEditorTemplate = list
        pushTemplate(list, kind: .queueEditor)
    }

    private func openNowPlayingAlbum() async {
        guard let session = AppEnvironment.shared?.session,
              let song = session.player.current?.song else { return }
        if let albumId = song.albumId, !albumId.isEmpty {
            await showAlbum(
                id: albumId,
                name: song.album ?? "Album",
                session: session,
                coverArt: song.coverArt,
                artist: song.artist)
        } else {
            await openNowPlayingArtist()
        }
    }

    private func openNowPlayingArtist() async {
        guard let session = AppEnvironment.shared?.session,
              let song = session.player.current?.song else { return }
        let route = SongNavigation.artistRoutes(for: song).first
            ?? SongNavigation.artistRoute(for: song)
        guard let route else { return }
        await showArtist(id: route.artistId, name: route.name, session: session)
    }

    // MARK: - Home

    private func makeHomeTemplate(session: AppSession) -> CPListTemplate {
        let template = CPListTemplate(title: "Home", sections: clampSections([
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ]))
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house.fill")
        // Paint cached rails immediately to avoid a blank → flash reload.
        if !CarPlayHomeCache.cachedFrequent.isEmpty
            || !CarPlayHomeCache.cachedPlaylists.isEmpty
            || CarPlayHomeCache.cachedError != nil {
            applySections(buildHomeSections(
                session: session,
                recent: (try? AppEnvironment.shared?.database.recentPlayEntries(
                    userKey: session.account.userKey, limit: 30)) ?? [],
                frequent: CarPlayHomeCache.cachedFrequent,
                playlists: CarPlayHomeCache.cachedPlaylists,
                mixes: CarPlayHomeCache.cachedDailyMixes,
                error: CarPlayHomeCache.cachedError,
                homeTemplate: template), to: template)
        }
        reloadHome(template: template, session: session)
        return template
    }

    private func reloadHome(template: CPListTemplate, session: AppSession) {
        homeLoadTask?.cancel()
        homeLoadTask = Task { [weak self] in
            guard let self else { return }
            let recent = (try? AppEnvironment.shared?.database.recentPlayEntries(
                userKey: session.account.userKey, limit: 30)) ?? []

            // Kick network work in parallel; apply once when everything settles.
            // Newest feeds Library’s Recently Added grid (Aura-style).
            async let frequentTask = session.client.albumList(type: .frequent, size: 16)
            async let newestTask = session.client.albumList(
                type: .newest, size: CarPlayListPolicy.libraryNewestTiles)
            async let mixesTask = self.fetchDailyMixes(session: session)
            async let playlistsTask = self.fetchPlaylists(session: session)

            let frequentOK: Bool
            let frequent: [Album]
            do {
                frequent = try await frequentTask
                frequentOK = true
            } catch {
                frequent = CarPlayHomeCache.cachedFrequent
                frequentOK = false
            }

            let newest: [Album]
            do {
                newest = try await newestTask
            } catch {
                newest = CarPlayHomeCache.cachedNewest
            }

            let playlistsOutcome = await playlistsTask
            let mixes = await mixesTask
            guard !Task.isCancelled else { return }

            let playlists = playlistsOutcome.value
            if playlistsOutcome.ok {
                CarPlayHomeCache.storePlaylists(playlists)
            }
            CarPlayHomeCache.storeRails(frequent: frequent, newest: newest)
            CarPlayHomeCache.storeDailyMixes(mixes)

            let serverFailed = !frequentOK && !playlistsOutcome.ok
            let error: String?
            if serverFailed && frequent.isEmpty && playlists.isEmpty {
                let message = "Can't reach your server"
                CarPlayHomeCache.storeError(message)
                error = message
            } else {
                error = nil
                CarPlayHomeCache.clearError()
            }

            let sections = self.buildHomeSections(
                session: session,
                recent: recent,
                frequent: frequent,
                playlists: playlists,
                mixes: mixes,
                error: error,
                homeTemplate: template)
            self.applySections(sections, to: template)
            // Library may already be on screen — refresh Recently Added from cache.
            if let library = self.libraryTabTemplate {
                self.applySections(
                    self.buildLibrarySections(
                        session: session, lists: playlists, error: false,
                        libraryTemplate: library),
                    to: library)
            }
            CarPlayArtwork.prefetch(
                ids: frequent.map { $0.coverArt ?? $0.id }
                    + newest.map { $0.coverArt ?? $0.id }
                    + mixes.prefix(8).flatMap(\.coverArtIds)
                    + playlists.prefix(8).map { $0.coverArt ?? $0.id },
                session: session)
        }
    }

    private func buildHomeSections(
        session: AppSession,
        recent: [RecentPlayEntry],
        frequent: [Album],
        playlists _: [Playlist],
        mixes: [DailyMix],
        error: String?,
        homeTemplate: CPListTemplate
    ) -> [CPListSection] {
        let perRow = max(1, Int(CPMaximumNumberOfGridImages))
        let tileCap = min(CarPlayListPolicy.homeImageRowTiles, perRow)
        let gridCap = min(CarPlayListPolicy.homeAlbumGridTiles, perRow * 2)
        // Same blueprint XCTest dumps — handlers attach to the live CP items below.
        // Playlists stay on Library (Aura-style Home has no playlist rail).
        let input = CarPlayListPolicy.HomeInput(
            serverError: error != nil,
            recentTitles: recent.map(recentTitle),
            frequentTitles: frequent.map(\.name),
            playlistTitles: [],
            mixTitles: mixes.map(\.title),
            vibeTitles: MoodVibe.spectrum.map(\.title))
        let spec = CarPlayListPolicy.buildHomeSpec(
            input, tileCap: tileCap, albumGridCap: gridCap)
        let clamped = CarPlayListPolicy.clamp(spec.sections, limits: listLimits)

        if error != nil {
            return [serverErrorSection { [weak self] in
                self?.reloadHome(template: homeTemplate, session: session)
            }]
        }

        var sections: [CPListSection] = []
        for section in clamped {
            // Section header carries the rail name — omit duplicate row text.
            let hideRowText = section.header != nil
            var items: [CPListTemplateItem] = []
            for item in section.items {
                switch item.title {
                case "Nothing here yet":
                    items.append(CPListItem(text: item.title, detailText: item.subtitle))
                case "Song Radio":
                    let radio = actionItem(
                        title: item.title,
                        detail: item.subtitle,
                        systemImage: "dot.radiowaves.left.and.right")
                    radio.handler = { [weak self] _, completion in
                        Task {
                            await self?.startSongRadio(session: session)
                            completion()
                        }
                    }
                    items.append(radio)
                case "Daily Mixes":
                    let tiles = Array(mixes.prefix(tileCap))
                    items.append(contentsOf: coverGridRows(
                        titles: tiles.map(\.title),
                        style: .playlist,
                        rowText: hideRowText ? nil : item.title,
                        perRow: perRow,
                        session: session,
                        covers: { tiles.map {
                            ($0.title, $0.coverArtIds.first, $0.songs.first?.coverArt)
                        }},
                        onTile: { [weak self] index in
                            guard tiles.indices.contains(index) else { return }
                            self?.playDailyMix(tiles[index], session: session)
                        },
                        onRow: { [weak self] in
                            self?.showDailyMixList(mixes, session: session)
                        }))
                case "Vibe Tuner":
                    let vibes = Array(MoodVibe.spectrum.prefix(tileCap))
                    items.append(contentsOf: coverGridRows(
                        titles: vibes.map(\.title),
                        style: .song,
                        rowText: hideRowText ? nil : item.title,
                        perRow: perRow,
                        session: session,
                        covers: { vibes.map { ($0.title, nil as String?, nil as String?) } },
                        onTile: { [weak self] index in
                            guard vibes.indices.contains(index) else { return }
                            Task {
                                await MoodPlayer.play(vibes[index], session: session)
                                self?.pushNowPlaying()
                            }
                        },
                        onRow: { [weak self] in
                            self?.showVibeList(session: session)
                        }))
                case "Recently Played":
                    let recentEntries = Array(recent.prefix(gridCap))
                    items.append(contentsOf: coverGridRows(
                        titles: recentEntries.map(recentTitle),
                        style: .album,
                        rowText: hideRowText ? nil : item.title,
                        perRow: perRow,
                        session: session,
                        covers: { recentEntries.map { self.recentCover($0) } },
                        onTile: { [weak self] index in
                            guard let self, recentEntries.indices.contains(index) else { return }
                            self.activateRecent(recentEntries[index], session: session)
                        },
                        onRow: { [weak self] in
                            self?.showRecentList(recent, session: session)
                        }))
                case "Jump Back In":
                    let albums = Array(frequent.prefix(gridCap))
                    items.append(contentsOf: coverGridRows(
                        titles: albums.map(\.name),
                        style: .album,
                        rowText: hideRowText ? nil : item.title,
                        perRow: perRow,
                        session: session,
                        covers: { albums.map { ($0.name, $0.coverArt, $0.id) } },
                        onTile: { [weak self] index in
                            guard albums.indices.contains(index) else { return }
                            let album = albums[index]
                            Task {
                                await self?.showAlbum(
                                    id: album.id, name: album.name, session: session,
                                    coverArt: album.coverArt, artist: album.artist,
                                    year: album.year, songCount: album.songCount)
                            }
                        },
                        onRow: { [weak self] in
                            self?.showAlbumList(frequent, title: "Jump Back In", session: session)
                        }))
                default:
                    items.append(CPListItem(text: item.title, detailText: item.subtitle))
                }
            }
            if !items.isEmpty {
                sections.append(CPListSection(
                    items: items, header: section.header, sectionIndexTitle: nil))
            }
        }
        return sections
    }

    /// Chunks covers into one or more `CPListImageRowItem`s (Aura-style multi-row
    /// grids under a section header). `rowText` is nil when the section header
    /// already names the rail.
    private func coverGridRows(
        titles: [String],
        style: CarPlayArtwork.Style,
        rowText: String?,
        perRow: Int,
        session: AppSession,
        covers: () -> [(String, String?, String?)],
        onTile: @escaping (Int) -> Void,
        onRow: @escaping () -> Void
    ) -> [CPListImageRowItem] {
        let allCovers = covers()
        guard !titles.isEmpty else { return [] }
        let strideSize = max(1, perRow)
        var rows: [CPListImageRowItem] = []
        var offset = 0
        while offset < titles.count {
            let end = min(offset + strideSize, titles.count)
            let sliceTitles = Array(titles[offset..<end])
            let base = offset
            let images = sliceTitles.map {
                CarPlayArtwork.placeholder(style: style, title: $0)
            }
            let row = CPListImageRowItem(text: rowText, images: images)
            row.listImageRowHandler = { _, index, completion in
                let absolute = base + index
                guard sliceTitles.indices.contains(index) else { completion(); return }
                onTile(absolute)
                completion()
            }
            row.handler = { _, completion in
                onRow()
                completion()
            }
            let sliceCovers = Array(allCovers[offset..<min(end, allCovers.count)])
            Task { @MainActor [weak self] in
                await self?.refreshImageRow(
                    row, covers: sliceCovers, session: session, style: style)
            }
            rows.append(row)
            offset = end
        }
        return rows
    }

    private func activateRecent(_ entry: RecentPlayEntry, session: AppSession) {
        switch entry {
        case .song(let song):
            playSongs([song], startAt: 0, label: song.title, kind: .search, session: session)
        case .album(let id, let name, let cover):
            Task {
                await showAlbum(
                    id: id, name: name, session: session,
                    coverArt: cover.coverArt, artist: cover.artist)
            }
        case .playlist(let id, let name, let cover):
            Task {
                await showPlaylist(
                    id: id, name: name, coverArt: cover.coverArt, session: session)
            }
        case .mix(_, let name, let cover, _):
            if let mix = CarPlayHomeCache.cachedDailyMixes.first(where: { $0.title == name }) {
                playDailyMix(mix, session: session)
            } else {
                playSongs([cover], startAt: 0, label: name, kind: .mix, session: session)
            }
        }
    }

    private func recentTitle(_ entry: RecentPlayEntry) -> String {
        switch entry {
        case .song(let song): return song.title
        case .album(_, let name, _): return name
        case .playlist(_, let name, _): return name
        case .mix(_, let name, _, _): return name
        }
    }

    private func recentCover(_ entry: RecentPlayEntry) -> (String, String?, String?) {
        switch entry {
        case .song(let song):
            return (song.title, song.coverArt, song.albumId ?? song.id)
        case .album(let id, let name, let cover):
            return (name, cover.coverArt, id)
        case .playlist(let id, let name, let cover):
            return (name, cover.coverArt, id)
        case .mix(_, let name, let cover, _):
            return (name, cover.coverArt, cover.albumId ?? cover.id)
        }
    }

    private func refreshImageRow(
        _ row: CPListImageRowItem,
        covers: [(title: String, coverArt: String?, fallbackId: String?)],
        session: AppSession,
        style: CarPlayArtwork.Style
    ) async {
        var images: [UIImage] = []
        for cover in covers {
            let placeholder = CarPlayArtwork.placeholder(style: style, title: cover.title)
            if let key = cover.coverArt ?? cover.fallbackId,
               let url = session.artworkURL(id: key, size: CarPlayArtwork.fetchSize),
               let image = await CarPlayArtwork.loadForRow(url: url, session: session) {
                images.append(image)
            } else {
                images.append(placeholder)
            }
        }
        guard !images.isEmpty else { return }
        row.update(images)
    }

    private struct FetchOutcome<T> {
        var value: T
        var ok: Bool
    }

    private func fetchPlaylists(session: AppSession) async -> FetchOutcome<[Playlist]> {
        if CarPlayHomeCache.playlistsFresh {
            return FetchOutcome(value: CarPlayHomeCache.cachedPlaylists, ok: true)
        }
        do {
            return FetchOutcome(value: try await session.client.playlists(), ok: true)
        } catch {
            return FetchOutcome(value: CarPlayHomeCache.cachedPlaylists, ok: false)
        }
    }

    private func fetchDailyMixes(session: AppSession) async -> [DailyMix] {
        let exclude = Array(session.rotation.excludedIDs)
        return (try? await session.wishlist?.dailyMixes(
            excludeSongIDs: exclude,
            recencyHours: PlaybackPreferences.autoplayRecencyHours
        ))?.mixes ?? CarPlayHomeCache.cachedDailyMixes
    }

    private func playShuffleAll(session: AppSession) async {
        var songs = (try? await session.client.randomSongs(size: 80)) ?? []
        if songs.isEmpty {
            songs = (try? await session.client.randomSongs(size: 80)) ?? []
        }
        guard !songs.isEmpty else { return }
        session.player.playShuffled(
            songs, context: PlaybackContext(label: "Shuffle All", kind: .mix))
        pushNowPlaying()
    }

    /// Song Radio / Instant Mix from the current track (or most recent play).
    private func startSongRadio(session: AppSession) async {
        var seed = session.player.current?.song
        if seed == nil {
            seed = (try? session.database.recentPlays(
                userKey: session.account.userKey, limit: 1))?.first
        }
        guard let seed else {
            presentSimpleAlert(
                title: "Nothing to radio",
                message: "Play a song first, then start Song Radio.")
            return
        }
        let songs = await InstantMix.songs(from: seed, client: session.client, count: 40)
        guard songs.count > 1 else {
            presentSimpleAlert(
                title: "Radio unavailable",
                message: "Couldn’t build a mix from this track.")
            return
        }
        let context = PlaybackContext(
            label: "Song Radio · \(seed.artist ?? seed.title)",
            kind: .mix)
        if session.player.current?.song.id == seed.id {
            session.player.adoptUpcomingMix(songs, context: context)
        } else {
            session.player.play(songs, startAt: 0, context: context)
        }
        pushNowPlaying()
    }

    private func playDailyMix(_ mix: DailyMix, session: AppSession) {
        let excluded = session.rotation.excludedIDs
        let songs = mix.songs.filter { !excluded.contains($0.id) }
        guard !songs.isEmpty else { return }
        playSongs(songs, startAt: 0, label: mix.title, kind: .mix, session: session)
    }

    private func showDailyMixList(_ mixes: [DailyMix], session: AppSession) {
        guard interfaceController != nil else { return }
        let items: [CPListItem] = mixes.map { mix in
            let item = listItem(
                text: mix.title,
                detail: mix.subtitle,
                coverArt: mix.coverArtIds.first ?? mix.songs.first?.coverArt,
                fallbackId: mix.songs.first?.albumId ?? mix.id,
                session: session,
                style: .playlist)
            item.handler = { [weak self] _, completion in
                self?.playDailyMix(mix, session: session)
                completion()
            }
            return item
        }
        let list = CPListTemplate(
            title: "Daily Mixes",
            sections: clampSections([CPListSection(items: items)]))
        pushTemplate(list, kind: .browse)
    }

    private func showVibeList(session: AppSession) {
        guard interfaceController != nil else { return }
        let items: [CPListItem] = MoodVibe.spectrum.map { vibe in
            let item = actionItem(
                title: vibe.title, detail: vibe.blurb, systemImage: vibe.symbol)
            item.handler = { [weak self] _, completion in
                Task {
                    await MoodPlayer.play(vibe, session: session)
                    self?.pushNowPlaying()
                    completion()
                }
            }
            return item
        }
        let list = CPListTemplate(
            title: "Vibe Tuner",
            sections: clampSections([CPListSection(items: items)]))
        pushTemplate(list, kind: .browse)
    }

    private func showRecentList(_ recent: [RecentPlayEntry], session: AppSession) {
        guard interfaceController != nil else { return }
        let items = recent.prefix(listLimits.maxItems).compactMap { recentItem($0, session: session) }
        let list = CPListTemplate(
            title: "Recently Played",
            sections: clampSections([
                items.isEmpty
                    ? emptySection(title: "Nothing here yet", detail: "Play something to fill this list")
                    : CPListSection(items: Array(items))
            ]))
        pushTemplate(list, kind: .browse)
    }

    private func showAlbumList(_ albums: [Album], title: String, session: AppSession) {
        guard interfaceController != nil else { return }
        let capped = Array(albums.prefix(listLimits.maxItems))
        let list = CPListTemplate(
            title: title,
            sections: clampSections([
                CPListSection(items: albumItems(capped, session: session))
            ]))
        pushTemplate(list, kind: .browse)
    }

    private func recentItem(_ entry: RecentPlayEntry, session: AppSession) -> CPListItem? {
        switch entry {
        case .song(let song):
            let item = listItem(
                text: song.title,
                detail: song.artist,
                coverArt: song.coverArt,
                fallbackId: song.albumId ?? song.id,
                session: session)
            item.handler = { [weak self] _, completion in
                self?.playSongs([song], startAt: 0, label: song.title, kind: .search, session: session)
                completion()
            }
            return item
        case .album(let id, let name, let cover):
            let item = listItem(
                text: name,
                detail: cover.artist,
                coverArt: cover.coverArt,
                fallbackId: id,
                session: session)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbum(
                        id: id,
                        name: name,
                        session: session,
                        coverArt: cover.coverArt,
                        artist: cover.artist)
                    completion()
                }
            }
            return item
        case .playlist(let id, let name, let cover):
            let item = listItem(
                text: name,
                detail: "Playlist",
                coverArt: cover.coverArt,
                fallbackId: id,
                session: session)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showPlaylist(
                        id: id, name: name, coverArt: cover.coverArt, session: session)
                    completion()
                }
            }
            return item
        case .mix(_, let name, let cover, let subtitle):
            let item = listItem(
                text: name,
                detail: subtitle,
                coverArt: cover.coverArt,
                fallbackId: cover.albumId ?? cover.id,
                session: session)
            item.handler = { [weak self] _, completion in
                // Prefer the full Daily Mix when cached; never play only the cover song.
                if let mix = CarPlayHomeCache.cachedDailyMixes.first(where: {
                    $0.title == name
                }) {
                    self?.playDailyMix(mix, session: session)
                } else {
                    self?.playSongs([cover], startAt: 0, label: name, kind: .mix, session: session)
                }
                completion()
            }
            return item
        }
    }

    // MARK: - Search

    private func makeSearchTab(session: AppSession) -> CPListTemplate {
        // Structure from CarPlayListPolicy.buildSearchChooserSpec (same as XCTest).
        let spec = CarPlayListPolicy.buildSearchChooserSpec()
        var items: [CPListItem] = []
        for item in spec.sections.flatMap(\.items) {
            let row = CPListItem(text: item.title, detailText: item.subtitle)
            switch item.title {
            case "Voice search":
                if let image = UIImage(systemName: "mic.fill") { row.setImage(image) }
                row.handler = { [weak self] _, completion in
                    self?.openSearch(session: session)
                    completion()
                }
            case "Keyboard":
                if let image = UIImage(systemName: "keyboard") { row.setImage(image) }
                row.handler = { [weak self] _, completion in
                    self?.openCustomKeyboard(session: session)
                    completion()
                }
            default:
                break
            }
            items.append(row)
        }
        let template = CPListTemplate(title: spec.title, sections: clampSections([
            CPListSection(items: items)
        ]))
        template.tabTitle = spec.tabTitle ?? spec.title
        template.tabImage = UIImage(systemName: "magnifyingglass")
        return template
    }

    /// Prefer Apple’s `CPSearchTemplate`; otherwise mirror the iPhone QWERTY.
    private func openSearch(session: AppSession) {
        // Limit UI hides the system keyboard — go straight to the letter pad
        // (never present an alert and push a search template at the same time).
        if let limits = sessionConfiguration?.limitedUserInterfaces,
           limits.contains(.keyboard) {
            openCustomKeyboard(session: session)
            return
        }

        // Soft probe each time. A failed push falls back for this attempt only
        // (never permanently disables system search for the session).
        pushSystemSearchTemplate { [weak self] ok in
            guard let self else { return }
            if ok { return }
            self.openMirroredPhoneSearch(session: session)
        }
    }

    private func openCustomKeyboard(session: AppSession) {
        guard interfaceController != nil else { return }
        stopMirrorSearch()
        let template = customKeyboard.makeTemplate { [weak self] query in
            Task { @MainActor in
                await self?.showSearchResults(
                    query: query, session: session, title: "“\(query)”")
            }
        }
        pushTemplate(template, kind: .search)
    }

    /// Real QWERTY on the iPhone; live hits update on CarPlay.
    private func openMirroredPhoneSearch(session: AppSession) {
        guard let interfaceController else { return }
        stopMirrorSearch()

        let placeholder = CPListItem(
            text: "Type on your iPhone",
            detailText: "Search opens there — results appear here")
        let list = CPListTemplate(
            title: "Search",
            sections: [CPListSection(items: [placeholder])])
        list.trailingNavigationBarButtons = [
            CPBarButton(title: "Voice") { [weak self] _ in
                // Pop the mirrored overlay first — never stack another search push.
                self?.replaceMirroredSearch {
                    self?.openSearch(session: session)
                }
            },
            CPBarButton(title: "Keys") { [weak self] _ in
                self?.replaceMirroredSearch {
                    self?.openCustomKeyboard(session: session)
                }
            }
        ]
        mirroredResultsTemplate = list
        pushTemplate(list, kind: .search)

        NotificationCenter.default.post(name: .dromeFocusCarPlaySearch, object: nil)

        mirrorQueryObserver = NotificationCenter.default.addObserver(
            forName: .dromeCarPlaySearchQuery,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let query = (note.userInfo?["query"] as? String) ?? ""
            Task { @MainActor in
                await self?.updateMirroredResults(query: query, session: session)
            }
        }
    }

    private func stopMirrorSearch() {
        if let mirrorQueryObserver {
            NotificationCenter.default.removeObserver(mirrorQueryObserver)
            self.mirrorQueryObserver = nil
        }
        mirroredResultsTemplate = nil
    }

    private func updateMirroredResults(query: String, session: AppSession) async {
        guard let list = mirroredResultsTemplate else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else {
            let placeholder = CPListItem(
                text: "Type on your iPhone",
                detailText: "Search opens there — results appear here")
            list.updateSections([CPListSection(items: [placeholder])])
            return
        }

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let result = (try? await session.client.search(
                trimmed, artistCount: 12, albumCount: 12, songCount: 24))
                ?? SearchResult3(artist: nil, album: nil, song: nil)
            guard !Task.isCancelled else { return }
            let filtered = await self.filterSearchResult(result, session: session)
            list.updateSections(self.makeSearchSections(
                from: filtered, query: trimmed, session: session))
        }
    }

    /// Push Apple’s search template (native keyboard). Uses the completion
    /// handler so unsupported templates fail softly instead of throwing.
    private func pushSystemSearchTemplate(completion: @escaping (Bool) -> Void) {
        guard interfaceController != nil else {
            completion(false)
            return
        }
        let search = CPSearchTemplate()
        search.delegate = self
        searchTemplate = search
        searchSongs = [:]
        searchAlbums = [:]
        searchArtists = [:]

        // Prefer the completion-based API (no exception). Also wrap in the
        // ObjC catcher for older call paths that still throw.
        let ok = DromeExceptionCatcher.perform {
            self.pushTemplate(search, kind: .search) { success in
                if !success {
                    self.searchTemplate = nil
                }
                completion(success)
            }
        }
        if !ok {
            searchTemplate = nil
            completion(false)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1, let session = AppEnvironment.shared?.session else {
            searchSongs = [:]; searchAlbums = [:]; searchArtists = [:]
            completionHandler([])
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self else {
                completionHandler([])
                return
            }
            if Task.isCancelled {
                completionHandler([])
                return
            }

            let result = (try? await session.client.search(
                query, artistCount: 8, albumCount: 8, songCount: 12))
                ?? SearchResult3(artist: nil, album: nil, song: nil)
            guard !Task.isCancelled else {
                completionHandler([])
                return
            }

            let filtered = await self.filterSearchResult(result, session: session)
            // CPSearchTemplate is a flat list and only keeps a short prefix —
            // put artists/albums first so they aren't buried under songs.
            let items = self.makeFlatSearchItems(from: filtered, session: session, limit: 20)
            completionHandler(items)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let session = AppEnvironment.shared?.session else {
            completionHandler()
            return
        }
        let info = Self.searchUserInfo(from: item)
        guard let kind = info["kind"], let id = info["id"] else {
            completionHandler()
            return
        }

        Task { [weak self] in
            switch kind {
            case "song":
                if let song = self?.searchSongs[id] {
                    self?.playSongs([song], startAt: 0, label: song.title, kind: .search, session: session)
                }
            case "album":
                let name = self?.searchAlbums[id]?.name ?? "Album"
                await self?.showAlbum(
                    id: id,
                    name: name,
                    session: session,
                    coverArt: self?.searchAlbums[id]?.coverArt,
                    artist: self?.searchAlbums[id]?.artist,
                    year: self?.searchAlbums[id]?.year,
                    songCount: self?.searchAlbums[id]?.songCount)
            case "artist":
                let name = self?.searchArtists[id]?.name ?? "Artist"
                await self?.showArtist(
                    id: id,
                    name: name,
                    session: session,
                    coverArt: self?.searchArtists[id]?.coverArt)
            default:
                break
            }
            completionHandler()
        }
    }

    /// `userInfo` comes back as NSDictionary / [String: Any] — never cast straight to `[String: String]`.
    private static func searchUserInfo(from item: CPListItem) -> [String: String] {
        guard let raw = item.userInfo as? [AnyHashable: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            guard let key = key as? String else { continue }
            if let string = value as? String {
                out[key] = string
            } else {
                out[key] = "\(value)"
            }
        }
        return out
    }

    /// Flat results for `CPSearchTemplate` — artists & albums before songs, hard cap.
    private func makeFlatSearchItems(
        from result: SearchResult3,
        session: AppSession,
        limit: Int
    ) -> [CPListItem] {
        searchSongs = [:]
        searchAlbums = [:]
        searchArtists = [:]

        var items: [CPListItem] = []
        let artists = Self.artistsWithEmptyAlbumsLast(result.artists)
        let albums = result.albums
        let songs = result.songs

        for artist in artists {
            guard items.count < limit else { break }
            searchArtists[artist.id] = artist
            let item = listItem(
                text: artist.name,
                detail: artist.albumCount.map { "Artist · \($0) albums" } ?? "Artist",
                coverArt: artist.coverArt,
                fallbackId: artist.id,
                session: session,
                style: .artist)
            item.accessoryType = .disclosureIndicator
            item.userInfo = ["kind": "artist", "id": artist.id]
            items.append(item)
        }
        for album in albums {
            guard items.count < limit else { break }
            searchAlbums[album.id] = album
            let detail = [album.artist, "Album"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let item = listItem(
                text: album.name,
                detail: detail.isEmpty ? "Album" : detail,
                coverArt: album.coverArt,
                fallbackId: album.id,
                session: session,
                style: .album)
            item.accessoryType = .disclosureIndicator
            item.userInfo = ["kind": "album", "id": album.id]
            items.append(item)
        }
        for song in songs {
            guard items.count < limit else { break }
            searchSongs[song.id] = song
            let item = listItem(
                text: song.title,
                detail: song.displayArtist,
                coverArt: song.coverArt,
                fallbackId: song.albumId ?? song.id,
                session: session,
                style: .song)
            item.userInfo = ["kind": "song", "id": song.id]
            items.append(item)
        }
        return items
    }

    /// Sectioned results for list templates (mirrored phone / voice / letter pad).
    private func makeSearchSections(
        from result: SearchResult3,
        query: String,
        session: AppSession
    ) -> [CPListSection] {
        searchSongs = [:]
        searchAlbums = [:]
        searchArtists = [:]

        var sections: [CPListSection] = []

        let artists = Self.artistsWithEmptyAlbumsLast(result.artists)
        if !artists.isEmpty {
            let items: [CPListItem] = artists.map { artist in
                searchArtists[artist.id] = artist
                let item = listItem(
                    text: artist.name,
                    detail: artist.albumCount.map { "\($0) albums" } ?? "Artist",
                    coverArt: artist.coverArt,
                    fallbackId: artist.id,
                    session: session,
                    style: .artist)
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    Task {
                        await self?.showArtist(
                            id: artist.id,
                            name: artist.name,
                            session: session,
                            coverArt: artist.coverArt)
                        completion()
                    }
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Artists", sectionIndexTitle: nil))
        }

        let albums = result.albums
        if !albums.isEmpty {
            for album in albums { searchAlbums[album.id] = album }
            sections.append(CPListSection(
                items: albumItems(albums, session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }

        let songs = result.songs
        if !songs.isEmpty {
            for song in songs { searchSongs[song.id] = song }
            sections.append(CPListSection(
                items: songItems(songs, label: query, kind: .search, session: session),
                header: "Songs",
                sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            sections = [CPListSection(items: [
                CPListItem(text: "No results", detailText: "“\(query)”")
            ])]
        } else {
            CarPlayArtwork.prefetch(
                ids: (result.artists.map { $0.coverArt ?? $0.id }
                      + result.albums.map { $0.coverArt ?? $0.id }
                      + result.songs.prefix(12).map { $0.coverArt ?? $0.albumId ?? $0.id }),
                session: session)
        }
        return clampSections(sections)
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // Live results already refresh while typing / dictating.
    }

    private func presentSimpleAlert(title: String, message: String) {
        guard let interfaceController else { return }
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: ["\(title). \(message)"], actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func showSearchResults(query: String, session: AppSession, title: String) async {
        guard interfaceController != nil else { return }
        let result = (try? await session.client.search(
            query, artistCount: 12, albumCount: 12, songCount: 24))
            ?? SearchResult3(artist: nil, album: nil, song: nil)
        let filtered = await filterSearchResult(result, session: session)
        let sections = makeSearchSections(from: filtered, query: query, session: session)
        let list = CPListTemplate(title: title, sections: sections)
        pushTemplate(list, kind: .search)
    }

    // MARK: - Podcasts

    private func makePodcastsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Podcasts", sections: clampSections([
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ]))
        template.tabTitle = "Podcasts"
        template.tabImage = UIImage(systemName: "headphones")

        Task { @MainActor in
            self.applySections(self.podcastSections(), to: template)
        }
        return template
    }

    private func podcastSections() -> [CPListSection] {
        guard let env = AppEnvironment.shared else {
            return [CPListSection(items: [
                CPListItem(text: "Open Drome on iPhone", detailText: "Podcasts sync from your phone")
            ])]
        }
        let manager = env.podcastManager
        let player = env.podcastPlayer
        var sections: [CPListSection] = []

        if let current = player.currentEpisode {
            let detail: String
            if player.isPlaying {
                detail = "Playing · tap for Now Playing"
            } else {
                detail = "Paused · tap to resume"
            }
            let row = CPListItem(text: current.title, detailText: detail)
            if let image = UIImage(systemName: "play.circle.fill") {
                row.setImage(image)
            }
            row.handler = { [weak self] _, completion in
                if player.currentEpisode?.id == current.id, !player.isPlaying {
                    player.resume()
                }
                self?.pushNowPlaying()
                self?.refreshNowPlayingButtons()
                completion()
            }
            sections.append(CPListSection(
                items: [row], header: "Now Playing", sectionIndexTitle: nil))
        }

        let inProgress = manager.inProgressEpisodes()
        if !inProgress.isEmpty {
            let cap = listsLimited ? CarPlayListPolicy.limitedListItemCap : 12
            let items: [CPListItem] = inProgress.prefix(cap).map { entry in
                let remaining = entry.episode.remainingText ?? entry.episode.durationText
                let item = CPListItem(
                    text: entry.episode.title,
                    detailText: remaining)
                item.handler = { [weak self] _, completion in
                    player.play(entry.episode, resumeFromSaved: true)
                    self?.pushNowPlaying()
                    self?.refreshNowPlayingButtons()
                    completion()
                }
                return item
            }
            sections.append(CPListSection(
                items: Array(items), header: "Continue Listening", sectionIndexTitle: nil))
        }

        let shows = manager.subscribedShows
        if shows.isEmpty {
            sections.append(CPListSection(items: [
                CPListItem(
                    text: "No subscriptions yet",
                    detailText: "Subscribe on your iPhone")
            ], header: "Shows", sectionIndexTitle: nil))
        } else {
            let cap = listLimits.maxItems
            let items: [CPListItem] = shows.prefix(cap).map { show in
                let item = CPListItem(
                    text: show.title,
                    detailText: show.author ?? "\(show.episodeCount) episodes")
                item.accessoryType = .disclosureIndicator
                if let image = UIImage(systemName: "mic.fill") {
                    item.setImage(image)
                }
                item.handler = { [weak self] _, completion in
                    self?.showPodcastEpisodes(show: show, manager: manager, player: player)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(
                items: Array(items), header: "Shows", sectionIndexTitle: nil))
        }
        return sections
    }

    private func showPodcastEpisodes(
        show: PodcastShow,
        manager: PodcastManager,
        player: PodcastPlayer
    ) {
        guard interfaceController != nil else { return }
        let episodes = (try? manager.episodes(for: show.feedURL)) ?? []
        let cap = min(listLimits.maxItems, CarPlayListPolicy.detailTrackCap)
        let items: [CPListItem] = episodes.prefix(cap).map { episode in
            var detailParts: [String] = []
            if let remaining = episode.remainingText, episode.playbackPosition > 1 {
                detailParts.append(remaining)
            } else {
                detailParts.append(episode.durationText)
            }
            if episode.isFullyPlayed { detailParts.append("Played") }
            let item = CPListItem(
                text: episode.title,
                detailText: detailParts.joined(separator: " · "))
            item.handler = { [weak self] _, completion in
                player.play(episode, resumeFromSaved: true)
                self?.pushNowPlaying()
                self?.refreshNowPlayingButtons()
                completion()
            }
            return item
        }
        let list = CPListTemplate(
            title: show.title,
            sections: clampSections([CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "No episodes", detailText: "Refresh on iPhone")]
                                     : Array(items))]))
        pushTemplate(list, kind: .detail)
    }

    // MARK: - Library

    private func makeLibraryTemplate(session: AppSession) -> CPListTemplate {
        // Match iPhone “Your Library” naming + SF Symbol tab image.
        let template = CPListTemplate(title: "Your Library", sections: clampSections([
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ]))
        template.tabTitle = "Your Library"
        template.tabImage = UIImage(systemName: "rectangle.stack.fill")

        if CarPlayHomeCache.playlistsFresh {
            applySections(
                buildLibrarySections(session: session, lists: CarPlayHomeCache.cachedPlaylists, error: false),
                to: template)
        }
        reloadLibrary(template: template, session: session)
        return template
    }

    private func reloadLibrary(template: CPListTemplate, session: AppSession) {
        libraryLoadTask?.cancel()
        libraryLoadTask = Task { [weak self] in
            guard let self else { return }
            let lists: [Playlist]
            let failed: Bool
            if CarPlayHomeCache.playlistsFresh {
                lists = CarPlayHomeCache.cachedPlaylists
                failed = false
            } else {
                do {
                    lists = try await session.client.playlists()
                    CarPlayHomeCache.storePlaylists(lists)
                    failed = false
                } catch {
                    lists = CarPlayHomeCache.cachedPlaylists
                    failed = lists.isEmpty
                }
            }
            guard !Task.isCancelled else { return }
            let sections = self.buildLibrarySections(
                session: session, lists: lists, error: failed, libraryTemplate: template)
            self.applySections(sections, to: template)
        }
    }

    private func buildLibrarySections(
        session: AppSession,
        lists: [Playlist],
        error: Bool,
        libraryTemplate: CPListTemplate? = nil
    ) -> [CPListSection] {
        // Structure comes from CarPlayListPolicy.buildLibrarySpec (same as XCTest).
        let userKey = session.account.userKey
        let visibleLists = lists.filter {
            !PlaylistOrderStore.isHidden($0.id, userKey: userKey)
        }
        let newest = CarPlayHomeCache.cachedNewest
        // Browse actions + optional Recently Added image row take slots first.
        let reserved = 7 + (newest.isEmpty ? 0 : 1)
        let playlistCap = min(
            max(0, listLimits.maxItems - reserved),
            listsLimited ? CarPlayListPolicy.limitedListItemCap : CarPlayListPolicy.libraryBrowseCap)
        let input = CarPlayListPolicy.LibraryInput(
            serverError: error,
            playlists: visibleLists.map { CarPlayListPolicy.PlaylistRef(id: $0.id, title: $0.name) },
            downloadedCount: session.downloads.downloadedCount,
            newestTitles: newest.map(\.name))
        let spec = CarPlayListPolicy.buildLibrarySpec(input, playlistCap: playlistCap)
        let clamped = CarPlayListPolicy.clamp(spec.sections, limits: listLimits)

        if error {
            return [serverErrorSection { [weak self] in
                if let libraryTemplate {
                    self?.reloadLibrary(template: libraryTemplate, session: session)
                }
            }]
        }

        // Match by stable id / role — never by display title (Navidrome allows
        // duplicate playlist names; a playlist can also be named "Albums").
        let byID = Dictionary(uniqueKeysWithValues: visibleLists.map { ($0.id, $0) })
        let perRow = max(1, Int(CPMaximumNumberOfGridImages))
        var sections: [CPListSection] = []
        for section in clamped {
            let hideRowText = section.header != nil
            var items: [CPListTemplateItem] = []
            for item in section.items {
                switch item.role {
                case .shuffleLibrary:
                    let row = actionItem(
                        title: item.title,
                        detail: item.subtitle,
                        systemImage: "shuffle")
                    row.handler = { [weak self] _, completion in
                        Task {
                            await self?.playShuffleAll(session: session)
                            completion()
                        }
                    }
                    items.append(row)
                case .browseDownloaded:
                    let row = libraryShortcut(
                        title: item.title,
                        detail: item.subtitle ?? "",
                        systemImage: "arrow.down.circle.fill")
                    row.handler = { [weak self] _, completion in
                        self?.showDownloads(session: session)
                        completion()
                    }
                    items.append(row)
                case .browseArtists:
                    let row = libraryShortcut(
                        title: item.title, detail: item.subtitle ?? "",
                        systemImage: "person.2.fill")
                    row.handler = { [weak self] _, completion in
                        Task {
                            await self?.showArtistsBrowse(session: session)
                            completion()
                        }
                    }
                    items.append(row)
                case .browseAlbums:
                    let row = libraryShortcut(
                        title: item.title, detail: item.subtitle ?? "",
                        systemImage: "square.stack.fill")
                    row.handler = { [weak self] _, completion in
                        Task {
                            await self?.showAlbumsBrowse(session: session)
                            completion()
                        }
                    }
                    items.append(row)
                case .browseTopRated:
                    let row = libraryShortcut(
                        title: item.title, detail: item.subtitle ?? "",
                        systemImage: "star.fill")
                    row.handler = { [weak self] _, completion in
                        Task {
                            await self?.showTopRatedFlat(session: session)
                            completion()
                        }
                    }
                    items.append(row)
                case .browseSmartPlaylists:
                    let row = libraryShortcut(
                        title: item.title, detail: item.subtitle ?? "",
                        systemImage: "wand.and.stars")
                    row.handler = { [weak self] _, completion in
                        self?.showSmartPlaylists(session: session)
                        completion()
                    }
                    items.append(row)
                case .browseGenres:
                    let row = libraryShortcut(
                        title: item.title, detail: item.subtitle ?? "",
                        systemImage: "guitars")
                    row.handler = { [weak self] _, completion in
                        Task {
                            await self?.showGenres(session: session)
                            completion()
                        }
                    }
                    items.append(row)
                case .recentlyAdded:
                    let albums = Array(newest.prefix(CarPlayListPolicy.libraryNewestTiles))
                    items.append(contentsOf: coverGridRows(
                        titles: albums.map(\.name),
                        style: .album,
                        rowText: hideRowText ? nil : item.title,
                        perRow: perRow,
                        session: session,
                        covers: { albums.map { ($0.name, $0.coverArt, $0.id) } },
                        onTile: { [weak self] index in
                            guard albums.indices.contains(index) else { return }
                            let album = albums[index]
                            Task {
                                await self?.showAlbum(
                                    id: album.id, name: album.name, session: session,
                                    coverArt: album.coverArt, artist: album.artist,
                                    year: album.year, songCount: album.songCount)
                            }
                        },
                        onRow: { [weak self] in
                            self?.showAlbumList(
                                albums, title: "Recently Added", session: session)
                        }))
                case .emptyPlaylists, .message:
                    items.append(CPListItem(text: item.title, detailText: item.subtitle))
                case .playlist:
                    if let id = item.id, let playlist = byID[id] {
                        items.append(contentsOf: playlistItems([playlist], session: session))
                    } else {
                        items.append(CPListItem(text: item.title, detailText: item.subtitle))
                    }
                case .retry, .action, .imageRow:
                    items.append(CPListItem(text: item.title, detailText: item.subtitle))
                }
            }
            if !items.isEmpty {
                sections.append(CPListSection(
                    items: items, header: section.header, sectionIndexTitle: nil))
            }
        }
        return sections
    }

    private func libraryShortcut(title: String, detail: String, systemImage: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.accessoryType = .disclosureIndicator
        if let image = UIImage(systemName: systemImage) {
            item.setImage(image)
        }
        return item
    }

    private func showDownloads(session: AppSession) {
        guard interfaceController != nil else { return }
        let songs = session.downloads.downloadedSongs()
            .sorted {
                ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending
            }
        if songs.isEmpty {
            let empty = CPListTemplate(title: "Downloaded", sections: clampSections([
                emptySection(title: "No downloads", detail: "Download music on your iPhone")
            ]))
            pushTemplate(empty, kind: .browse)
            return
        }

        let grouped = Dictionary(grouping: songs) { $0.album?.isEmpty == false ? ($0.album ?? "Tracks") : "Tracks" }
        let limits = listLimits
        var remaining = limits.maxItems
        var sections: [CPListSection] = []
        for name in grouped.keys.sorted().prefix(limits.maxSections) {
            guard remaining > 0 else { break }
            let albumSongs = Array((grouped[name] ?? []).prefix(remaining))
            let items = songItems(albumSongs, label: name, kind: .mix, session: session)
            sections.append(CPListSection(items: items, header: name, sectionIndexTitle: nil))
            remaining -= items.count
        }
        let list = CPListTemplate(title: "Downloaded", sections: clampSections(sections))
        pushTemplate(list, kind: .browse)
    }

    /// Flattened Top Rated — one screen with 5★ / 4★ / albums (no menu → collection → … chain).
    private func showSmartPlaylists(session: AppSession) {
        let definitions = SmartPlaylistCatalog.builtIn
        let items: [CPListItem] = definitions.map { definition in
            let item = listItem(
                text: definition.name,
                detail: definition.subtitle,
                coverArt: nil,
                fallbackId: definition.id,
                session: session,
                style: .playlist)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.playSmartPlaylist(definition, session: session)
                    completion()
                }
            }
            item.accessoryType = .disclosureIndicator
            return item
        }
        let list = CPListTemplate(
            title: "Smart Playlists",
            sections: clampSections([CPListSection(items: items)]))
        pushTemplate(list, kind: .browse)
    }

    private func playSmartPlaylist(
        _ definition: SmartPlaylistDefinition,
        session: AppSession
    ) async {
        let songs = SmartPlaylistEngine.evaluate(
            definition: definition,
            userKey: session.account.userKey,
            database: session.database,
            downloads: session.downloads)
        guard !songs.isEmpty else {
            presentSimpleAlert(
                title: definition.name,
                message: "Nothing matches this smart playlist yet.")
            return
        }
        playSongs(
            songs, startAt: 0, label: definition.name, kind: .mix, session: session)
    }

    private func showTopRatedFlat(session: AppSession) async {
        guard interfaceController != nil else { return }

        let five = session.ratings.cachedSongs(minRating: 5)
        let fourPlus = session.ratings.cachedSongs(minRating: 4)
        let albums: [Album]
        do {
            albums = try await session.client.albumList(type: .highest, size: 40)
                .filter { ($0.userRating ?? 0) > 0 }
        } catch {
            albums = []
        }

        var sections: [CPListSection] = []
        let songCap = listsLimited ? 6 : 12

        if !five.isEmpty {
            let playable = Array(five.prefix(songCap))
            var items: [CPListItem] = []
            let play = actionItem(title: "Play 5 Stars", detail: "\(five.count) songs", systemImage: "play.fill")
            play.handler = { [weak self] _, completion in
                self?.playSongs(five, startAt: 0, label: "5 Stars", kind: .mix, session: session)
                completion()
            }
            items.append(play)
            items.append(contentsOf: songItems(playable, label: "5 Stars", kind: .mix, session: session))
            sections.append(CPListSection(items: items, header: "5 Stars", sectionIndexTitle: nil))
        }

        if !fourPlus.isEmpty {
            let playable = Array(fourPlus.prefix(songCap))
            var items: [CPListItem] = []
            let play = actionItem(title: "Play 4★ & Up", detail: "\(fourPlus.count) songs", systemImage: "play.fill")
            play.handler = { [weak self] _, completion in
                self?.playSongs(fourPlus, startAt: 0, label: "4 Stars & Up", kind: .mix, session: session)
                completion()
            }
            items.append(play)
            items.append(contentsOf: songItems(playable, label: "4 Stars & Up", kind: .mix, session: session))
            sections.append(CPListSection(items: items, header: "4 Stars & Up", sectionIndexTitle: nil))
        }

        if !albums.isEmpty {
            let capped = Array(albums.prefix(songCap))
            sections.append(CPListSection(
                items: albumItems(capped, session: session),
                header: "Top Rated Albums",
                sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            sections = [emptySection(
                title: "Nothing here yet",
                detail: "Rate tracks on your iPhone or Now Playing")]
        }

        let list = CPListTemplate(title: "Top Rated", sections: clampSections(sections))
        pushTemplate(list, kind: .browse)
    }

    private func showGenres(
        session: AppSession,
        updating existing: CPListTemplate? = nil
    ) async {
        guard interfaceController != nil else { return }

        let list: CPListTemplate
        if let existing {
            list = existing
        } else {
            list = CPListTemplate(title: "Genres", sections: clampSections([
                CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
            ]))
            pushTemplate(list, kind: .browse)
        }

        let raw: [Genre]
        do {
            raw = try await session.client.genres()
        } catch {
            applySections([serverErrorSection { [weak self] in
                Task { await self?.showGenres(session: session, updating: list) }
            }], to: list)
            return
        }
        let genres = GenreNormalizer.shared.groupedGenres(raw)
        let items: [CPListItem] = genres.prefix(listLimits.maxItems).map { genre in
            let detail: String
            if genre.songCount > 0 {
                detail = "\(genre.songCount) songs"
            } else if genre.albumCount > 0 {
                detail = "\(genre.albumCount) albums"
            } else {
                detail = "Genre"
            }
            let item = CPListItem(text: genre.displayName, detailText: detail)
            item.accessoryType = .disclosureIndicator
            if let image = UIImage(systemName: "guitars") {
                item.setImage(image)
            }
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showGenre(genre, session: session)
                    completion()
                }
            }
            return item
        }
        applySections([
            CPListSection(items: items.isEmpty
                          ? [CPListItem(text: "No genres", detailText: nil)]
                          : Array(items))
        ], to: list)
    }

    private func showGenre(_ genre: NormalizedGenre, session: AppSession) async {
        guard interfaceController != nil else { return }
        var songs: [Song] = []
        var albums: [Album] = []
        await withTaskGroup(of: (albums: [Album], songs: [Song]).self) { group in
            for tag in genre.rawTags {
                group.addTask {
                    let a = (try? await session.client.albumList(type: .byGenre, size: 40, genre: tag)) ?? []
                    let s = (try? await session.client.songsByGenre(tag)) ?? []
                    return (a, s)
                }
            }
            var albumById: [String: Album] = [:]
            var songById: [String: Song] = [:]
            for await result in group {
                for album in result.albums { albumById[album.id] = album }
                for song in result.songs { songById[song.id] = song }
            }
            albums = Array(albumById.values).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            songs = Array(songById.values).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        var sections: [CPListSection] = []
        if !songs.isEmpty {
            let playable = Array(songs.prefix(40))
            var items: [CPListItem] = []
            let play = CPListItem(text: "Play", detailText: "\(playable.count) songs")
            play.handler = { [weak self] _, completion in
                self?.playSongs(playable, startAt: 0, label: genre.displayName, kind: .genre, session: session)
                completion()
            }
            items.append(play)
            items.append(contentsOf: songItems(playable, label: genre.displayName, kind: .genre, session: session))
            sections.append(CPListSection(items: items, header: "Songs", sectionIndexTitle: nil))
        }
        if !albums.isEmpty {
            sections.append(CPListSection(
                items: albumItems(Array(albums.prefix(40)), session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            sections = [emptySection(title: "Nothing found", detail: "No songs or albums for this genre")]
        }
        let list = CPListTemplate(title: genre.displayName, sections: clampSections(sections))
        pushTemplate(list, kind: .detail)
    }

    // MARK: - Shared detail screens

    private func playlistItems(_ playlists: [Playlist], session: AppSession) -> [CPListItem] {
        playlists.map { playlist in
            let item = listItem(
                text: playlist.name,
                detail: playlist.songCountLabel,
                coverArt: playlist.coverArt,
                fallbackId: playlist.id,
                session: session,
                style: .playlist)
            item.accessoryType = .disclosureIndicator
            if session.downloads.isPlaylistFullyDownloaded(
                playlistId: playlist.id, expectedCount: playlist.songCount ?? 0)
            {
                item.setAccessoryImage(UIImage(systemName: "arrow.down.circle.fill"))
            }
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showPlaylist(
                        id: playlist.id,
                        name: playlist.name,
                        coverArt: playlist.coverArt,
                        session: session)
                    completion()
                }
            }
            return item
        }
    }

    private func albumItems(_ albums: [Album], session: AppSession) -> [CPListItem] {
        // Warm covers so the next page / this list fills in immediately.
        CarPlayArtwork.prefetch(
            ids: albums.map { $0.coverArt ?? $0.id },
            session: session)

        return albums.map { album in
            let item = listItem(
                text: album.name,
                detail: album.artist,
                coverArt: album.coverArt,
                fallbackId: album.id,
                session: session,
                style: .album)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbum(
                        id: album.id,
                        name: album.name,
                        session: session,
                        coverArt: album.coverArt,
                        artist: album.artist,
                        year: album.year,
                        songCount: album.songCount)
                    completion()
                }
            }
            return item
        }
    }

    private func songItems(_ songs: [Song], label: String,
                           kind: PlaybackContext.Kind, session: AppSession) -> [CPListItem] {
        CarPlayArtwork.prefetch(
            ids: songs.prefix(24).map { $0.coverArt ?? $0.albumId ?? $0.id },
            session: session)

        return songs.enumerated().map { index, song in
            let item = listItem(
                text: song.title,
                detail: song.artist,
                coverArt: song.coverArt,
                fallbackId: song.albumId ?? song.id,
                session: session,
                style: .song)
            item.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: index, label: label, kind: kind, session: session)
                completion()
            }
            return item
        }
    }

    private func showAlbum(
        id: String,
        name: String,
        session: AppSession,
        coverArt: String? = nil,
        artist: String? = nil,
        year: Int? = nil,
        songCount: Int? = nil,
        updating existing: CPListTemplate? = nil
    ) async {
        guard let interfaceController else { return }

        let cached = LibraryDetailCache.album(id)
        // Instant shell with artwork so the page never opens blank.
        let shell = cached ?? AlbumWithSongs(
            id: id,
            name: name,
            artist: artist,
            artistId: nil,
            coverArt: coverArt,
            songCount: songCount,
            duration: nil,
            year: year,
            genre: nil,
            userRating: nil,
            song: [])

        let placeholder: CPListTemplate
        if let existing {
            placeholder = existing
            applySections(albumDetailSections(
                album: shell,
                fallbackName: name,
                loading: cached == nil || (cached?.songs.isEmpty ?? true),
                session: session), to: placeholder)
        } else {
            placeholder = CPListTemplate(
                title: name,
                sections: albumDetailSections(
                    album: shell,
                    fallbackName: name,
                    loading: cached == nil || (cached?.songs.isEmpty ?? true),
                    session: session))
            pushTemplate(placeholder, kind: .detail)
        }

        // Prefetch the hero cover at CarPlay size right away.
        CarPlayArtwork.prefetch(ids: [coverArt ?? id], session: session, limit: 1)

        let album: AlbumWithSongs
        if let fresh = try? await session.client.album(id: id) {
            LibraryDetailCache.store(album: fresh)
            album = fresh
        } else if let cached {
            album = cached
        } else {
            let retry = CPListItem(text: "Retry", detailText: "Try loading again")
            if let image = UIImage(systemName: "arrow.clockwise") {
                retry.setImage(image)
            }
            retry.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbum(
                        id: id, name: name, session: session,
                        coverArt: coverArt, artist: artist, year: year, songCount: songCount,
                        updating: placeholder)
                    completion()
                }
            }
            applySections([CPListSection(items: [
                albumHeroItem(shell, session: session, loading: false, playable: false),
                CPListItem(text: "Couldn't load album", detailText: "Check Wi‑Fi or try again"),
                retry
            ])], to: placeholder)
            return
        }

        applySections(albumDetailSections(
            album: album, fallbackName: name, loading: false, session: session), to: placeholder)
    }

    private func albumDetailSections(
        album: AlbumWithSongs?,
        fallbackName: String,
        loading: Bool,
        session: AppSession
    ) -> [CPListSection] {
        guard let album else {
            let item = CPListItem(
                text: loading ? fallbackName : "Album unavailable",
                detailText: loading ? "Loading…" : nil)
            CarPlayArtwork.attach(
                to: item, coverArt: nil, fallbackId: nil, session: session, style: .album)
            return [CPListSection(items: [item])]
        }

        let songs = album.songs
        let kind = PlaybackContext.Kind.album(id: album.id)
        var sections: [CPListSection] = []

        // Hero is informational only — Play + Shuffle are the actions (no duplicate hero Play).
        var headerItems: [CPListItem] = [
            albumHeroItem(album, session: session, loading: loading && songs.isEmpty, playable: false)
        ]

        if !songs.isEmpty {
            let play = actionItem(
                title: "Play",
                detail: albumActionSubtitle(album),
                systemImage: "play.fill",
                coverArt: album.coverArt,
                fallbackId: album.id,
                session: session,
                style: .album)
            play.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: 0, label: album.name, kind: kind, session: session)
                completion()
            }
            headerItems.append(play)

            let shuffle = actionItem(
                title: "Shuffle",
                detail: "\(songs.count) songs",
                systemImage: "shuffle")
            shuffle.handler = { [weak self] _, completion in
                session.player.playShuffled(
                    songs, context: PlaybackContext(label: album.name, kind: kind))
                self?.pushNowPlaying()
                completion()
            }
            headerItems.append(shuffle)
        } else if loading {
            let loadingRow = CPListItem(text: "Loading tracks…", detailText: "Almost ready")
            if let image = UIImage(systemName: "ellipsis") {
                loadingRow.setImage(image)
            }
            headerItems.append(loadingRow)
        }

        // Omit when the stack is already at the CarPlay max — pushing artist
        // (or artist→album again) would exceed depth 5 / loop unboundedly.
        if canPushOrReplaceDetail,
           let artistId = album.artistId, !artistId.isEmpty,
           let artistName = album.artist, !artistName.isEmpty {
            let artist = actionItem(
                title: artistName,
                detail: "Go to artist",
                systemImage: "person.fill")
            artist.accessoryType = .disclosureIndicator
            artist.handler = { [weak self] _, completion in
                Task {
                    await self?.showArtist(
                        id: artistId, name: artistName, session: session)
                    completion()
                }
            }
            headerItems.append(artist)
        }

        sections.append(CPListSection(items: headerItems, header: nil, sectionIndexTitle: nil))

        guard !songs.isEmpty else { return sections }

        let discs = Dictionary(grouping: songs) { $0.discNumber ?? 1 }
        let discKeys = discs.keys.sorted()
        let multiDisc = discKeys.count > 1

        var remaining = max(0, listLimits.maxItems - headerItems.count)
        for disc in discKeys {
            guard remaining > 0 else { break }
            let discSongs = (discs[disc] ?? []).sorted {
                ($0.track ?? 0) < ($1.track ?? 0)
            }
            let capped = Array(discSongs.prefix(remaining))
            let header = multiDisc ? "Disc \(disc)" : "Tracks"
            sections.append(CPListSection(
                items: albumTrackItems(capped, album: album, session: session),
                header: header,
                sectionIndexTitle: nil))
            remaining -= capped.count
        }
        return clampSections(sections)
    }

    private func albumHeroItem(
        _ album: AlbumWithSongs,
        session: AppSession,
        loading: Bool,
        playable: Bool
    ) -> CPListItem {
        var detailParts: [String] = []
        if let artist = album.artist, !artist.isEmpty { detailParts.append(artist) }
        if loading {
            detailParts.append("Loading…")
        } else {
            let meta = albumActionSubtitle(album)
            if meta != "Album" { detailParts.append(meta) }
        }
        let item = CPListItem(
            text: album.name,
            detailText: detailParts.isEmpty ? "Album" : detailParts.joined(separator: " · "))
        CarPlayArtwork.attach(
            to: item,
            coverArt: album.coverArt,
            fallbackId: album.id,
            session: session,
            style: .album)
        if playable, !album.songs.isEmpty {
            let songs = album.songs
            let kind = PlaybackContext.Kind.album(id: album.id)
            item.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: 0, label: album.name, kind: kind, session: session)
                completion()
            }
        }
        return item
    }

    private func albumActionSubtitle(_ album: AlbumWithSongs) -> String {
        var parts: [String] = []
        if !album.songs.isEmpty {
            parts.append("\(album.songs.count) song\(album.songs.count == 1 ? "" : "s")")
        } else if let count = album.songCount, count > 0 {
            parts.append("\(count) songs")
        }
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre, !genre.isEmpty { parts.append(genre) }
        return parts.isEmpty ? "Album" : parts.joined(separator: " · ")
    }

    private func albumTrackItems(
        _ songs: [Song],
        album: AlbumWithSongs,
        session: AppSession
    ) -> [CPListItem] {
        let kind = PlaybackContext.Kind.album(id: album.id)
        return songs.enumerated().map { index, song in
            let trackNo = song.track.map(String.init) ?? "\(index + 1)"
            let detailParts = [song.durationText].filter { !$0.isEmpty && $0 != "0:00" }
            let item = CPListItem(
                text: song.title,
                detailText: detailParts.isEmpty ? trackNo : "\(trackNo) · \(detailParts.joined())")
            // Album page: track numbers stay glanceable; hero carries the cover.
            item.handler = { [weak self] _, completion in
                self?.playSongs(
                    album.songs, startAt: album.songs.firstIndex(where: { $0.id == song.id }) ?? index,
                    label: album.name, kind: kind, session: session)
                completion()
            }
            return item
        }
    }

    private func showArtist(
        id: String,
        name: String,
        session: AppSession,
        coverArt: String? = nil,
        updating existing: CPListTemplate? = nil
    ) async {
        guard let interfaceController else { return }

        let cached = LibraryDetailCache.artist(id)
        let shellArtist = cached?.artist ?? ArtistWithAlbums(
            id: id,
            name: name,
            coverArt: coverArt,
            artistImageUrl: nil,
            albumCount: nil,
            album: nil)

        let placeholder: CPListTemplate
        if let existing {
            placeholder = existing
            applySections(artistDetailSections(
                artist: shellArtist,
                topSongs: cached?.topSongs ?? [],
                fallbackName: name,
                loading: cached == nil,
                session: session), to: placeholder)
        } else {
            placeholder = CPListTemplate(
                title: name,
                sections: artistDetailSections(
                    artist: shellArtist,
                    topSongs: cached?.topSongs ?? [],
                    fallbackName: name,
                    loading: cached == nil,
                    session: session))
            pushTemplate(placeholder, kind: .detail)
        }
        CarPlayArtwork.prefetch(ids: [coverArt ?? id], session: session, limit: 1)

        async let artistTask = session.client.artist(id: id)
        async let topTask = session.client.topSongs(artistName: name, count: 20)

        let artist = try? await artistTask
        let topSongs = (try? await topTask) ?? []

        if let artist {
            LibraryDetailCache.store(artist: artist, topSongs: topSongs, owned: cached?.owned ?? [])
            applySections(artistDetailSections(
                artist: artist,
                topSongs: topSongs,
                fallbackName: name,
                loading: false,
                session: session), to: placeholder)
            CarPlayArtwork.prefetch(
                ids: artist.albums.map { $0.coverArt ?? $0.id },
                session: session)
        } else if cached == nil {
            let retry = CPListItem(text: "Retry", detailText: "Try loading again")
            if let image = UIImage(systemName: "arrow.clockwise") {
                retry.setImage(image)
            }
            retry.handler = { [weak self] _, completion in
                Task {
                    await self?.showArtist(
                        id: id, name: name, session: session,
                        coverArt: coverArt, updating: placeholder)
                    completion()
                }
            }
            applySections([CPListSection(items: [
                artistHeroItem(shellArtist, session: session, loading: false),
                CPListItem(text: "Couldn't load artist", detailText: "Check Wi‑Fi or try again"),
                retry
            ])], to: placeholder)
        } else if !topSongs.isEmpty {
            LibraryDetailCache.store(
                artist: cached!.artist, topSongs: topSongs, owned: cached?.owned ?? [])
            applySections(artistDetailSections(
                artist: cached?.artist,
                topSongs: topSongs,
                fallbackName: name,
                loading: false,
                session: session), to: placeholder)
        }
    }

    private func artistDetailSections(
        artist: ArtistWithAlbums?,
        topSongs: [Song],
        fallbackName: String,
        loading: Bool,
        session: AppSession
    ) -> [CPListSection] {
        let artistId = artist?.id
        let artistName = artist?.name ?? fallbackName
        let albums = artist?.albums ?? []
        let popular = Array(topSongs.prefix(8))
        let kind: PlaybackContext.Kind = artistId.map { .artist(id: $0) } ?? .mix

        var sections: [CPListSection] = []
        var headerItems: [CPListItem] = []

        if let artist {
            headerItems.append(artistHeroItem(artist, session: session, loading: loading && popular.isEmpty && albums.isEmpty))
        }

        if !popular.isEmpty {
            let play = actionItem(
                title: "Play Popular",
                detail: "\(popular.count) songs",
                systemImage: "play.fill",
                coverArt: popular.first?.coverArt,
                fallbackId: popular.first?.albumId ?? popular.first?.id,
                session: session,
                style: .song)
            play.handler = { [weak self] _, completion in
                self?.playSongs(popular, startAt: 0, label: artistName, kind: kind, session: session)
                completion()
            }
            headerItems.append(play)

            let shuffle = actionItem(
                title: "Shuffle Popular",
                detail: nil,
                systemImage: "shuffle")
            shuffle.handler = { [weak self] _, completion in
                session.player.playShuffled(
                    popular, context: PlaybackContext(label: artistName, kind: kind))
                self?.pushNowPlaying()
                completion()
            }
            headerItems.append(shuffle)
        } else if loading {
            let loadingRow = CPListItem(text: "Loading…", detailText: "Popular songs & albums")
            if let image = UIImage(systemName: "ellipsis") {
                loadingRow.setImage(image)
            }
            headerItems.append(loadingRow)
        } else if !albums.isEmpty {
            let browse = actionItem(
                title: "\(albums.count) albums",
                detail: "In your library",
                systemImage: "square.stack.fill")
            browse.handler = { _, completion in completion() }
            headerItems.append(browse)
        }

        if headerItems.isEmpty {
            headerItems = [CPListItem(text: "Nothing found", detailText: "No songs or albums yet")]
        }
        sections.append(CPListSection(items: headerItems, header: nil, sectionIndexTitle: nil))

        if !popular.isEmpty {
            let items = popular.enumerated().map { index, song -> CPListItem in
                let item = listItem(
                    text: song.title,
                    detail: song.album,
                    coverArt: song.coverArt,
                    fallbackId: song.albumId ?? song.id,
                    session: session,
                    style: .song)
                item.handler = { [weak self] _, completion in
                    self?.playSongs(popular, startAt: index, label: artistName, kind: kind, session: session)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Popular", sectionIndexTitle: nil))
        }

        if !albums.isEmpty {
            let sorted = albums.sorted { lhs, rhs in
                let ly = lhs.year ?? 0
                let ry = rhs.year ?? 0
                if ly != ry { return ly > ry }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            let cap = max(0, listLimits.maxItems - sections.reduce(0) { $0 + $1.items.count })
            sections.append(CPListSection(
                items: artistAlbumItems(Array(sorted.prefix(cap)), session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }

        return clampSections(sections)
    }

    private func artistHeroItem(
        _ artist: ArtistWithAlbums,
        session: AppSession,
        loading: Bool
    ) -> CPListItem {
        var detailParts: [String] = []
        if let count = artist.albumCount, count > 0 {
            detailParts.append("\(count) albums")
        } else if !artist.albums.isEmpty {
            detailParts.append("\(artist.albums.count) albums")
        }
        if loading { detailParts.append("Loading…") }
        let item = CPListItem(
            text: artist.name,
            detailText: detailParts.isEmpty ? "Artist" : detailParts.joined(separator: " · "))
        CarPlayArtwork.attach(
            to: item,
            coverArt: artist.coverArt,
            fallbackId: artist.id,
            session: session,
            style: .artist)
        return item
    }

    private func artistAlbumItems(_ albums: [Album], session: AppSession) -> [CPListItem] {
        albumItems(albums, session: session)
    }

    private func showArtistsBrowse(
        session: AppSession,
        updating existing: CPListTemplate? = nil
    ) async {
        guard let interfaceController else { return }

        func presentError(_ template: CPListTemplate) {
            applySections([serverErrorSection { [weak self] in
                Task { await self?.showArtistsBrowse(session: session, updating: template) }
            }], to: template)
        }

        let list: CPListTemplate
        if let existing {
            list = existing
        } else {
            list = CPListTemplate(title: "Artists", sections: clampSections([
                CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
            ]))
            pushTemplate(list, kind: .browse)
        }

        let indexes: [ArtistIndex]
        do {
            indexes = try await session.client.artists()
        } catch {
            presentError(list)
            return
        }
        let artists = await filteredBrowseArtists(indexes.flatMap(\.artists), session: session)
        // Full A–Z — index pages in place so late letters stay reachable under Limit UI.
        let buckets = CarPlayListPolicy.letterBuckets(artists, name: { $0.name })
        CarPlayArtwork.prefetch(
            ids: artists.prefix(40).map { $0.coverArt ?? $0.id },
            session: session)

        if buckets.isEmpty {
            applySections([
                emptySection(title: "No artists", detail: "Sync your library on iPhone")
            ], to: list)
            return
        }

        applyArtistLetterIndex(buckets, onto: list, session: session, offset: 0)
    }

    /// Letter index for artists. `More…` / `← Previous` update in place (no extra depth).
    private func applyArtistLetterIndex(
        _ buckets: [(letter: String, items: [Artist])],
        onto list: CPListTemplate,
        session: AppSession,
        offset: Int
    ) {
        // Reserve rows for Previous and/or More when present.
        let pageSize = max(1, listLimits.maxItems - 2)
        let page = CarPlayListPolicy.letterPage(buckets, offset: offset, pageSize: pageSize)
        var letterItems: [CPListItem] = []
        if let previous = page.previousOffset {
            let back = actionItem(
                title: "← Previous",
                detail: "Earlier letters",
                systemImage: "chevron.left.circle")
            back.handler = { [weak self] _, completion in
                self?.applyArtistLetterIndex(
                    buckets, onto: list, session: session, offset: previous)
                completion()
            }
            letterItems.append(back)
        }
        letterItems.append(contentsOf: page.page.map { bucket in
            let item = libraryShortcut(
                title: bucket.letter,
                detail: "\(bucket.items.count) artists",
                systemImage: "person.2.fill")
            item.handler = { [weak self] _, completion in
                self?.showArtistLetter(
                    bucket.letter, artists: bucket.items, session: session, offset: 0)
                completion()
            }
            return item
        })
        if let next = page.nextOffset {
            let more = actionItem(
                title: "More…",
                detail: "\(page.remaining) more letters",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                self?.applyArtistLetterIndex(
                    buckets, onto: list, session: session, offset: next)
                completion()
            }
            letterItems.append(more)
        }
        applySections([CPListSection(items: letterItems)], to: list)
    }

    /// Artists for one letter. First open pushes; More… / ← Previous update in place.
    private func showArtistLetter(
        _ letter: String,
        artists: [Artist],
        session: AppSession,
        offset: Int,
        updating existing: CPListTemplate? = nil
    ) {
        guard interfaceController != nil else { return }
        let list: CPListTemplate
        if let existing {
            list = existing
        } else {
            list = CPListTemplate(title: letter, sections: [])
            pushTemplate(list, kind: .letter)
        }

        let pageSize = min(listLimits.letterPageSize, max(1, listLimits.maxItems - 2))
        let page = CarPlayListPolicy.letterPage(artists, offset: offset, pageSize: pageSize)

        var items: [CPListItem] = []
        if let previous = page.previousOffset {
            let back = actionItem(
                title: "← Previous",
                detail: "Earlier artists",
                systemImage: "chevron.left.circle")
            back.handler = { [weak self] _, completion in
                self?.showArtistLetter(
                    letter, artists: artists, session: session,
                    offset: previous, updating: list)
                completion()
            }
            items.append(back)
        }
        items.append(contentsOf: page.page.map { artist in
            let item = listItem(
                text: artist.name,
                detail: artist.albumCount.map { "\($0) albums" } ?? "Artist",
                coverArt: artist.coverArt,
                fallbackId: artist.id,
                session: session,
                style: .artist)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showArtist(
                        id: artist.id,
                        name: artist.name,
                        session: session,
                        coverArt: artist.coverArt)
                    completion()
                }
            }
            return item
        })
        if let next = page.nextOffset {
            let more = actionItem(
                title: "More…",
                detail: "\(page.remaining) more",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                self?.showArtistLetter(
                    letter, artists: artists, session: session,
                    offset: next, updating: list)
                completion()
            }
            items.append(more)
        }
        applySections([CPListSection(items: items)], to: list)
    }

    /// A–Z letter index. Index + letter More… both update in place (no depth growth).
    private func showAlbumsBrowse(
        session: AppSession,
        updating existing: CPListTemplate? = nil
    ) async {
        guard let interfaceController else { return }

        func presentError(_ template: CPListTemplate) {
            applySections([serverErrorSection { [weak self] in
                Task { await self?.showAlbumsBrowse(session: session, updating: template) }
            }], to: template)
        }

        let list: CPListTemplate
        if let existing {
            list = existing
        } else {
            list = CPListTemplate(title: "Albums", sections: clampSections([
                CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
            ]))
            pushTemplate(list, kind: .browse)
        }

        albumBrowseTemplate = list
        albumsBrowseOffset = 0

        // First page immediately; remaining pages fill in the background.
        let pageSize = 80
        let first: [Album]
        do {
            first = try await session.client.albumList(
                type: .alphabeticalByName, size: pageSize, offset: 0)
        } catch {
            presentError(list)
            return
        }

        if first.isEmpty {
            applySections([
                emptySection(title: "No albums", detail: "Sync your library on iPhone")
            ], to: list)
            return
        }

        applyAlbumLetterIndex(
            CarPlayListPolicy.letterBuckets(first, name: { $0.name }),
            onto: list, session: session, offset: 0)

        guard first.count >= pageSize else { return }

        Task { [weak self] in
            guard let self else { return }
            var all = first
            var offset = first.count
            while !Task.isCancelled {
                let page: [Album]
                do {
                    page = try await session.client.albumList(
                        type: .alphabeticalByName, size: pageSize, offset: offset)
                } catch {
                    break
                }
                if page.isEmpty { break }
                all.append(contentsOf: page)
                offset += page.count
                let buckets = CarPlayListPolicy.letterBuckets(all, name: { $0.name })
                let keepOffset = self.albumsBrowseOffset
                self.applyAlbumLetterIndex(
                    buckets, onto: list, session: session, offset: keepOffset)
                if page.count < pageSize || offset >= 50_000 { break }
            }
        }
    }

    private weak var albumBrowseTemplate: CPListTemplate?
    private var albumsBrowseOffset = 0

    private func applyAlbumLetterIndex(
        _ buckets: [(letter: String, items: [Album])],
        onto list: CPListTemplate,
        session: AppSession,
        offset: Int
    ) {
        let pageSize = max(1, listLimits.maxItems - 2)
        var page = CarPlayListPolicy.letterPage(buckets, offset: offset, pageSize: pageSize)
        // Background fills can leave a stale offset past the end — fall back.
        if page.page.isEmpty, let previous = page.previousOffset {
            page = CarPlayListPolicy.letterPage(
                buckets, offset: previous, pageSize: pageSize)
            albumsBrowseOffset = previous
        } else {
            albumsBrowseOffset = offset
        }
        var letterItems: [CPListItem] = []
        if let previous = page.previousOffset {
            let back = actionItem(
                title: "← Previous",
                detail: "Earlier letters",
                systemImage: "chevron.left.circle")
            back.handler = { [weak self] _, completion in
                self?.applyAlbumLetterIndex(
                    buckets, onto: list, session: session, offset: previous)
                completion()
            }
            letterItems.append(back)
        }
        letterItems.append(contentsOf: page.page.map { bucket in
            let item = libraryShortcut(
                title: bucket.letter,
                detail: "\(bucket.items.count) albums",
                systemImage: "square.stack.fill")
            item.handler = { [weak self] _, completion in
                self?.showAlbumLetter(
                    bucket.letter, albums: bucket.items, session: session, offset: 0)
                completion()
            }
            return item
        })
        if let next = page.nextOffset {
            let more = actionItem(
                title: "More…",
                detail: "\(page.remaining) more letters",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                self?.applyAlbumLetterIndex(
                    buckets, onto: list, session: session, offset: next)
                completion()
            }
            letterItems.append(more)
        }
        applySections([CPListSection(items: letterItems)], to: list)
    }

    private func showAlbumLetter(
        _ letter: String,
        albums: [Album],
        session: AppSession,
        offset: Int,
        updating existing: CPListTemplate? = nil
    ) {
        guard interfaceController != nil else { return }
        let list: CPListTemplate
        if let existing {
            list = existing
        } else {
            list = CPListTemplate(title: letter, sections: [])
            pushTemplate(list, kind: .letter)
        }

        let pageSize = min(listLimits.letterPageSize, max(1, listLimits.maxItems - 2))
        let page = CarPlayListPolicy.letterPage(albums, offset: offset, pageSize: pageSize)
        var items: [CPListItem] = []
        if let previous = page.previousOffset {
            let back = actionItem(
                title: "← Previous",
                detail: "Earlier albums",
                systemImage: "chevron.left.circle")
            back.handler = { [weak self] _, completion in
                self?.showAlbumLetter(
                    letter, albums: albums, session: session,
                    offset: previous, updating: list)
                completion()
            }
            items.append(back)
        }
        items.append(contentsOf: albumItems(page.page, session: session))
        if let next = page.nextOffset {
            let more = actionItem(
                title: "More…",
                detail: "\(page.remaining) more",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                self?.showAlbumLetter(
                    letter, albums: albums, session: session,
                    offset: next, updating: list)
                completion()
            }
            items.append(more)
        }
        applySections([CPListSection(items: items)], to: list)
    }

    private func actionItem(
        title: String,
        detail: String?,
        systemImage: String,
        coverArt: String? = nil,
        fallbackId: String? = nil,
        session: AppSession? = nil,
        style: CarPlayArtwork.Style = .album
    ) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        if let session, coverArt != nil || fallbackId != nil {
            CarPlayArtwork.attach(
                to: item, coverArt: coverArt, fallbackId: fallbackId, session: session, style: style)
        } else if let image = UIImage(systemName: systemImage) {
            item.setImage(image)
        }
        return item
    }

    private func showPlaylist(
        id: String,
        name: String,
        coverArt: String? = nil,
        session: AppSession,
        updating existing: CPListTemplate? = nil
    ) async {
        guard let interfaceController else { return }

        let cached = LibraryDetailCache.playlist(id)
        let shellSongs = cached?.songs ?? []
        var loadingItems: [CPListItem] = []
        let hero = CPListItem(
            text: name,
            detailText: shellSongs.isEmpty ? "Loading playlist…" : "\(shellSongs.count) songs")
        CarPlayArtwork.attach(
            to: hero, coverArt: coverArt ?? cached?.coverArt, fallbackId: id,
            session: session, style: .playlist)
        loadingItems.append(hero)
        if shellSongs.isEmpty {
            let loadingRow = CPListItem(text: "Loading tracks…", detailText: nil)
            if let image = UIImage(systemName: "ellipsis") {
                loadingRow.setImage(image)
            }
            loadingItems.append(loadingRow)
        }

        let placeholder: CPListTemplate
        if let existing {
            placeholder = existing
            applySections([CPListSection(items: loadingItems)], to: placeholder)
        } else {
            placeholder = CPListTemplate(
                title: name,
                sections: [CPListSection(items: loadingItems)])
            pushTemplate(placeholder, kind: .detail)
        }

        guard let playlist = try? await session.client.playlist(id: id) else {
            let retry = CPListItem(text: "Retry", detailText: "Try loading again")
            if let image = UIImage(systemName: "arrow.clockwise") {
                retry.setImage(image)
            }
            retry.handler = { [weak self] _, completion in
                Task {
                    await self?.showPlaylist(
                        id: id, name: name, coverArt: coverArt,
                        session: session, updating: placeholder)
                    completion()
                }
            }
            applySections([CPListSection(items: [
                hero,
                CPListItem(text: "Couldn't load playlist", detailText: "Check Wi‑Fi or try again"),
                retry
            ])], to: placeholder)
            return
        }
        LibraryDetailCache.store(playlist: playlist)

        var items: [CPListItem] = []
        let kind: PlaybackContext.Kind = playlist.name == RotationManager.playlistName
            ? .outOfRotation : .playlist(id: id)

        // Hero is info-only — keep a single Play + Shuffle (no duplicate hero Play).
        let readyHero = CPListItem(
            text: playlist.name,
            detailText: playlist.songs.isEmpty ? "Empty playlist" : "\(playlist.songs.count) songs")
        CarPlayArtwork.attach(
            to: readyHero,
            coverArt: playlist.coverArt ?? coverArt,
            fallbackId: id,
            session: session,
            style: .playlist)
        items.append(readyHero)

        if !playlist.songs.isEmpty {
            let playAll = actionItem(
                title: "Play",
                detail: "\(playlist.songs.count) songs",
                systemImage: "play.fill",
                coverArt: playlist.coverArt ?? coverArt,
                fallbackId: id,
                session: session,
                style: .playlist)
            playAll.handler = { [weak self] _, completion in
                self?.playSongs(playlist.songs, startAt: 0, label: name, kind: kind, session: session)
                completion()
            }
            items.append(playAll)

            let shuffle = actionItem(title: "Shuffle", detail: nil, systemImage: "shuffle")
            shuffle.handler = { [weak self] _, completion in
                session.player.playShuffled(
                    playlist.songs,
                    context: PlaybackContext(label: name, kind: kind))
                self?.pushNowPlaying()
                completion()
            }
            items.append(shuffle)
            let trackCap = max(0, listLimits.maxItems - items.count)
            items.append(contentsOf: songItems(
                Array(playlist.songs.prefix(trackCap)),
                label: name, kind: kind, session: session))
        }

        applySections([CPListSection(items: items)], to: placeholder)
    }

    // MARK: - Artwork + playback helpers

    private func listItem(
        text: String,
        detail: String?,
        coverArt: String?,
        fallbackId: String?,
        session: AppSession,
        style: CarPlayArtwork.Style = .album
    ) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        CarPlayArtwork.attach(
            to: item, coverArt: coverArt, fallbackId: fallbackId, session: session, style: style)
        return item
    }

    private func playSongs(_ songs: [Song], startAt: Int, label: String,
                           kind: PlaybackContext.Kind, session: AppSession) {
        guard !songs.isEmpty else { return }
        session.player.play(songs, startAt: startAt,
                            context: PlaybackContext(label: label, kind: kind))
        refreshNowPlayingButtons()
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard let interfaceController else { return }
        if interfaceController.topTemplate is CPNowPlayingTemplate { return }
        pushTemplate(CPNowPlayingTemplate.shared, kind: .nowPlaying)
    }

    // MARK: - Depth-safe template pushes

    private var templateStackDepth: Int {
        interfaceController?.templates.count ?? 0
    }

    /// True when Go to artist / nested detail can still appear (push or replace).
    private var canPushOrReplaceDetail: Bool {
        CarPlayListPolicy.pushDecision(
            currentDepth: templateStackDepth, kind: .detail) != .skip
    }

    /// Every CarPlay push goes through `CarPlayListPolicy.pushDecision`.
    private func pushTemplate(
        _ template: CPTemplate,
        kind: CarPlayListPolicy.PushKind,
        animated: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let interfaceController else {
            completion?(false)
            return
        }
        let decision = CarPlayListPolicy.pushDecision(
            currentDepth: templateStackDepth, kind: kind)
        switch decision {
        case .push:
            interfaceController.pushTemplate(template, animated: animated) { success, _ in
                completion?(success)
            }
        case .replaceTop:
            interfaceController.popTemplate(animated: false) { [weak self] _, _ in
                self?.interfaceController?.pushTemplate(
                    template, animated: animated
                ) { success, _ in
                    completion?(success)
                }
            }
        case .skip:
            DromeDiagnostics.log(
                "carplay push skipped kind=\(kind.rawValue) depth=\(templateStackDepth)",
                category: .session)
            completion?(false)
        }
    }

    /// Pop the mirrored search overlay, then run `next` (Voice / Keys).
    private func replaceMirroredSearch(_ next: @escaping () -> Void) {
        guard let interfaceController else {
            stopMirrorSearch()
            next()
            return
        }
        stopMirrorSearch()
        if interfaceController.templates.count > 1 {
            interfaceController.popTemplate(animated: false) { _, _ in
                next()
            }
        } else {
            next()
        }
    }

    /// Artists with an explicit `albumCount` of 0 sort after everyone else.
    private static func artistsWithEmptyAlbumsLast(_ artists: [Artist]) -> [Artist] {
        artists.sorted { a, b in
            let aEmpty = (a.albumCount ?? -1) == 0
            let bEmpty = (b.albumCount ?? -1) == 0
            if aEmpty != bEmpty { return !aEmpty && bEmpty }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func filteredBrowseArtists(_ artists: [Artist], session: AppSession) async -> [Artist] {
        guard LibraryArtistFilter.hideCreditOnlyArtists else {
            return Self.artistsWithEmptyAlbumsLast(artists)
        }
        let ownership = await session.artistOwnershipStats()
        let songsIndexed = await session.songsIndexComplete()
        return Self.artistsWithEmptyAlbumsLast(
            LibraryArtistFilter.filter(artists, ownership: ownership, songsIndexed: songsIndexed))
    }

    private func filterSearchResult(_ result: SearchResult3, session: AppSession) async -> SearchResult3 {
        guard LibraryArtistFilter.hideCreditOnlyArtists else { return result }
        let ownership = await session.artistOwnershipStats()
        let songsIndexed = await session.songsIndexComplete()
        let artists = LibraryArtistFilter.filter(result.artists, ownership: ownership, songsIndexed: songsIndexed)
        return SearchResult3(artist: artists, album: result.album, song: result.song)
    }
}

extension Notification.Name {
    /// Focus the iPhone Search field so CarPlay can mirror a real QWERTY keyboard.
    static let dromeFocusCarPlaySearch = Notification.Name("drome.focusCarPlaySearch")
    /// CarPlay observes this while mirroring; `userInfo["query"]` is a String.
    static let dromeCarPlaySearchQuery = Notification.Name("drome.carPlaySearchQuery")
}
