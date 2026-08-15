import UIKit
import LinkPresentation
import UniformTypeIdentifiers

/// Builds share payloads that work in Messages, Discord, Mail, etc.
///
/// `drome://` cannot be crawled for Open Graph, so album art has to be attached
/// on the share itself (`LPLinkMetadata` + the image). Messages still opens
/// Drome; Discord / Mail / copy get the HTTPS page.
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

        let coverIDs = [song.coverArt, song.albumId, song.id].compactMap { $0 }.filter { !$0.isEmpty }
        var cover = ImageLoader.shared.previewCover(ids: coverIDs)
        if cover == nil, let env = AppEnvironment.shared?.session {
            for id in coverIDs {
                if let url = env.artworkURL(id: id, size: 300) {
                    cover = ImageLoader.shared.previewImage(for: url)
                    if cover != nil { break }
                }
            }
            if cover == nil, let url = env.artworkURL(for: song, size: 300) {
                cover = await ImageLoader.shared.image(for: url)
            }
        }

        let appURL = url(songId: song.id)
        var webURL: URL?
        if let client = AppEnvironment.shared?.session?.wishlist {
            let jpeg = cover.flatMap(Self.shareJPEG(from:))
            let accent = cover.map(Self.accentHex(from:)) ?? "#3D7EFF"
            webURL = await withTimeout(seconds: 2.0) {
                try? await client.createTrackShare(
                    songId: song.id, title: title, artist: artist, album: album,
                    accent: accent, coverJPEG: jpeg)
            }
        }

        let metadata = linkMetadata(headline: headline, appURL: appURL, image: cover)
        let item = ShareItem(headline: headline, appURL: appURL, webURL: webURL, image: cover, metadata: metadata)
        var items: [Any] = [item]
        if let cover {
            items.append(CoverItem(image: cover))
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
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

    private static func linkMetadata(headline: String, appURL: URL, image: UIImage?) -> LPLinkMetadata {
        let meta = LPLinkMetadata()
        meta.title = headline
        meta.originalURL = appURL
        meta.url = appURL
        if let image, let jpeg = shareJPEG(from: image) {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
                completion(jpeg, nil)
                return Progress(totalUnitCount: 0)
            }
            meta.imageProvider = provider
            meta.iconProvider = provider
        }
        return meta
    }

    /// Small enough to upload quickly; sharp enough for OG / the share card.
    private static func shareJPEG(from image: UIImage) -> Data? {
        let maxEdge: CGFloat = 400
        let longest = max(image.size.width, image.size.height)
        let source: UIImage
        if longest > maxEdge {
            let scale = maxEdge / longest
            let size = CGSize(width: (image.size.width * scale).rounded(),
                              height: (image.size.height * scale).rounded())
            source = image.preparingThumbnail(of: size) ?? image
        } else {
            source = image
        }
        return source.jpegData(compressionQuality: 0.72)
    }

    @MainActor
    private static func withTimeout(seconds: TimeInterval, _ work: @escaping () async -> URL?) async -> URL? {
        await withTaskGroup(of: (Bool, URL?).self) { group in
            group.addTask { (true, await work()) }
            group.addTask {
                let ns = UInt64(max(seconds, 0.2) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return (false, nil)
            }
            var result: URL?
            while let (finished, url) = await group.next() {
                if finished {
                    result = url
                    group.cancelAll()
                    break
                }
                group.cancelAll()
                break
            }
            return result
        }
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
        let metadata: LPLinkMetadata

        init(headline: String, appURL: URL, webURL: URL?, image: UIImage?, metadata: LPLinkMetadata) {
            self.headline = headline
            self.appURL = appURL
            self.webURL = webURL
            self.image = image
            self.metadata = metadata
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            image ?? appURL
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            itemForActivityType activityType: UIActivity.ActivityType?
        ) -> Any? {
            let raw = activityType?.rawValue ?? ""
            if activityType == .mail
                || activityType == .copyToPasteboard
                || raw.localizedCaseInsensitiveContains("discord")
                || raw.localizedCaseInsensitiveContains("Slack") {
                let link = webURL ?? appURL
                return "\(headline)\n\(link.absoluteString)"
            }
            return metadata
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
            metadata
        }
    }

    /// iMessage cannot fetch art from `drome://`, so attach the JPEG as well.
    private final class CoverItem: NSObject, UIActivityItemSource {
        let image: UIImage

        init(image: UIImage) {
            self.image = image
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            image
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            itemForActivityType activityType: UIActivity.ActivityType?
        ) -> Any? {
            if activityType == .copyToPasteboard
                || activityType == .mail
                || activityType == .print {
                return nil
            }
            return image
        }
    }
}
