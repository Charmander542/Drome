import UIKit
import LinkPresentation

/// Builds share payloads that work in Messages, Discord, Mail, etc.
///
/// Messages opens whatever URL is in the bubble. We put `drome://track/{id}`
/// there so a tap goes straight into the app (album art comes from local
/// `LPLinkMetadata`, not the companion webpage). Discord / Slack / Mail still
/// get an HTTPS card when the companion is configured.
enum SongShare {
    static func url(songId: String) -> URL {
        URL(string: "drome://track/\(songId)")!
    }

    @MainActor
    static func present(song: Song) {
        Task { await presentAsync(song: song) }
    }

    @MainActor
    private static func presentAsync(song: Song) async {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.displayArtist
        let album = (song.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let headline: String = {
            if artist.isEmpty { return title }
            return "\(title) — \(artist)"
        }()

        var cover: UIImage?
        let coverIDs = [song.coverArt, song.albumId, song.id].compactMap { $0 }.filter { !$0.isEmpty }
        if let env = AppEnvironment.shared?.session {
            for id in coverIDs {
                if let url = env.artworkURL(id: id, size: 800),
                   let image = ImageLoader.shared.previewImage(for: url) {
                    cover = image
                    break
                }
            }
            if cover == nil, let url = env.artworkURL(for: song, size: 800) {
                cover = await ImageLoader.shared.image(for: url)
            }
        }

        let appURL = url(songId: song.id)
        var webURL: URL?
        if let client = AppEnvironment.shared?.session?.wishlist {
            let jpeg = cover.flatMap { $0.jpegData(compressionQuality: 0.82) }
            let accent = cover.map(Self.accentHex(from:)) ?? "#3D7EFF"
            webURL = try? await client.createTrackShare(
                songId: song.id, title: title, artist: artist, album: album,
                accent: accent, coverJPEG: jpeg)
        }

        let item = ShareItem(headline: headline, appURL: appURL, webURL: webURL, image: cover)
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

    private static func accentHex(from image: UIImage) -> String {
        guard let sample = image.preparingThumbnail(of: CGSize(width: 16, height: 16)),
              let cg = sample.cgImage else { return "#3D7EFF" }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return "#3D7EFF" }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "#3D7EFF" }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0, g = 0, b = 0, n = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            r += Int(data[i]); g += Int(data[i + 1]); b += Int(data[i + 2]); n += 1
        }
        guard n > 0 else { return "#3D7EFF" }
        return String(format: "#%02X%02X%02X", min(r / n, 255), min(g / n, 255), min(b / n, 255))
    }

    private final class ShareItem: NSObject, UIActivityItemSource {
        let headline: String
        let appURL: URL
        let webURL: URL?
        let image: UIImage?

        init(headline: String, appURL: URL, webURL: URL?, image: UIImage? = nil) {
            self.headline = headline
            self.appURL = appURL
            self.webURL = webURL
            self.image = image
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            appURL
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            itemForActivityType activityType: UIActivity.ActivityType?
        ) -> Any? {
            let raw = activityType?.rawValue ?? ""
            if activityType == .mail
                || raw.localizedCaseInsensitiveContains("discord")
                || raw.localizedCaseInsensitiveContains("Slack") {
                let link = webURL ?? appURL
                return "\(headline)\n\(link.absoluteString)"
            }
            // Messages, copy, AirDrop: open Drome directly.
            return appURL
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
            meta.originalURL = appURL
            meta.url = appURL
            if let image {
                meta.imageProvider = NSItemProvider(object: image)
                meta.iconProvider = NSItemProvider(object: image)
            }
            return meta
        }
    }
}
