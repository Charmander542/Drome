import UIKit
import LinkPresentation
import UniformTypeIdentifiers
import MessageUI
import Messages

/// Builds share payloads that work in Messages, Discord, Mail, etc.
///
/// The system Messages tile stays in its usual slot. Tapping it opens
/// `MFMessageComposeViewController` with the live Drome card. Discord / Mail /
/// copy still get the HTTPS `/s/{token}` page.
enum SongShare {
    static func url(songId: String) -> URL {
        URL(string: "drome://track/\(songId)")!
    }

    @MainActor
    static func present(song: Song) {
        guard !SharePrepHUD.isVisible else { return }
        SharePrepHUD.show()
        Task {
            await presentAsync(song: song)
            SharePrepHUD.hide()
        }
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

        MessagesShareBridge.pushRecent(
            id: song.id,
            title: title,
            artist: artist,
            album: album,
            coverArt: song.coverArt ?? song.albumId)

        let appURL = url(songId: song.id)
        var webURL: URL?
        if let client = AppEnvironment.shared?.session?.wishlist {
            let jpeg = cover.flatMap(Self.shareJPEG(from:))
            let accent = cover.map(Self.accentHex(from:)) ?? "#3D7EFF"
            webURL = await withTimeout(seconds: 4.0) {
                try? await client.createTrackShare(
                    songId: song.id, title: title, artist: artist, album: album,
                    accent: accent, coverJPEG: jpeg)
            }
        }

        let metadata = linkMetadata(headline: headline, openURL: webURL ?? appURL, image: cover)
        let iMessage = SongIMessage.make(
            song: song, title: title, artist: artist, album: album,
            cover: cover, webURL: webURL,
            serverHost: AppEnvironment.shared?.session?.account.serverURL.host)
        let item = ShareItem(
            headline: headline, appURL: appURL, webURL: webURL,
            metadata: metadata, iMessage: iMessage)
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
        SharePrepHUD.hide()
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
    static func topViewController() -> UIViewController? {
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

    private static func linkMetadata(headline: String, openURL: URL, image: UIImage?) -> LPLinkMetadata {
        let meta = LPLinkMetadata()
        meta.title = headline
        meta.originalURL = openURL
        meta.url = openURL
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
        let metadata: LPLinkMetadata
        let iMessage: MSMessage

        init(headline: String, appURL: URL, webURL: URL?, metadata: LPLinkMetadata, iMessage: MSMessage) {
            self.headline = headline
            self.appURL = appURL
            self.webURL = webURL
            self.metadata = metadata
            self.iMessage = iMessage
        }

        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            webURL ?? appURL
        }

        func activityViewController(
            _ activityViewController: UIActivityViewController,
            itemForActivityType activityType: UIActivity.ActivityType?
        ) -> Any? {
            let raw = activityType?.rawValue ?? ""
            let link = webURL ?? appURL
            if isMessagesActivity(activityType),
               MFMessageComposeViewController.canSendText(),
               activityViewController.viewIfLoaded?.window != nil {
                let bubble = iMessage
                DispatchQueue.main.async {
                    activityViewController.dismiss(animated: true) {
                        MessageComposeCoordinator.shared.present(message: bubble)
                    }
                }
                return nil
            }
            if activityType == .mail
                || activityType == .copyToPasteboard
                || raw.localizedCaseInsensitiveContains("discord")
                || raw.localizedCaseInsensitiveContains("Slack") {
                return "\(headline)\n\(link.absoluteString)"
            }
            return link
        }

        private func isMessagesActivity(_ activityType: UIActivity.ActivityType?) -> Bool {
            guard let activityType else { return false }
            if activityType == .message { return true }
            let raw = activityType.rawValue
            return raw == "com.apple.UIKit.activity.Message"
                || raw.localizedCaseInsensitiveContains("MobileSMS")
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
}

/// Center pill so Share doesn’t feel dead while cover / token upload runs.
@MainActor
private enum SharePrepHUD {
    private static weak var container: UIView?
    static var isVisible: Bool { container != nil }

    static func show() {
        hide()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) else { return }

        let dim = UIView(frame: window.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dim.isUserInteractionEnabled = true
        dim.accessibilityViewIsModal = true

        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        pill.layer.cornerRadius = 16
        pill.clipsToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.startAnimating()

        let label = UILabel()
        label.text = "Preparing share"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(stack)
        dim.addSubview(pill)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -14),
            pill.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
        ])

        window.addSubview(dim)
        container = dim
        dim.alpha = 0
        UIView.animate(withDuration: 0.18) { dim.alpha = 1 }
    }

    static func hide() {
        guard let dim = container else { return }
        container = nil
        UIView.animate(withDuration: 0.12, animations: { dim.alpha = 0 }) { _ in
            dim.removeFromSuperview()
        }
    }
}
