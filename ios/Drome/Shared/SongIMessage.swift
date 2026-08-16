import MessageUI
import Messages
import UIKit

/// Builds an `MSMessage` the containing app can hand to
/// `MFMessageComposeViewController` — the official way to drop a live iMessage
/// bubble from Drome itself, not only from the Messages app drawer.
enum SongIMessage {
    static func make(
        song: Song,
        title: String,
        artist: String,
        album: String,
        cover: UIImage?,
        webURL: URL?,
        serverHost: String?
    ) -> MSMessage {
        let template = MSMessageTemplateLayout()
        template.image = MessageCardImage.render(cover: cover, title: title, artist: artist)
        template.caption = title
        template.subcaption = artist.isEmpty ? nil : artist

        let message = MSMessage()
        message.layout = MSMessageLiveLayout(alternateLayout: template)
        message.summaryText = artist.isEmpty ? title : "\(title) — \(artist)"
        message.url = messageURL(
            webURL: webURL, song: song, title: title, artist: artist,
            album: album, serverHost: serverHost)
        return message
    }

    /// iMessage drops `drome://` from `MSMessage.url`. Keep an http(s) URL with
    /// `song` / title / artist in the query so the live bubble can read it.
    static func messageURL(
        webURL: URL?,
        song: Song,
        title: String,
        artist: String,
        album: String,
        serverHost: String?
    ) -> URL {
        var comps: URLComponents
        if let webURL, let parsed = URLComponents(url: webURL, resolvingAgainstBaseURL: false),
           parsed.scheme == "http" || parsed.scheme == "https" {
            comps = parsed
        } else if let serverHost, !serverHost.isEmpty {
            comps = URLComponents(string: "https://\(serverHost)/drome-imessage") ?? URLComponents()
        } else {
            comps = URLComponents()
            comps.scheme = "https"
            comps.host = "app.drome.invalid"
            comps.path = "/t/\(song.id)"
        }
        var items = comps.queryItems ?? []
        func set(_ name: String, _ value: String?) {
            items.removeAll { $0.name == name }
            if let value, !value.isEmpty {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        set("song", song.id)
        set("title", title)
        set("artist", artist)
        set("album", album)
        set("cover", song.coverArt ?? song.albumId)
        set("server", serverHost)
        comps.queryItems = items
        return comps.url ?? webURL ?? URL(string: "https://app.drome.invalid/t/\(song.id)?song=\(song.id)")!
    }
}

enum MessageCardImage {
    static let art: CGFloat = 56
    static let height: CGFloat = 64
    static let width: CGFloat = 248

    static func render(cover: UIImage?, title: String, artist: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            UIColor.black.setFill()
            UIRectFill(bounds)

            let artRect = CGRect(x: 4, y: 4, width: art, height: art)
            UIGraphicsGetCurrentContext()?.saveGState()
            UIBezierPath(roundedRect: artRect, cornerRadius: 7).addClip()
            if let cover, cover.size.width > 0, cover.size.height > 0 {
                let scale = max(art / cover.size.width, art / cover.size.height)
                let w = cover.size.width * scale
                let h = cover.size.height * scale
                cover.draw(in: CGRect(x: artRect.midX - w / 2, y: artRect.midY - h / 2, width: w, height: h))
            } else {
                UIColor(white: 0.18, alpha: 1).setFill()
                UIBezierPath(rect: artRect).fill()
            }
            UIGraphicsGetCurrentContext()?.restoreGState()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let artistAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            ]
            (title as NSString).draw(in: CGRect(x: 68, y: 14, width: width - 76, height: 18), withAttributes: titleAttrs)
            if !artist.isEmpty {
                (artist as NSString).draw(in: CGRect(x: 68, y: 32, width: width - 76, height: 16), withAttributes: artistAttrs)
            }
        }
    }
}

final class SendIMessageActivity: UIActivity {
    let message: MSMessage

    init(message: MSMessage) {
        self.message = message
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .share }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("drome.app.sendIMessage")
    }

    override var activityTitle: String? { "Messages" }

    override var activityImage: UIImage? { Self.icon }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        MFMessageComposeViewController.canSendText()
    }

    override func perform() {
        let message = self.message
        activityDidFinish(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Task { @MainActor in
                MessageComposeCoordinator.shared.present(message: message)
            }
        }
    }

    /// Template glyph so the tile actually appears in the share sheet (SF Symbols
    /// as `activityImage` are often dropped).
    private static let icon: UIImage = {
        let side: CGFloat = 60
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let bubble = UIBezierPath(roundedRect: CGRect(x: 8, y: 10, width: 44, height: 32), cornerRadius: 10)
            bubble.move(to: CGPoint(x: 20, y: 42))
            bubble.addLine(to: CGPoint(x: 16, y: 52))
            bubble.addLine(to: CGPoint(x: 28, y: 42))
            bubble.close()
            UIColor.white.setFill()
            bubble.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}

final class MessageComposeCoordinator: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageComposeCoordinator()

    @MainActor
    func present(message: MSMessage) {
        guard MFMessageComposeViewController.canSendText() else { return }
        let compose = MFMessageComposeViewController()
        compose.message = message
        compose.messageComposeDelegate = self
        SongShare.topViewController()?.present(compose, animated: true)
    }

    func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        controller.dismiss(animated: true)
    }
}
