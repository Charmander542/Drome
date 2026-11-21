import Foundation

extension Notification.Name {
    static let dromeSessionChanged = Notification.Name("drome.sessionChanged")
    static let dromeOpenNowPlaying = Notification.Name("drome.openNowPlaying")
    static let dromeNetworkPathChanged = Notification.Name("drome.networkPathChanged")
    static let dromeOpenPlaylist = Notification.Name("drome.openPlaylist")
    static let dromeReplayOnboarding = Notification.Name("drome.replayOnboarding")
    static let dromeReloadGenres = Notification.Name("drome.reloadGenres")
}

enum NowPlayingPresenter {
    static func open() {
        NotificationCenter.default.post(name: .dromeOpenNowPlaying, object: nil)
    }
}

enum PlaylistPresenter {
    static let playlistIDKey = "playlistId"

    static func open(playlistId: String) {
        NotificationCenter.default.post(
            name: .dromeOpenPlaylist,
            object: nil,
            userInfo: [playlistIDKey: playlistId])
    }
}

enum OnboardingPresenter {
    static func replay() {
        NotificationCenter.default.post(name: .dromeReplayOnboarding, object: nil)
    }
}
