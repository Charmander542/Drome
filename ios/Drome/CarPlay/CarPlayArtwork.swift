import CarPlay
import UIKit

/// CarPlay list artwork — must be sized for the *car* screen scale
/// (`CPInterfaceController.carTraitCollection`), opaque, and exactly
/// `CPListItem.maximumImageSize`. Phone-scale bitmaps are often dropped silently.
@MainActor
enum CarPlayArtwork {
    /// Compact Navidrome covers — plenty for CarPlay tiles, fast to fetch.
    static let fetchSize = 200

    /// Set from `CarPlaySceneDelegate` on connect (car screen scale, not phone).
    static var carDisplayScale: CGFloat = 2.0

    private static var scaledCache = NSCache<NSString, UIImage>()
    private static var placeholderCache = NSCache<NSString, UIImage>()
    private static var prepared = false

    static func prepare() {
        guard !prepared else { return }
        prepared = true
        scaledCache.countLimit = 500
        placeholderCache.countLimit = 100
    }

    /// Point size CarPlay expects for list images (never zero).
    static var listPointSize: CGSize {
        let size = CPListItem.maximumImageSize
        if size.width >= 20, size.height >= 20 { return size }
        return CGSize(width: 90, height: 90)
    }

    // MARK: - Attach

    static func attach(
        to item: CPListItem,
        coverArt: String?,
        fallbackId: String?,
        session: AppSession,
        style: Style = .album
    ) {
        prepare()
        let title = item.text
        let key = (coverArt?.nilIfEmpty) ?? (fallbackId?.nilIfEmpty)

        // Always show something immediately.
        item.setImage(placeholder(style: style, title: title))

        guard let key,
              let url = session.artworkURL(id: key, size: fetchSize)
        else { return }

        let cacheKey = url.absoluteString as NSString
        if let scaled = scaledCache.object(forKey: cacheKey) {
            item.setImage(scaled)
            return
        }
        if let cached = ImageLoader.shared.cachedImage(for: url) {
            let scaled = carListImage(from: cached)
            scaledCache.setObject(scaled, forKey: cacheKey)
            item.setImage(scaled)
            return
        }

        // Hold the item; CarPlay updates the row when setImage is called later.
        Task { @MainActor in
            let image = await loadImage(url: url, session: session)
            guard let image else { return }
            let scaled = carListImage(from: image)
            scaledCache.setObject(scaled, forKey: cacheKey)
            item.setImage(scaled)
        }
    }

    static func prefetch(ids: [String], session: AppSession, limit: Int = 30) {
        prepare()
        let urls = ids.prefix(limit).compactMap { session.artworkURL(id: $0, size: fetchSize) }
        ImageLoader.shared.prefetch(Array(urls))
        // Also kick a few through our car-scaled cache path.
        for url in urls.prefix(12) {
            let cacheKey = url.absoluteString as NSString
            if scaledCache.object(forKey: cacheKey) != nil { continue }
            Task { @MainActor in
                guard let image = await loadImage(url: url, session: session) else { return }
                scaledCache.setObject(carListImage(from: image), forKey: cacheKey)
            }
        }
    }

    // MARK: - Load

    private static func loadImage(url: URL, session: AppSession) async -> UIImage? {
        if let image = await ImageLoader.shared.image(for: url) {
            return image
        }
        // Bypass ImageLoader failure cache — CarPlay connect can race before
        // ImageLoader.session is swapped to the account session.
        return await directFetch(url: url, session: session)
    }

    private static func directFetch(url: URL, session: AppSession) async -> UIImage? {
        let urlSession = ImageLoader.shared.session
        guard let (data, response) = try? await urlSession.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 24,
              let image = UIImage(data: data)
        else {
            // Last resort: account client session (self-signed trust).
            guard let (data, response) = try? await session.client.session.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return nil }
            ImageLoader.shared.cacheImage(image, for: url)
            return image
        }
        ImageLoader.shared.cacheImage(image, for: url)
        return image
    }

    // MARK: - Placeholders

    enum Style {
        case album, artist, playlist, song
    }

    static func placeholder(style: Style, title: String?) -> UIImage {
        prepare()
        let letter = monogram(from: title)
        let cacheKey = "\(Int(carDisplayScale))-\(style)-\(letter)-\(Int(listPointSize.width))" as NSString
        if let cached = placeholderCache.object(forKey: cacheKey) {
            return cached
        }
        let image = renderPlaceholder(letter: letter, style: style)
        placeholderCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func monogram(from title: String?) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "♪" }
        return String(first).uppercased()
    }

    private static func renderPlaceholder(letter: String, style: Style) -> UIImage {
        let pointSize = listPointSize
        let scale = max(carDisplayScale, 1)
        let pixel = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

        UIGraphicsBeginImageContextWithOptions(pointSize, true, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return UIImage(systemName: "music.note") ?? UIImage()
        }

        let colors = gradient(for: style, letter: letter)
        let cgColors = colors.map(\.cgColor) as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cgColors,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: pointSize.width, y: pointSize.height),
                options: [])
        } else {
            UIColor(white: 0.2, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: pointSize))
        }

        let fontSize = min(pointSize.width, pointSize.height) * 0.4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let textSize = (letter as NSString).size(withAttributes: attrs)
        let point = CGPoint(
            x: (pointSize.width - textSize.width) / 2,
            y: (pointSize.height - textSize.height) / 2)
        (letter as NSString).draw(at: point, withAttributes: attrs)

        _ = pixel // silence unused if optimizer complains
        return UIGraphicsGetImageFromCurrentImageContext()
            ?? UIImage(systemName: "music.note")
            ?? UIImage()
    }

    private static func gradient(for style: Style, letter: String) -> [UIColor] {
        let scalar = Int(letter.uppercased().unicodeScalars.first?.value ?? 65)
        let hue = CGFloat((scalar * 37) % 360) / 360.0
        switch style {
        case .artist:
            return [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1),
                UIColor(hue: hue, saturation: 0.65, brightness: 0.25, alpha: 1),
            ]
        case .playlist:
            return [
                UIColor(hue: 0.58, saturation: 0.50, brightness: 0.45, alpha: 1),
                UIColor(hue: 0.72, saturation: 0.55, brightness: 0.25, alpha: 1),
            ]
        case .song, .album:
            return [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.48, alpha: 1),
                UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                        saturation: 0.65, brightness: 0.26, alpha: 1),
            ]
        }
    }

    // MARK: - Car-scaled list image

    /// Opaque UIImage at exact CarPlay list size + car display scale.
    static func carListImage(from image: UIImage) -> UIImage {
        let pointSize = listPointSize
        let scale = max(carDisplayScale, 1)

        UIGraphicsBeginImageContextWithOptions(pointSize, true /* opaque */, scale)
        defer { UIGraphicsEndImageContext() }

        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: pointSize))

        let fill = max(
            pointSize.width / max(image.size.width, 1),
            pointSize.height / max(image.size.height, 1))
        let drawSize = CGSize(width: image.size.width * fill, height: image.size.height * fill)
        let origin = CGPoint(
            x: (pointSize.width - drawSize.width) / 2,
            y: (pointSize.height - drawSize.height) / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
