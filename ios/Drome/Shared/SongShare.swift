import UIKit
import LinkPresentation

/// Builds share payloads that work in Messages, Discord, Mail, etc.
enum SongShare {
    static func url(songId: String) -> URL {
        URL(string: "drome://track/\(songId)")!
    }

    @MainActor
    static func present(song: Song) {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.displayArtist
        let headline: String = {
            if artist.isEmpty { return title }
            return "\(title) — \(artist)"
        }()
        let link = url(songId: song.id)

        let item = ShareItem(headline: headline, url: link)
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activity.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .openInIBooks,
        ]

        guard let presenter = topViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    /// Back-compat for call sites that only have an id.
    @MainActor
    static func present(songId: String, title: String? = nil) {
        var song = Song(id: songId, title: title ?? "Track")
        song.artist = nil
        present(song: song)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Provides both plain text and a URL so Messages / Discord / Mail always
    /// get a useful payload, plus LPLinkMetadata for rich previews.
    private final class ShareItem: NSObject, UIActivityItemSource {
        let headline: String
        let url: URL

        init(headline: String, url: URL) {
            self.headline = headline
            self.url = url
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            "\(headline)\n\(url.absoluteString)"
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            itemForActivityType activityType: UIActivity.ActivityType?
        ) -> Any? {
            // Discord / Messages / Mail: text + link as one string is the most
            // reliably pasteable / sendable format for custom schemes.
            if activityType == .message
                || activityType == .mail
                || activityType?.rawValue.contains("discord") == true
                || activityType?.rawValue.contains("Slack") == true {
                return "\(headline)\n\(url.absoluteString)"
            }
            return "\(headline)\n\(url.absoluteString)"
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            subjectForActivityType activityType: UIActivity.ActivityType?
        ) -> String {
            headline
        }

        func activityViewControllerLinkMetadata(
            _ activityViewController: UIActivityViewController
        ) -> LPLinkMetadata? {
            let meta = LPLinkMetadata()
            meta.title = headline
            meta.originalURL = url
            meta.url = url
            return meta
        }
    }
}
