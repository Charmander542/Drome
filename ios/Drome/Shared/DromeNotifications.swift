import Foundation

extension Notification.Name {
    static let dromeSessionChanged = Notification.Name("drome.sessionChanged")
    static let dromeOpenNowPlaying = Notification.Name("drome.openNowPlaying")
}

enum NowPlayingPresenter {
    static func open() {
        NotificationCenter.default.post(name: .dromeOpenNowPlaying, object: nil)
    }
}
