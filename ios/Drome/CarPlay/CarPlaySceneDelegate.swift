import CarPlay
import Foundation
import UIKit

/// CarPlay entry point (`CPTemplateApplicationSceneSessionRoleApplication`).
///
/// Tabs: Home · Search · Library. Now Playing is the shared system template
/// (artwork via `MPNowPlayingInfoCenter`; rate / shuffle / repeat / autoplay
/// buttons; Queue + album/artist actions).
///
/// Search prefers `CPSearchTemplate` (native keyboard) when the OS allows it
/// for audio apps (iOS 27+). On earlier OSes, Search mirrors the iPhone’s
/// QWERTY onto live CarPlay results; an 8-key grid remains available on-head-unit.
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
    private weak var searchTabTemplate: CPListTemplate?
    private weak var mirroredResultsTemplate: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?
    private var sessionConfiguration: CPSessionConfiguration?
    private var searchTask: Task<Void, Never>?
    private var searchSongs: [String: Song] = [:]
    private var searchAlbums: [String: Album] = [:]
    private var searchArtists: [String: Artist] = [:]
    /// Cached after first probe — system keyboard search is entitlement/OS gated.
    private var systemSearchSupported: Bool?
    private var mirrorQueryObserver: NSObjectProtocol?
    private let customKeyboard = CarPlayKeyboard()

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
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        searchTask?.cancel()
        stopMirrorSearch()
        searchTemplate = nil
        systemSearchSupported = nil
        searchTabTemplate = nil
        mirroredResultsTemplate = nil
        sessionConfiguration = nil
        customKeyboard.reset()
        self.interfaceController = nil
        tabBar = nil
        NotificationCenter.default.removeObserver(self)
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        // Vehicle / Simulator "Limit UI" can hide the system keyboard even when
        // CPSearchTemplate is allowed.
        _ = limitedUserInterfaces
    }

    @objc private func sessionChanged() {
        rebuildRoot()
    }

    // MARK: - Root

    private func rebuildRoot() {
        guard let interfaceController else { return }

        guard let session = AppEnvironment.shared?.session else {
            let list = CPListTemplate(title: "Drome", sections: [
                CPListSection(items: [
                    CPListItem(text: "Sign in on your iPhone",
                               detailText: "Open Drome and connect to Navidrome")
                ])
            ])
            interfaceController.setRootTemplate(list, animated: true, completion: nil)
            return
        }

        // Tab bar only accepts list/grid templates (not Now Playing or Search).
        let home = makeHomeTemplate(session: session)
        let search = makeSearchTab(session: session)
        let library = makeLibraryTemplate(session: session)
        let tabs = CPTabBarTemplate(templates: [home, search, library])
        tabs.delegate = self
        tabBar = tabs
        searchTabTemplate = search
        interfaceController.setRootTemplate(tabs, animated: true, completion: nil)
        refreshNowPlayingButtons()
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        // Search tab shows Type on iPhone / Siri dictation / Letter pad — don't auto-push.
        _ = selectedTemplate
    }

    // MARK: - Now Playing

    private func configureNowPlayingTemplate() {
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        np.isUpNextButtonEnabled = true
        np.upNextTitle = "Queue"
        np.isAlbumArtistButtonEnabled = true

        let rateImage = UIImage(systemName: "star.fill") ?? UIImage()
        let rate = CPNowPlayingImageButton(image: rateImage) { [weak self] _ in
            self?.showRatingPicker()
        }
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            AppEnvironment.shared?.session?.player.cycleShuffleMode()
            self?.refreshNowPlayingButtons()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            AppEnvironment.shared?.session?.player.cycleRepeatMode()
            self?.refreshNowPlayingButtons()
        }
        let autoplayImage = UIImage(systemName: "infinity") ?? UIImage()
        let autoplay = CPNowPlayingImageButton(image: autoplayImage) { [weak self] _ in
            guard let player = AppEnvironment.shared?.session?.player else { return }
            player.autoplayEnabled.toggle()
            self?.refreshNowPlayingButtons()
        }
        let artistImage = UIImage(systemName: "person.fill") ?? UIImage()
        let artist = CPNowPlayingImageButton(image: artistImage) { [weak self] _ in
            Task { await self?.openNowPlayingArtist() }
        }

        np.updateNowPlayingButtons([rate, shuffle, repeatButton, autoplay, artist])
        refreshNowPlayingButtons()
    }

    private func refreshNowPlayingButtons() {
        guard let session = AppEnvironment.shared?.session else { return }
        let player = session.player
        let rating = player.current.map { session.ratings.rating(for: $0.song) } ?? 0
        let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
        for button in buttons {
            if button is CPNowPlayingShuffleButton {
                button.isSelected = player.shuffleMode != .off
            } else if button is CPNowPlayingRepeatButton {
                button.isSelected = player.repeatMode != .off
            }
        }
        let images = buttons.compactMap { $0 as? CPNowPlayingImageButton }
        if images.count >= 1 { images[0].isSelected = rating > 0 }
        if images.count >= 2 { images[1].isSelected = player.autoplayEnabled }
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showQueue()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { await openNowPlayingAlbum() }
    }

    private func showRatingPicker() {
        guard let interfaceController,
              let session = AppEnvironment.shared?.session,
              let song = session.player.current?.song else { return }

        let current = session.ratings.rating(for: song)
        var items: [CPListItem] = (1...5).map { stars in
            let filled = String(repeating: "★", count: stars)
            let empty = String(repeating: "☆", count: 5 - stars)
            let item = CPListItem(
                text: "\(filled)\(empty)",
                detailText: stars == current ? "Current rating" : nil)
            item.handler = { [weak self] _, completion in
                session.ratings.setRating(stars, for: song)
                self?.refreshNowPlayingButtons()
                interfaceController.popTemplate(animated: true) { _, _ in
                    completion()
                }
            }
            return item
        }

        let clear = CPListItem(text: "Clear rating", detailText: nil)
        clear.handler = { [weak self] _, completion in
            session.ratings.setRating(0, for: song)
            self?.refreshNowPlayingButtons()
            interfaceController.popTemplate(animated: true) { _, _ in
                completion()
            }
        }
        items.append(clear)

        let list = CPListTemplate(title: "Rate", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showQueue() {
        guard let interfaceController,
              let session = AppEnvironment.shared?.session else { return }
        let player = session.player
        let upcoming = player.userQueue + player.contextQueue

        if upcoming.isEmpty {
            let empty = CPListTemplate(title: "Queue", sections: [
                CPListSection(items: [
                    CPListItem(text: "Queue is empty", detailText: "Play something to build a queue")
                ])
            ])
            interfaceController.pushTemplate(empty, animated: true, completion: nil)
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

        let list = CPListTemplate(title: "Queue", sections: [
            CPListSection(items: [manage]),
            CPListSection(items: items, header: "Up Next", sectionIndexTitle: nil)
        ])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showQueueEditor() {
        guard let interfaceController,
              let session = AppEnvironment.shared?.session else { return }
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
                interfaceController.popTemplate(animated: false) { _, _ in
                    self?.showQueueEditor()
                    completion()
                }
            }
            return row
        }
        let list = CPListTemplate(
            title: "Edit Queue",
            sections: [CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "Queue is empty", detailText: nil)]
                                     : items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
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
        let template = CPListTemplate(title: "Home", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house.fill")

        Task {
            let recent = (try? AppEnvironment.shared.database.recentPlayEntries(
                userKey: session.account.userKey, limit: 30)) ?? []
            async let frequentTask = session.client.albumList(type: .frequent, size: 16)
            async let newestTask = session.client.albumList(type: .newest, size: 16)
            async let playlistsTask = session.client.playlists()

            let frequent = (try? await frequentTask) ?? []
            let newest = (try? await newestTask) ?? []
            let playlists = (try? await playlistsTask) ?? []

            var sections: [CPListSection] = []

            let recentItems = recent.prefix(12).compactMap { entry -> CPListItem? in
                recentItem(entry, session: session)
            }
            if !recentItems.isEmpty {
                sections.append(CPListSection(
                    items: Array(recentItems),
                    header: "Recently Played",
                    sectionIndexTitle: nil))
            }

            if !frequent.isEmpty {
                sections.append(CPListSection(
                    items: albumItems(frequent, session: session),
                    header: "Jump Back In",
                    sectionIndexTitle: nil))
            }

            if !newest.isEmpty {
                sections.append(CPListSection(
                    items: albumItems(newest, session: session),
                    header: "New in Your Library",
                    sectionIndexTitle: nil))
            }

            let ranked = rankedHomePlaylists(playlists, recent: recent)
            if !ranked.isEmpty {
                sections.append(CPListSection(
                    items: playlistItems(ranked, session: session),
                    header: "Playlists",
                    sectionIndexTitle: nil))
            }

            if sections.isEmpty {
                sections = [CPListSection(items: [
                    CPListItem(text: "Nothing here yet",
                               detailText: "Play music on your iPhone to fill Home")
                ])]
            }
            template.updateSections(sections)
            CarPlayArtwork.prefetch(
                ids: frequent.map { $0.coverArt ?? $0.id }
                    + newest.map { $0.coverArt ?? $0.id }
                    + ranked.prefix(12).map { $0.coverArt ?? $0.id },
                session: session)
        }
        return template
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
                self?.playSongs([cover], startAt: 0, label: name, kind: .mix, session: session)
                completion()
            }
            return item
        }
    }

    private func rankedHomePlaylists(_ playlists: [Playlist],
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
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        ordered.append(contentsOf: rest)
        return Array(ordered.prefix(16))
    }

    // MARK: - Search

    private func makeSearchTab(session: AppSession) -> CPListTemplate {
        // Prefer system CPSearchTemplate when the OS allows it (audio: iOS 27+).
        // Voice uses the system search field’s Siri dictation, not in-app recognition.
        let phone = CPListItem(
            text: "Type on iPhone",
            detailText: "Keyboard opens on your phone — results show here")
        if let image = UIImage(systemName: "iphone") {
            phone.setImage(image)
        }
        phone.handler = { [weak self] _, completion in
            self?.openSearch(session: session)
            completion()
        }

        let voice = CPListItem(
            text: "Search by voice",
            detailText: "Opens search — tap the mic for Siri dictation")
        if let image = UIImage(systemName: "mic.fill") {
            voice.setImage(image)
        }
        voice.handler = { [weak self] _, completion in
            self?.openSearch(session: session)
            completion()
        }

        let keys = CPListItem(
            text: "CarPlay letter pad",
            detailText: "Spell with on-screen keys")
        if let image = UIImage(systemName: "keyboard") {
            keys.setImage(image)
        }
        keys.handler = { [weak self] _, completion in
            self?.openCustomKeyboard(session: session)
            completion()
        }

        let template = CPListTemplate(title: "Search", sections: [
            CPListSection(items: [phone, voice, keys])
        ])
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        return template
    }

    /// Prefer Apple’s `CPSearchTemplate`; otherwise mirror the iPhone QWERTY.
    private func openSearch(session: AppSession) {
        if systemSearchSupported == false {
            openMirroredPhoneSearch(session: session)
            return
        }

        // If the vehicle / Simulator has Limit UI on, the system keyboard is hidden.
        if let limits = sessionConfiguration?.limitedUserInterfaces,
           limits.contains(.keyboard) {
            presentSimpleAlert(
                title: "Keyboard limited",
                message: "Turn off Limit UI in CarPlay Simulator, or search while parked.")
        }

        // Soft probe — completion path never freezes the UI waiting on an exception.
        pushSystemSearchTemplate { [weak self] ok in
            guard let self else { return }
            if ok {
                self.systemSearchSupported = true
                return
            }
            self.systemSearchSupported = false
            self.openMirroredPhoneSearch(session: session)
        }
    }

    private func openCustomKeyboard(session: AppSession) {
        guard let interfaceController else { return }
        stopMirrorSearch()
        let template = customKeyboard.makeTemplate { [weak self] query in
            Task { @MainActor in
                await self?.showSearchResults(
                    query: query, session: session, title: "“\(query)”")
            }
        }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
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
                self?.openSearch(session: session)
            },
            CPBarButton(title: "Keys") { [weak self] _ in
                self?.openCustomKeyboard(session: session)
            }
        ]
        mirroredResultsTemplate = list
        interfaceController.pushTemplate(list, animated: true, completion: nil)

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
            list.updateSections(self.makeSearchSections(
                from: result, query: trimmed, session: session))
        }
    }

    /// Push Apple’s search template (native keyboard). Uses the completion
    /// handler so unsupported templates fail softly instead of throwing.
    private func pushSystemSearchTemplate(completion: @escaping (Bool) -> Void) {
        guard let interfaceController else {
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
            interfaceController.pushTemplate(search, animated: true) { success, _ in
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

            // CPSearchTemplate is a flat list and only keeps a short prefix —
            // put artists/albums first so they aren't buried under songs.
            let items = self.makeFlatSearchItems(from: result, session: session, limit: 20)
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
        return sections
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
        guard let interfaceController else { return }
        let result = (try? await session.client.search(
            query, artistCount: 12, albumCount: 12, songCount: 24))
            ?? SearchResult3(artist: nil, album: nil, song: nil)
        let sections = makeSearchSections(from: result, query: query, session: session)
        let list = CPListTemplate(title: title, sections: sections)
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: - Library

    private func makeLibraryTemplate(session: AppSession) -> CPListTemplate {
        let template = CPListTemplate(title: "Library", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "rectangle.stack.fill")

        Task {
            let lists = (try? await session.client.playlists()) ?? []
            var sections: [CPListSection] = []

            var shortcuts: [CPListItem] = []

            let downloads = libraryShortcut(
                title: "Downloaded",
                detail: session.downloads.downloadedCount == 0
                    ? "Offline music"
                    : "\(session.downloads.downloadedCount) songs",
                systemImage: "arrow.down.circle.fill")
            downloads.handler = { [weak self] _, completion in
                self?.showDownloads(session: session)
                completion()
            }
            shortcuts.append(downloads)

            let artists = libraryShortcut(
                title: "Artists",
                detail: "Browse your artists",
                systemImage: "person.2.fill")
            artists.handler = { [weak self] _, completion in
                Task {
                    await self?.showArtistsBrowse(session: session)
                    completion()
                }
            }
            shortcuts.append(artists)

            let albums = libraryShortcut(
                title: "Albums",
                detail: "Browse your albums",
                systemImage: "square.stack.fill")
            albums.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbumsBrowse(session: session)
                    completion()
                }
            }
            shortcuts.append(albums)

            let rated = libraryShortcut(
                title: "Top Rated",
                detail: "5★, 4★ & up, top albums",
                systemImage: "star.fill")
            rated.handler = { [weak self] _, completion in
                self?.showRatedMenu(session: session)
                completion()
            }
            shortcuts.append(rated)

            let genres = libraryShortcut(
                title: "Genres",
                detail: "Browse by genre",
                systemImage: "guitars")
            genres.handler = { [weak self] _, completion in
                Task {
                    await self?.showGenres(session: session)
                    completion()
                }
            }
            shortcuts.append(genres)

            sections.append(CPListSection(items: shortcuts, header: "Browse", sectionIndexTitle: nil))

            if lists.isEmpty {
                sections.append(CPListSection(items: [
                    CPListItem(text: "No playlists", detailText: "Create one on your iPhone")
                ], header: "Playlists", sectionIndexTitle: nil))
            } else {
                sections.append(CPListSection(
                    items: playlistItems(lists, session: session),
                    header: "Playlists",
                    sectionIndexTitle: nil))
            }

            template.updateSections(sections)
        }
        return template
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
        guard let interfaceController else { return }
        let songs = session.downloads.downloadedSongs()
            .sorted {
                ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending
            }
        if songs.isEmpty {
            let empty = CPListTemplate(title: "Downloaded", sections: [
                CPListSection(items: [
                    CPListItem(text: "No downloads", detailText: "Download music on your iPhone")
                ])
            ])
            interfaceController.pushTemplate(empty, animated: true, completion: nil)
            return
        }

        let grouped = Dictionary(grouping: songs) { $0.album?.isEmpty == false ? ($0.album ?? "Tracks") : "Tracks" }
        let sections: [CPListSection] = grouped.keys.sorted().map { name in
            let albumSongs = grouped[name] ?? []
            let items = songItems(albumSongs, label: name, kind: .mix, session: session)
            return CPListSection(items: items, header: name, sectionIndexTitle: nil)
        }
        let list = CPListTemplate(title: "Downloaded", sections: sections)
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showRatedMenu(session: AppSession) {
        guard let interfaceController else { return }
        let items: [CPListItem] = RatedCollection.allCases.map { collection in
            let item = libraryShortcut(
                title: collection.rawValue,
                detail: collection.subtitle,
                systemImage: collection.systemImage)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showRatedCollection(collection, session: session)
                    completion()
                }
            }
            return item
        }
        let list = CPListTemplate(title: "Top Rated", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showRatedCollection(_ collection: RatedCollection, session: AppSession) async {
        guard let interfaceController else { return }

        if collection == .topAlbums {
            let albums = ((try? await session.client.albumList(type: .highest, size: 80)) ?? [])
                .filter { ($0.userRating ?? 0) > 0 }
            let list = CPListTemplate(
                title: collection.rawValue,
                sections: [CPListSection(items: albumItems(albums, session: session))])
            interfaceController.pushTemplate(list, animated: true, completion: nil)
            return
        }

        let minRating = collection == .fiveStars ? 5 : 4
        let songs = session.ratings.cachedSongs(minRating: minRating)
        var items: [CPListItem] = []
        if !songs.isEmpty {
            let play = CPListItem(text: "Play All", detailText: "\(songs.count) songs")
            play.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: 0, label: collection.rawValue, kind: .mix, session: session)
                completion()
            }
            items.append(play)
            items.append(contentsOf: songItems(songs, label: collection.rawValue, kind: .mix, session: session))
        } else {
            items = [CPListItem(text: "Nothing here yet", detailText: "Rate tracks on your iPhone or Now Playing")]
        }
        let list = CPListTemplate(title: collection.rawValue, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showGenres(session: AppSession) async {
        guard let interfaceController else { return }
        let raw = (try? await session.client.genres()) ?? []
        let genres = GenreNormalizer.shared.groupedGenres(raw)
        let items: [CPListItem] = genres.map { genre in
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
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showGenre(genre, session: session)
                    completion()
                }
            }
            return item
        }
        let list = CPListTemplate(
            title: "Genres",
            sections: [CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "No genres", detailText: nil)]
                                     : items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showGenre(_ genre: NormalizedGenre, session: AppSession) async {
        guard let interfaceController else { return }
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
            sections = [CPListSection(items: [CPListItem(text: "Nothing found", detailText: nil)])]
        }
        let list = CPListTemplate(title: genre.displayName, sections: sections)
        interfaceController.pushTemplate(list, animated: true, completion: nil)
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
        songCount: Int? = nil
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

        let placeholder = CPListTemplate(
            title: name,
            sections: albumDetailSections(
                album: shell,
                fallbackName: name,
                loading: cached == nil || (cached?.songs.isEmpty ?? true),
                session: session))
        interfaceController.pushTemplate(placeholder, animated: true, completion: nil)

        // Prefetch the hero cover at CarPlay size right away.
        CarPlayArtwork.prefetch(ids: [coverArt ?? id], session: session, limit: 1)

        let album: AlbumWithSongs
        if let fresh = try? await session.client.album(id: id) {
            LibraryDetailCache.store(album: fresh)
            album = fresh
        } else if let cached {
            album = cached
        } else {
            placeholder.updateSections([CPListSection(items: [
                albumHeroItem(shell, session: session, loading: false, playable: false),
                CPListItem(text: "Couldn't load album", detailText: "Try again when you’re parked")
            ])])
            return
        }

        placeholder.updateSections(albumDetailSections(
            album: album, fallbackName: name, loading: false, session: session))
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

        var headerItems: [CPListItem] = [
            albumHeroItem(album, session: session, loading: loading && songs.isEmpty, playable: !songs.isEmpty)
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

        if let artistId = album.artistId, !artistId.isEmpty,
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

        for disc in discKeys {
            let discSongs = (discs[disc] ?? []).sorted {
                ($0.track ?? 0) < ($1.track ?? 0)
            }
            let header = multiDisc ? "Disc \(disc)" : "Tracks"
            sections.append(CPListSection(
                items: albumTrackItems(discSongs, album: album, session: session),
                header: header,
                sectionIndexTitle: nil))
        }
        return sections
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
        coverArt: String? = nil
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

        let placeholder = CPListTemplate(
            title: name,
            sections: artistDetailSections(
                artist: shellArtist,
                topSongs: cached?.topSongs ?? [],
                fallbackName: name,
                loading: cached == nil,
                session: session))
        interfaceController.pushTemplate(placeholder, animated: true, completion: nil)
        CarPlayArtwork.prefetch(ids: [coverArt ?? id], session: session, limit: 1)

        async let artistTask = session.client.artist(id: id)
        async let topTask = session.client.topSongs(artistName: name, count: 20)

        let artist = try? await artistTask
        let topSongs = (try? await topTask) ?? []

        if let artist {
            LibraryDetailCache.store(artist: artist, topSongs: topSongs, owned: cached?.owned ?? [])
            placeholder.updateSections(artistDetailSections(
                artist: artist,
                topSongs: topSongs,
                fallbackName: name,
                loading: false,
                session: session))
            CarPlayArtwork.prefetch(
                ids: artist.albums.map { $0.coverArt ?? $0.id },
                session: session)
        } else if cached == nil {
            placeholder.updateSections([CPListSection(items: [
                artistHeroItem(shellArtist, session: session, loading: false),
                CPListItem(text: "Couldn't load artist", detailText: "Try again when you’re parked")
            ])])
        } else if !topSongs.isEmpty {
            LibraryDetailCache.store(
                artist: cached!.artist, topSongs: topSongs, owned: cached?.owned ?? [])
            placeholder.updateSections(artistDetailSections(
                artist: cached?.artist,
                topSongs: topSongs,
                fallbackName: name,
                loading: false,
                session: session))
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
            sections.append(CPListSection(
                items: artistAlbumItems(sorted, session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }

        return sections
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

    private func showArtistsBrowse(session: AppSession) async {
        guard let interfaceController else { return }
        let indexes = (try? await session.client.artists()) ?? []
        let artists = Self.artistsWithEmptyAlbumsLast(indexes.flatMap(\.artists))
        CarPlayArtwork.prefetch(
            ids: artists.prefix(40).map { $0.coverArt ?? $0.id },
            session: session)
        let items: [CPListItem] = artists.map { artist in
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
        let list = CPListTemplate(
            title: "Artists",
            sections: [CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "No artists", detailText: nil)]
                                     : items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showAlbumsBrowse(session: AppSession) async {
        guard let interfaceController else { return }
        let page = (try? await session.client.albumList(
            type: .alphabeticalByName, size: 80, offset: 0)) ?? []
        var items = albumItems(page, session: session)
        if page.count >= 80 {
            let more = actionItem(
                title: "Load More Albums",
                detail: "Continue A–Z",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbumsBrowseMore(offset: page.count, session: session)
                    completion()
                }
            }
            items.append(more)
        }
        let list = CPListTemplate(
            title: "Albums",
            sections: [CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "No albums", detailText: nil)]
                                     : items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func showAlbumsBrowseMore(offset: Int, session: AppSession) async {
        guard let interfaceController else { return }
        let page = (try? await session.client.albumList(
            type: .alphabeticalByName, size: 80, offset: offset)) ?? []
        var items = albumItems(page, session: session)
        if page.count >= 80 {
            let more = actionItem(
                title: "Load More Albums",
                detail: "Continue A–Z",
                systemImage: "ellipsis.circle")
            more.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbumsBrowseMore(offset: offset + page.count, session: session)
                    completion()
                }
            }
            items.append(more)
        }
        let list = CPListTemplate(
            title: "More Albums",
            sections: [CPListSection(items: items.isEmpty
                                     ? [CPListItem(text: "That’s everything", detailText: nil)]
                                     : items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
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
        session: AppSession
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

        let placeholder = CPListTemplate(
            title: name,
            sections: [CPListSection(items: loadingItems)])
        interfaceController.pushTemplate(placeholder, animated: true, completion: nil)

        guard let playlist = try? await session.client.playlist(id: id) else {
            placeholder.updateSections([CPListSection(items: [
                hero,
                CPListItem(text: "Couldn't load playlist", detailText: nil)
            ])])
            return
        }
        LibraryDetailCache.store(playlist: playlist)

        var items: [CPListItem] = []
        let kind: PlaybackContext.Kind = playlist.name == RotationManager.playlistName
            ? .outOfRotation : .playlist(id: id)

        let readyHero = CPListItem(
            text: playlist.name,
            detailText: playlist.songs.isEmpty ? "Empty playlist" : "\(playlist.songs.count) songs")
        CarPlayArtwork.attach(
            to: readyHero,
            coverArt: playlist.coverArt ?? coverArt,
            fallbackId: id,
            session: session,
            style: .playlist)
        if !playlist.songs.isEmpty {
            readyHero.handler = { [weak self] _, completion in
                self?.playSongs(playlist.songs, startAt: 0, label: name, kind: kind, session: session)
                completion()
            }
        }
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
            items.append(contentsOf: songItems(playlist.songs, label: name, kind: kind, session: session))
        }

        placeholder.updateSections([CPListSection(items: items)])
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
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
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
}

extension Notification.Name {
    /// Focus the iPhone Search field so CarPlay can mirror a real QWERTY keyboard.
    static let dromeFocusCarPlaySearch = Notification.Name("drome.focusCarPlaySearch")
    /// CarPlay observes this while mirroring; `userInfo["query"]` is a String.
    static let dromeCarPlaySearchQuery = Notification.Name("drome.carPlaySearchQuery")
}
