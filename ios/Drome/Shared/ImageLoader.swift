import UIKit
import SwiftUI
import ImageIO

/// Small async image loader with an in-memory cache. Uses the active
/// account's URLSession so self-signed-certificate trust applies to artwork.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var _session: URLSession = .shared

    var session: URLSession {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); defer { lock.unlock() }; _session = newValue }
    }

    init() {
        cache.countLimit = 400
        // ~64 MB of decoded bitmaps; prefer evicting by cost over count alone.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }

        let maxPixel = Self.maxPixelDimension(for: url)
        guard let image = Self.downsampledImage(data: data, maxPixel: maxPixel) else { return nil }
        let cost = Self.approximateCost(of: image)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Prefer the Subsonic `size=` query (already list-sized). Fallback keeps
    /// list art small even when the URL omits a size.
    private static func maxPixelDimension(for url: URL) -> CGFloat {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let sizeItem = items.first(where: { $0.name == "size" }),
              let value = sizeItem.value, let size = Double(value), size > 0
        else {
            return 240
        }
        // Decode at ~2× for retina list cells without loading full art.
        return CGFloat(min(max(size * 2, 120), 1200))
    }

    private static func downsampledImage(data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func approximateCost(of image: UIImage) -> Int {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return max(width * height * 4, 1)
    }
}

/// Artwork view backed by ImageLoader, with a music-note placeholder.
struct RemoteImage: View {
    let url: URL?
    var placeholderSymbol: String = "music.note"

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(white: 0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                return
            }
            // Keep the previous image on screen while a new URL loads so the
            // layout never flashes empty on every redraw.
            if loadedURL == url, image != nil { return }
            if let cached = await ImageLoader.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                image = cached
                loadedURL = url
            } else if loadedURL != url {
                guard !Task.isCancelled else { return }
                image = nil
                loadedURL = nil
            }
        }
    }
}
