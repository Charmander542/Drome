import CarPlay
import Foundation
import UIKit

/// CarPlay entry point. Wired in Info.plist under
/// `CPTemplateApplicationSceneSessionRoleApplication`.
///
/// Capabilities today:
/// - Playlists → song list with Play / Shuffle / per-track start
/// - Library → recent & frequent albums, plus artists → top songs
/// - Now Playing (system template) with shuffle / repeat / autoplay buttons
/// - Lock-screen / CarPlay transport via `MPNowPlayingInfoCenter`
///
/// Real cars require Apple-approved `com.apple.developer.carplay-audio`
/// entitlement (request via developer.apple.com). It is intentionally omitted
/// from Drome.entitlements so normal development signing works; the Simulator
/// CarPlay window still brings up this UI without that entitlement.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        configureNowPlayingTemplate()
        rebuildRoot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionChanged),
            name: .dromeSessionChanged, object: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        tabBar = nil
        NotificationCenter.default.removeObserver(self)
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

        let playlists = makePlaylistsTemplate(session: session)
        let library = makeLibraryTemplate(session: session)
        let nowPlaying = CPNowPlayingTemplate.shared

        let tabs = CPTabBarTemplate(templates: [playlists, library, nowPlaying])
        tabBar = tabs
        interfaceController.setRootTemplate(tabs, animated: true, completion: nil)
    }

    private func configureNowPlayingTemplate() {
        let np = CPNowPlayingTemplate.shared
        np.isUpNextButtonEnabled = false
        np.isAlbumArtistButtonEnabled = false

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

        np.updateNowPlayingButtons([shuffle, repeatButton, autoplay])
        refreshNowPlayingButtons()
    }

    private func refreshNowPlayingButtons() {
        guard let player = AppEnvironment.shared?.session?.player else { return }
        let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
        for button in buttons {
            if button is CPNowPlayingShuffleButton {
                button.isSelected = player.shuffleMode != .off
            } else if button is CPNowPlayingRepeatButton {
                button.isSelected = player.repeatMode != .off
            } else if button is CPNowPlayingImageButton {
                button.isSelected = player.autoplayEnabled
            }
        }
    }

    // MARK: - Playlists tab

    private func makePlaylistsTemplate(session: AppSession) -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        template.tabImage = UIImage(systemName: "music.note.list")
        template.tabTitle = "Playlists"

        Task {
            let lists = (try? await session.client.playlists()) ?? []
            if lists.isEmpty {
                template.updateSections([CPListSection(items: [
                    CPListItem(text: "No playlists", detailText: "Create one on your iPhone")
                ])])
                return
            }
            let items: [CPListItem] = lists.map { playlist in
                let item = CPListItem(
                    text: playlist.name,
                    detailText: playlist.songCount.map { "\($0) songs" })
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    Task {
                        await self?.showPlaylist(id: playlist.id, name: playlist.name, session: session)
                        completion()
                    }
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
        return template
    }

    private func showPlaylist(id: String, name: String, session: AppSession) async {
        guard let interfaceController else { return }
        guard let playlist = try? await session.client.playlist(id: id) else {
            return
        }

        var items: [CPListItem] = []

        if !playlist.songs.isEmpty {
            let playAll = CPListItem(text: "Play", detailText: "\(playlist.songs.count) songs")
            playAll.handler = { [weak self] _, completion in
                self?.playSongs(playlist.songs, startAt: 0, label: name,
                                kind: playlist.name == RotationManager.playlistName
                                    ? .outOfRotation : .playlist(id: id),
                                session: session)
                completion()
            }
            items.append(playAll)

            let shuffle = CPListItem(text: "Shuffle", detailText: nil)
            shuffle.handler = { [weak self] _, completion in
                session.player.playShuffled(
                    playlist.songs,
                    context: PlaybackContext(
                        label: name,
                        kind: playlist.name == RotationManager.playlistName
                            ? .outOfRotation : .playlist(id: id)))
                self?.pushNowPlaying()
                completion()
            }
            items.append(shuffle)
        }

        for (index, song) in playlist.songs.enumerated() {
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.handler = { [weak self] _, completion in
                self?.playSongs(playlist.songs, startAt: index, label: name,
                                kind: playlist.name == RotationManager.playlistName
                                    ? .outOfRotation : .playlist(id: id),
                                session: session)
                completion()
            }
            items.append(item)
        }

        if items.isEmpty {
            items = [CPListItem(text: "Empty playlist", detailText: nil)]
        }

        let detail = CPListTemplate(title: name, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(detail, animated: true, completion: nil)
    }

    // MARK: - Library tab

    private func makeLibraryTemplate(session: AppSession) -> CPListTemplate {
        let template = CPListTemplate(title: "Library", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        template.tabImage = UIImage(systemName: "square.stack")
        template.tabTitle = "Library"

        Task {
            async let recent = session.client.albumList(type: .recent, size: 12)
            async let frequent = session.client.albumList(type: .frequent, size: 12)
            async let artists = session.client.artists()

            let recentAlbums = (try? await recent) ?? []
            let frequentAlbums = (try? await frequent) ?? []
            let artistIndexes = (try? await artists) ?? []

            var sections: [CPListSection] = []

            if !recentAlbums.isEmpty {
                sections.append(CPListSection(
                    items: albumItems(recentAlbums, session: session),
                    header: "Recently Played",
                    sectionIndexTitle: nil))
            }
            if !frequentAlbums.isEmpty {
                sections.append(CPListSection(
                    items: albumItems(frequentAlbums, session: session),
                    header: "Heavy Rotation",
                    sectionIndexTitle: nil))
            }

            let flatArtists = artistIndexes.flatMap(\.artists).prefix(40)
            if !flatArtists.isEmpty {
                let items: [CPListItem] = flatArtists.map { artist in
                    let item = CPListItem(text: artist.name,
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
                    CPListItem(text: "Library unavailable", detailText: "Check your Navidrome connection")
                ])]
            }
            template.updateSections(sections)
        }
        return template
    }

    private func albumItems(_ albums: [Album], session: AppSession) -> [CPListItem] {
        albums.map { album in
            let item = CPListItem(text: album.name, detailText: album.artist)
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

        for (index, song) in album.songs.enumerated() {
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.handler = { [weak self] _, completion in
                self?.playSongs(album.songs, startAt: index, label: name, kind: .album, session: session)
                completion()
            }
            items.append(item)
        }

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
            for (index, song) in songs.enumerated() {
                let item = CPListItem(text: song.title, detailText: song.album)
                item.handler = { [weak self] _, completion in
                    self?.playSongs(songs, startAt: index, label: name, kind: .artist, session: session)
                    completion()
                }
                items.append(item)
            }
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

    // MARK: - Playback helpers

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
        // Prefer selecting the Now Playing tab when available.
        if let tabBar,
           let index = tabBar.templates.firstIndex(where: { $0 is CPNowPlayingTemplate }) {
            tabBar.selectTemplate(at: index)
            return
        }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}

extension Notification.Name {
    static let dromeSessionChanged = Notification.Name("drome.sessionChanged")
    static let dromeOpenNowPlaying = Notification.Name("drome.openNowPlaying")
}

enum NowPlayingPresenter {
    static func open() {
        NotificationCenter.default.post(name: .dromeOpenNowPlaying, object: nil)
    }
}
