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
    /// Dedupes concurrent fetches for the same cover URL.
    private var inflight: [NSString: Task<UIImage?, Never>] = [:]
    /// Skip hammering IDs that returned non-images (XML errors, empty bodies).
    private var failed = Set<NSString>()
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrentFetches = 12

    var session: URLSession {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); defer { lock.unlock() }; _session = newValue }
    }

    init() {
        cache.countLimit = 1200
        // ~192 MB of decoded bitmaps; prefer evicting by cost over count alone.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        lock.lock()
        if failed.contains(key) {
            lock.unlock()
            return nil
        }
        if let existing = inflight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquireFetchSlot()
            defer { self.releaseFetchSlot() }
            return await self.fetchAndDecode(url: url, key: key)
        }
        inflight[key] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inflight[key] = nil
        lock.unlock()
        return image
    }

    /// Warm the cache for nearby list cells so fast flings paint like a back-nav.
    func prefetch(_ urls: [URL], limit: Int = 24) {
        var started = 0
        for url in urls {
            guard started < limit else { break }
            let key = url.absoluteString as NSString
            lock.lock()
            let skip = cache.object(forKey: key) != nil
                || failed.contains(key)
                || inflight[key] != nil
            lock.unlock()
            guard !skip else { continue }
            started += 1
            Task(priority: .utility) { _ = await image(for: url) }
        }
    }

    /// Synchronous memory lookup so list cells can paint without awaiting.
    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Insert a decoded image (e.g. freshly saved offline cover art).
    func cacheImage(_ image: UIImage, for url: URL) {
        let cost = Self.approximateCost(of: image)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
        lock.lock()
        failed.remove(url.absoluteString as NSString)
        lock.unlock()
    }

    func removeCached(for url: URL) {
        let key = url.absoluteString as NSString
        cache.removeObject(forKey: key)
        lock.lock()
        failed.remove(key)
        lock.unlock()
    }

    // MARK: - Fetch

    private func fetchAndDecode(url: URL, key: NSString) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else {
            markFailed(key)
            return nil
        }

        let maxPixel = Self.maxPixelDimension(for: url)
        let image = await Task.detached(priority: .utility) {
            Self.downsampledImage(data: data, maxPixel: maxPixel)
        }.value
        guard let image else {
            markFailed(key)
            return nil
        }
        let cost = Self.approximateCost(of: image)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private func markFailed(_ key: NSString) {
        lock.lock()
        failed.insert(key)
        // Cap so a bad session can't grow forever.
        if failed.count > 400 {
            failed.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    private func acquireFetchSlot() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeFetches < maxConcurrentFetches {
                activeFetches += 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    private func releaseFetchSlot() {
        lock.lock()
        if !waiters.isEmpty {
            // Transfer the slot to the next waiter.
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            activeFetches = max(0, activeFetches - 1)
            lock.unlock()
        }
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
        // Empty / HTML / XML error bodies — don't ask ImageIO for a thumbnail
        // (that logs CGImageSourceCreateThumbnailAtIndex … 'n/a').
        guard data.count > 24, !Self.looksLikeNonImage(data) else { return nil }

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            return UIImage(data: data)
        }

        if let type = CGImageSourceGetType(source) as String? {
            let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty || normalized == "n/a" || normalized == "public.data" {
                return UIImage(data: data)
            }
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        // Quiet fallback — some formats thumbnail poorly but still decode.
        return UIImage(data: data)
    }

    private static func looksLikeNonImage(_ data: Data) -> Bool {
        // '<', '{', '[' → HTML/XML/JSON error payloads from the server.
        guard let first = data.first else { return true }
        switch first {
        case 0x3C, 0x7B, 0x5B: return true
        default: break
        }
        // JPEG / PNG / GIF / WebP / BMP magic
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return false }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return false }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return false }
        if data.count >= 12,
           data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return false
        }
        if data.starts(with: [0x42, 0x4D]) { return false }
        // Unknown — let ImageIO try without forcing the thumbnail path first.
        return false
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
        .onAppear { applyURL(url, preferKeepExisting: true) }
        .onChange(of: url) { _, newURL in
            applyURL(newURL, preferKeepExisting: false)
        }
        .task(id: url) {
            guard let url else { return }
            if loadedURL == url, image != nil { return }
            if ImageLoader.shared.cachedImage(for: url) != nil { return }
            if let loaded = await ImageLoader.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                // Only replace if we still want this URL.
                if self.url == url {
                    image = loaded
                    loadedURL = url
                }
            }
        }
    }

    /// Sync cache hit immediately so strip rotations never flash the wrong art
    /// or an empty placeholder for a frame.
    private func applyURL(_ newURL: URL?, preferKeepExisting: Bool) {
        guard let newURL else {
            image = nil
            loadedURL = nil
            return
        }
        if loadedURL == newURL, image != nil { return }
        if let cached = ImageLoader.shared.cachedImage(for: newURL) {
            image = cached
            loadedURL = newURL
            return
        }
        // Async path will fill in; keep current bitmap only when asked (appear).
        if !preferKeepExisting {
            // Avoid sticking on the previous track's art after a strip rotate.
            // Prefer a neutral fill over the wrong album for a frame.
            image = nil
            loadedURL = nil
        }
    }
}
