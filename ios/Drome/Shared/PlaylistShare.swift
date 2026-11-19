import UIKit
import LinkPresentation

/// Share a playlist the way we share tracks — deep link + friendly card.
/// Recipients on the same Navidrome open the playlist; others still get the name.
enum PlaylistShare {
    static func url(playlistId: String) -> URL {
        URL(string: "drome://playlist/\(playlistId)")!
    }

    static func playURL(playlistId: String, name: String) -> URL {
        var components = URLComponents()
        components.scheme = "drome"
        components.host = "play"
        components.queryItems = [
            URLQueryItem(name: "resume", value: "playlist:\(playlistId)"),
            URLQueryItem(name: "entry", value: "playlist:\(playlistId)"),
        ]
        return components.url ?? url(playlistId: playlistId)
    }

    @MainActor
    static func present(playlist: Playlist, songs: [Song] = []) {
        guard !SharePrepHUD.isVisible else { return }
        SharePrepHUD.show()
        Task {
            await presentAsync(playlist: playlist, songs: songs)
            SharePrepHUD.hide()
        }
    }

    @MainActor
    private static func presentAsync(playlist: Playlist, songs: [Song]) async {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = playlist.songCount ?? songs.count
        let headline = count > 0 ? "\(name) · \(count) songs" : name
        let openURL = playURL(playlistId: playlist.id, name: name)

        let coverIDs = ([playlist.coverArt] + songs.prefix(4).compactMap { $0.coverArt ?? $0.albumId })
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var cover = ImageLoader.shared.previewCover(ids: coverIDs)
        if cover == nil, let env = AppEnvironment.shared?.session {
            for id in coverIDs {
                if let url = env.artworkURL(id: id, size: 300) {
                    cover = ImageLoader.shared.previewImage(for: url)
                    if cover != nil { break }
                }
            }
        }

        let metadata = LPLinkMetadata()
        metadata.originalURL = openURL
        metadata.url = openURL
        metadata.title = headline
        if let cover {
            metadata.imageProvider = NSItemProvider(object: cover)
        }

        let item = PlaylistShareItem(
            headline: headline,
            detail: "Open in Drome to play this playlist.",
            openURL: openURL,
            metadata: metadata)
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activity.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .openInIBooks,
        ]

        guard let presenter = SongShare.topViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        SharePrepHUD.hide()
        presenter.present(activity, animated: true)
    }
}

private final class PlaylistShareItem: NSObject, UIActivityItemSource {
    let headline: String
    let detail: String
    let openURL: URL
    let metadata: LPLinkMetadata

    init(headline: String, detail: String, openURL: URL, metadata: LPLinkMetadata) {
        self.headline = headline
        self.detail = detail
        self.openURL = openURL
        self.metadata = metadata
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        openURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        if activityType == .mail || activityType == .message {
            return "\(headline)\n\(detail)\n\(openURL.absoluteString)"
        }
        return openURL
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        metadata
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        headline
    }
}
