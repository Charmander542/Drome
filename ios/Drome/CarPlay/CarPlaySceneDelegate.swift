import CarPlay
import Foundation
import Speech
import AVFoundation
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
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioEngine: AVAudioEngine?
    private var voiceSearchTimeout: Task<Void, Never>?
    /// Cached after first probe — system keyboard search is entitlement/OS gated.
    private var systemSearchSupported: Bool?
    /// Hard voice failures (mic/permissions/simulator) grey out “Ask for a song”.
    private var voiceSearchDisabled = false
    private var mirrorQueryObserver: NSObjectProtocol?
    private let customKeyboard = CarPlayKeyboard()

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
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
        voiceSearchTimeout?.cancel()
        stopSpeechRecognition()
        stopMirrorSearch()
        searchTemplate = nil
        systemSearchSupported = nil
        voiceSearchDisabled = false
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
        // Search tab shows Type on iPhone / Ask by voice / Letter pad — don't auto-push.
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

        np.updateNowPlayingButtons([rate, shuffle, repeatButton, autoplay])
        refreshNowPlayingButtons()
    }

    private func refreshNowPlayingButtons() {
        guard let session = AppEnvironment.shared?.session else { return }
        let player = session.player
        let rating = player.current.map { session.ratings.rating(for: $0.song) } ?? 0
        let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
        for (index, button) in buttons.enumerated() {
            if button is CPNowPlayingShuffleButton {
                button.isSelected = player.shuffleMode != .off
            } else if button is CPNowPlayingRepeatButton {
                button.isSelected = player.repeatMode != .off
            } else if button is CPNowPlayingImageButton {
                // Buttons: [rate, shuffle, repeat, autoplay]
                if index == 0 {
                    button.isSelected = rating > 0
                } else {
                    button.isSelected = player.autoplayEnabled
                }
            }
        }
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showQueue()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showAlbumArtistOptions()
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

    private func showAlbumArtistOptions() {
        guard let interfaceController,
              let session = AppEnvironment.shared?.session,
              let song = session.player.current?.song else { return }

        var items: [CPListItem] = []

        if let albumId = song.albumId, !albumId.isEmpty {
            let albumName = song.album ?? "Album"
            let albumItem = listItem(
                text: "Go to Album",
                detail: albumName,
                coverArt: song.coverArt,
                fallbackId: albumId,
                session: session)
            albumItem.accessoryType = .disclosureIndicator
            albumItem.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbum(id: albumId, name: albumName, session: session)
                    completion()
                }
            }
            items.append(albumItem)
        }

        let artistRoutes = SongNavigation.artistRoutes(for: song)
        if artistRoutes.isEmpty, let fallback = SongNavigation.artistRoute(for: song) {
            let artistItem = CPListItem(text: "Go to Artist", detailText: fallback.name)
            artistItem.accessoryType = .disclosureIndicator
            artistItem.handler = { [weak self] _, completion in
                Task {
                    await self?.showArtist(id: fallback.artistId, name: fallback.name, session: session)
                    completion()
                }
            }
            items.append(artistItem)
        } else {
            for route in artistRoutes {
                let artistItem = CPListItem(text: "Go to Artist", detailText: route.name)
                artistItem.accessoryType = .disclosureIndicator
                artistItem.handler = { [weak self] _, completion in
                    Task {
                        await self?.showArtist(id: route.artistId, name: route.name, session: session)
                        completion()
                    }
                }
                items.append(artistItem)
            }
        }

        if items.isEmpty {
            items = [CPListItem(text: "No album or artist link", detailText: nil)]
        }

        let list = CPListTemplate(title: "Browse", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
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
                    await self?.showAlbum(id: id, name: name, session: session)
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
                    await self?.showPlaylist(id: id, name: name, session: session)
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
        // Otherwise: type on iPhone (mirrored results), ask by voice, or letter pad.
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
            text: "Ask for a song",
            detailText: voiceSearchDisabled
                ? "Unavailable — use Type on iPhone"
                : "Say an artist, album, or track name")
        if let image = UIImage(systemName: "mic.fill") {
            voice.setImage(image)
        }
        voice.isEnabled = !voiceSearchDisabled
        voice.handler = { [weak self] _, completion in
            defer { completion() }
            guard let self, !self.voiceSearchDisabled else { return }
            self.startVoiceSearch(session: session)
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

    /// Rebuild the Search tab in place (e.g. after greying out voice).
    private func refreshSearchTab(session: AppSession) {
        guard let tabBar else {
            rebuildRoot()
            return
        }
        let templates = tabBar.templates
        guard templates.count >= 3 else {
            rebuildRoot()
            return
        }
        let search = makeSearchTab(session: session)
        searchTabTemplate = search
        tabBar.updateTemplates([templates[0], search, templates[2]])
        tabBar.select(search)
    }

    /// Dismiss alerts / voice UI and land on the Search options list.
    private func returnToSearchTab(session: AppSession) {
        guard let interfaceController else { return }
        let finish = { [weak self] in
            guard let self else { return }
            interfaceController.popToRootTemplate(animated: true) { [weak self] _, _ in
                self?.refreshSearchTab(session: session)
            }
        }
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: true) { _, _ in
                finish()
            }
        } else {
            finish()
        }
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
        list.trailingNavigationBarButtons = voiceSearchDisabled
            ? [
                CPBarButton(title: "Keys") { [weak self] _ in
                    self?.openCustomKeyboard(session: session)
                }
            ]
            : [
                CPBarButton(title: "Voice") { [weak self] _ in
                    self?.startVoiceSearch(session: session)
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
            let result = try? await session.client.search(
                trimmed, artistCount: 10, albumCount: 12, songCount: 30)
            guard !Task.isCancelled else { return }

            var sections: [CPListSection] = []
            self.searchSongs = [:]
            self.searchAlbums = [:]
            self.searchArtists = [:]

            let songs = result?.song ?? []
            if !songs.isEmpty {
                for song in songs { self.searchSongs[song.id] = song }
                sections.append(CPListSection(
                    items: self.songItems(songs, label: trimmed, kind: .search, session: session),
                    header: "Songs",
                    sectionIndexTitle: nil))
            }
            let albums = result?.album ?? []
            if !albums.isEmpty {
                sections.append(CPListSection(
                    items: self.albumItems(albums, session: session),
                    header: "Albums",
                    sectionIndexTitle: nil))
            }
            let artists = Self.artistsWithEmptyAlbumsLast(result?.artist ?? [])
            if !artists.isEmpty {
                let items: [CPListItem] = artists.map { artist in
                    self.searchArtists[artist.id] = artist
                    let item = CPListItem(
                        text: artist.name,
                        detailText: artist.albumCount.map { "\($0) albums" })
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, completion in
                        Task {
                            await self?.showArtist(
                                id: artist.id, name: artist.name, session: session)
                            completion()
                        }
                    }
                    return item
                }
                sections.append(CPListSection(
                    items: items, header: "Artists", sectionIndexTitle: nil))
            }

            if sections.isEmpty {
                sections = [CPListSection(items: [
                    CPListItem(text: "No results", detailText: "“\(trimmed)”")
                ])]
            }
            list.updateSections(sections)
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
            completionHandler([])
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let result = try? await session.client.search(
                query, artistCount: 10, albumCount: 12, songCount: 30)
            guard !Task.isCancelled, let self else { return }

            var items: [CPListItem] = []
            self.searchSongs = [:]
            self.searchAlbums = [:]
            self.searchArtists = [:]

            for song in result?.song ?? [] {
                self.searchSongs[song.id] = song
                let item = self.listItem(
                    text: song.title,
                    detail: song.displayArtist,
                    coverArt: song.coverArt,
                    fallbackId: song.albumId ?? song.id,
                    session: session)
                item.userInfo = ["kind": "song", "id": song.id]
                items.append(item)
            }
            for album in result?.album ?? [] {
                self.searchAlbums[album.id] = album
                let item = self.listItem(
                    text: album.name,
                    detail: album.artist,
                    coverArt: album.coverArt,
                    fallbackId: album.id,
                    session: session)
                item.accessoryType = .disclosureIndicator
                item.userInfo = ["kind": "album", "id": album.id]
                items.append(item)
            }
            for artist in Self.artistsWithEmptyAlbumsLast(result?.artist ?? []) {
                self.searchArtists[artist.id] = artist
                let item = CPListItem(
                    text: artist.name,
                    detailText: artist.albumCount.map { "\($0) albums" })
                item.accessoryType = .disclosureIndicator
                item.userInfo = ["kind": "artist", "id": artist.id]
                items.append(item)
            }

            completionHandler(items)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let session = AppEnvironment.shared?.session,
              let info = item.userInfo as? [String: String],
              let kind = info["kind"], let id = info["id"] else {
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
                await self?.showAlbum(id: id, name: name, session: session)
            case "artist":
                let name = self?.searchArtists[id]?.name ?? "Artist"
                await self?.showArtist(id: id, name: name, session: session)
            default:
                break
            }
            completionHandler()
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // Live results already refresh while typing / dictating.
    }

    private func startVoiceSearch(session: AppSession) {
        guard interfaceController != nil, !voiceSearchDisabled else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.presentVoiceFailure(
                        session: session,
                        title: "Speech recognition unavailable",
                        message: "Enable Speech Recognition for Drome in Settings.",
                        disableVoice: true)
                    return
                }
                AVAudioApplication.requestRecordPermission { allowed in
                    Task { @MainActor in
                        guard allowed else {
                            self.presentVoiceFailure(
                                session: session,
                                title: "Microphone needed",
                                message: "Allow microphone access to use Voice Search.",
                                disableVoice: true)
                            return
                        }
                        self.presentVoiceSearch(session: session)
                    }
                }
            }
        }
    }

    private func presentVoiceSearch(session: AppSession) {
        guard let interfaceController else { return }

        let listening = CPVoiceControlState(
            identifier: "listening",
            titleVariants: ["Listening…", "Say a song, artist, or album"],
            image: UIImage(systemName: "mic.fill"),
            repeats: true)
        let working = CPVoiceControlState(
            identifier: "working",
            titleVariants: ["Searching…"],
            image: UIImage(systemName: "magnifyingglass"),
            repeats: true)
        let voice = CPVoiceControlTemplate(voiceControlStates: [listening, working])

        interfaceController.presentTemplate(voice, animated: true) { [weak self] success, _ in
            guard success else {
                self?.presentVoiceFailure(
                    session: session,
                    title: "Voice Search failed",
                    message: "Could not open voice search. Try Type on iPhone.",
                    disableVoice: true)
                return
            }
            self?.beginSpeechRecognition(session: session, voiceTemplate: voice)
        }
    }

    private func beginSpeechRecognition(session: AppSession, voiceTemplate: CPVoiceControlTemplate) {
        stopSpeechRecognition()
        voiceSearchTimeout?.cancel()

        // Activate the session *before* reading the input format / installing a
        // tap. On Simulator (and some CarPlay routes) the mic reports 0 Hz
        // until playAndRecord is active — installing a tap then crashes with
        // IsFormatSampleRateAndChannelCountValid.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .measurement,
                options: [.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            presentVoiceFailure(
                session: session,
                title: "Voice Search failed",
                message: "Could not start the microphone. Try Type on iPhone.",
                disableVoice: true)
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search

        let input = engine.inputNode
        // Prefer the hardware format after activation; fall back to nil so
        // AVAudioEngine picks a valid format. Never pass a 0 Hz / 0-channel format.
        let hardware = input.outputFormat(forBus: 0)
        let format: AVAudioFormat? =
            (hardware.sampleRate > 0 && hardware.channelCount > 0) ? hardware : nil

        let tapInstalled = DromeExceptionCatcher.perform {
            // format: nil asks the engine to use the bus’s native format.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
        }
        guard tapInstalled else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            presentVoiceFailure(
                session: session,
                title: "Voice Search unavailable",
                message: "Mic isn’t ready (common in Simulator). Try Type on iPhone.",
                disableVoice: true)
            return
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            presentVoiceFailure(
                session: session,
                title: "Voice Search failed",
                message: "Could not start listening. Try Type on iPhone.",
                disableVoice: true)
            return
        }

        audioEngine = engine
        speechRequest = request

        var finished = false
        speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let query = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    voiceTemplate.activateVoiceControlState(withIdentifier: "working")
                    self.stopSpeechRecognition()
                    self.dismissVoiceTemplate { [weak self] in
                        guard let self else { return }
                        guard !query.isEmpty else {
                            self.presentVoiceFailure(
                                session: session,
                                title: "Try again",
                                message: "I didn’t catch that.",
                                disableVoice: false)
                            return
                        }
                        Task { await self.showSearchResults(query: query, session: session, title: "“\(query)”") }
                    }
                    return
                }
                if error != nil {
                    finished = true
                    self.stopSpeechRecognition()
                    self.presentVoiceFailure(
                        session: session,
                        title: "Voice Search failed",
                        message: "Try Type on iPhone.",
                        disableVoice: true)
                }
            }
        }

        // Auto-stop if the user never finishes a phrase.
        voiceSearchTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stopSpeechRecognition()
            self.dismissVoiceTemplate()
        }
    }

    private func stopSpeechRecognition() {
        speechRequest?.endAudio()
        speechRequest = nil
        if let engine = audioEngine {
            _ = DromeExceptionCatcher.perform {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
        }
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    private func dismissVoiceTemplate(completion: (() -> Void)? = nil) {
        guard let interfaceController else {
            completion?()
            return
        }
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: true) { _, _ in
                completion?()
            }
        } else {
            completion?()
        }
    }

    /// Voice failure: dismiss voice UI, show alert; OK returns to Search and
    /// optionally greys out Ask for a song.
    private func presentVoiceFailure(
        session: AppSession,
        title: String,
        message: String,
        disableVoice: Bool
    ) {
        stopSpeechRecognition()
        if disableVoice {
            voiceSearchDisabled = true
        }
        dismissVoiceTemplate { [weak self] in
            guard let self, let interfaceController = self.interfaceController else { return }
            let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.returnToSearchTab(session: session)
            }
            let alert = CPAlertTemplate(
                titleVariants: ["\(title). \(message)"],
                actions: [ok])
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
        }
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
        let result = try? await session.client.search(
            query, artistCount: 12, albumCount: 12, songCount: 24)

        var sections: [CPListSection] = []

        let songs = result?.song ?? []
        if !songs.isEmpty {
            sections.append(CPListSection(
                items: songItems(songs, label: query, kind: .search, session: session),
                header: "Songs",
                sectionIndexTitle: nil))
        }

        let albums = result?.album ?? []
        if !albums.isEmpty {
            sections.append(CPListSection(
                items: albumItems(albums, session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }

        let artists = Self.artistsWithEmptyAlbumsLast(result?.artist ?? [])
        if !artists.isEmpty {
            let items: [CPListItem] = artists.map { artist in
                let item = CPListItem(
                    text: artist.name,
                    detailText: artist.albumCount.map { "\($0) albums" })
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    Task {
                        await self?.showArtist(id: artist.id, name: artist.name, session: session)
                        completion()
                    }
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Artists", sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            sections = [CPListSection(items: [
                CPListItem(text: "No results", detailText: "Nothing matched “\(query)”")
            ])]
        }

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
                detail: playlist.songCount.map { "\($0) songs" } ?? "Playlist",
                coverArt: playlist.coverArt,
                fallbackId: playlist.id,
                session: session)
            item.accessoryType = .disclosureIndicator
            if session.downloads.isPlaylistFullyDownloaded(
                playlistId: playlist.id, expectedCount: playlist.songCount ?? 0)
            {
                item.setAccessoryImage(UIImage(systemName: "arrow.down.circle.fill"))
            }
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showPlaylist(id: playlist.id, name: playlist.name, session: session)
                    completion()
                }
            }
            return item
        }
    }

    private func albumItems(_ albums: [Album], session: AppSession) -> [CPListItem] {
        albums.map { album in
            let item = listItem(
                text: album.name,
                detail: album.artist,
                coverArt: album.coverArt,
                fallbackId: album.id,
                session: session)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.showAlbum(id: album.id, name: album.name, session: session)
                    completion()
                }
            }
            return item
        }
    }

    private func songItems(_ songs: [Song], label: String,
                           kind: PlaybackContext.Kind, session: AppSession) -> [CPListItem] {
        songs.enumerated().map { index, song in
            let item = listItem(
                text: song.title,
                detail: song.artist,
                coverArt: song.coverArt,
                fallbackId: song.albumId ?? song.id,
                session: session)
            item.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: index, label: label, kind: kind, session: session)
                completion()
            }
            return item
        }
    }

    private func showPlaylist(id: String, name: String, session: AppSession) async {
        guard let interfaceController else { return }
        guard let playlist = try? await session.client.playlist(id: id) else { return }

        var items: [CPListItem] = []
        let kind: PlaybackContext.Kind = playlist.name == RotationManager.playlistName
            ? .outOfRotation : .playlist(id: id)

        if !playlist.songs.isEmpty {
            let playAll = CPListItem(text: "Play", detailText: "\(playlist.songs.count) songs")
            playAll.handler = { [weak self] _, completion in
                self?.playSongs(playlist.songs, startAt: 0, label: name, kind: kind, session: session)
                completion()
            }
            items.append(playAll)

            let shuffle = CPListItem(text: "Shuffle", detailText: nil)
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

        if items.isEmpty {
            items = [CPListItem(text: "Empty playlist", detailText: nil)]
        }

        let detail = CPListTemplate(title: name, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(detail, animated: true, completion: nil)
    }

    private func showAlbum(id: String, name: String, session: AppSession) async {
        guard let interfaceController else { return }
        guard let album = try? await session.client.album(id: id),
              !album.songs.isEmpty else { return }

        var items: [CPListItem] = []
        let playAll = CPListItem(text: "Play Album", detailText: "\(album.songs.count) songs")
        playAll.handler = { [weak self] _, completion in
            self?.playSongs(album.songs, startAt: 0, label: name, kind: .album, session: session)
            completion()
        }
        items.append(playAll)

        let shuffle = CPListItem(text: "Shuffle", detailText: nil)
        shuffle.handler = { [weak self] _, completion in
            session.player.playShuffled(album.songs,
                                        context: PlaybackContext(label: name, kind: .album))
            self?.pushNowPlaying()
            completion()
        }
        items.append(shuffle)
        items.append(contentsOf: songItems(album.songs, label: name, kind: .album, session: session))

        let detail = CPListTemplate(title: name, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(detail, animated: true, completion: nil)
    }

    private func showArtist(id: String, name: String, session: AppSession) async {
        guard let interfaceController else { return }
        let songs = (try? await session.client.topSongs(artistName: name, count: 40)) ?? []
        let albums = (try? await session.client.artist(id: id))?.albums ?? []

        var sections: [CPListSection] = []
        if !songs.isEmpty {
            var items: [CPListItem] = []
            let playTop = CPListItem(text: "Play Top Songs", detailText: nil)
            playTop.handler = { [weak self] _, completion in
                self?.playSongs(songs, startAt: 0, label: name, kind: .artist, session: session)
                completion()
            }
            items.append(playTop)
            items.append(contentsOf: songItems(songs, label: name, kind: .artist, session: session))
            sections.append(CPListSection(items: items, header: "Top Songs", sectionIndexTitle: nil))
        }
        if !albums.isEmpty {
            sections.append(CPListSection(
                items: albumItems(albums, session: session),
                header: "Albums",
                sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            sections = [CPListSection(items: [CPListItem(text: "Nothing found", detailText: nil)])]
        }

        let detail = CPListTemplate(title: name, sections: sections)
        interfaceController.pushTemplate(detail, animated: true, completion: nil)
    }

    // MARK: - Artwork + playback helpers

    private func listItem(text: String, detail: String?, coverArt: String?,
                          fallbackId: String?, session: AppSession) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        attachArtwork(to: item, coverArt: coverArt, fallbackId: fallbackId, session: session)
        return item
    }

    private func attachArtwork(to item: CPListItem, coverArt: String?,
                               fallbackId: String?, session: AppSession) {
        guard let url = session.artworkURL(id: coverArt ?? fallbackId, size: 180) else { return }
        if let cached = ImageLoader.shared.cachedImage(for: url) {
            item.setImage(Self.scaledListImage(cached))
            return
        }
        Task {
            guard let image = await ImageLoader.shared.image(for: url) else { return }
            item.setImage(Self.scaledListImage(image))
        }
    }

    private static func scaledListImage(_ image: UIImage) -> UIImage {
        let maxSize = CPListItem.maximumImageSize
        let renderer = UIGraphicsImageRenderer(size: maxSize)
        return renderer.image { _ in
            let scale = min(maxSize.width / max(image.size.width, 1),
                            maxSize.height / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (maxSize.width - size.width) / 2,
                                 y: (maxSize.height - size.height) / 2)
            image.draw(in: CGRect(origin: origin, size: size))
        }
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
    static let dromeSessionChanged = Notification.Name("drome.sessionChanged")
    static let dromeOpenNowPlaying = Notification.Name("drome.openNowPlaying")
    /// Focus the iPhone Search field so CarPlay can mirror a real QWERTY keyboard.
    static let dromeFocusCarPlaySearch = Notification.Name("drome.focusCarPlaySearch")
    /// CarPlay observes this while mirroring; `userInfo["query"]` is a String.
    static let dromeCarPlaySearchQuery = Notification.Name("drome.carPlaySearchQuery")
}

enum NowPlayingPresenter {
    static func open() {
        NotificationCenter.default.post(name: .dromeOpenNowPlaying, object: nil)
    }
}
