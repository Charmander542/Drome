import UIKit
import SwiftUI
import ImageIO

/// Small async image loader with an in-memory cache. Uses the active
/// account's URLSession so self-signed-certificate trust applies to artwork.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    /// Best decoded bitmap per cover id so a list-size fetch can paint Now Playing
    /// immediately while a larger decode finishes.
    private let coverCache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var _session: URLSession = .shared
    /// Dedupes concurrent fetches for the same cover URL.
    private var inflight: [NSString: Task<UIImage?, Never>] = [:]
    /// Skip hammering IDs that returned non-images (XML errors, empty bodies).
    private var failed = Set<NSString>()
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrentFetches = 8
    /// Parsed cover URLs. Row bodies ask about the same URL several times
    /// per frame (exact cache, preview, identity); parsing query items each
    /// time showed up while scrolling.
    private var parsedRequests: [String: ParsedArtwork] = [:]
    private let diskQueue = DispatchQueue(label: "com.drome.cover-disk", qos: .utility)
    private let diskDirectory: URL
    private var diskWritesSinceTrim = 0

    var session: URLSession {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); defer { lock.unlock() }; _session = newValue }
    }

    init() {
        cache.countLimit = 1200
        // ~192 MB of decoded bitmaps; prefer evicting by cost over count alone.
        cache.totalCostLimit = 192 * 1024 * 1024
        coverCache.countLimit = 400
        coverCache.totalCostLimit = 96 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("DromeCoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL, priority: TaskPriority = .userInitiated) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            // Older builds decoded local covers at 240px — drop those so
            // Now Playing / heroes can re-decode at full resolution.
            if Self.shouldInvalidateStaleLocalDecode(url: url, image: cached) {
                cache.removeObject(forKey: key)
            } else {
                rememberCover(cached, for: url)
                return cached
            }
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
            return await self.fetchAndDecode(url: url, key: key, priority: priority)
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
            if let cached = cache.object(forKey: key) {
                lock.unlock()
                rememberCover(cached, for: url)
                continue
            }
            let skip = failed.contains(key) || inflight[key] != nil
            lock.unlock()
            guard !skip else { continue }
            started += 1
            Task(priority: .utility) { _ = await image(for: url, priority: .utility) }
        }
    }

    /// Synchronous memory lookup so list cells can paint without awaiting.
    func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        guard let cached = cache.object(forKey: key) else { return nil }
        if Self.shouldInvalidateStaleLocalDecode(url: url, image: cached) {
            cache.removeObject(forKey: key)
            return nil
        }
        return cached
    }

    private static func shouldInvalidateStaleLocalDecode(url: URL, image: UIImage) -> Bool {
        guard url.isFileURL else { return false }
        let pixels = max(image.size.width, image.size.height) * image.scale
        return pixels < 500
    }

    /// Insert a decoded image (e.g. freshly saved offline cover art).
    func cacheImage(_ image: UIImage, for url: URL) {
        let cost = Self.approximateCost(of: image)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
        rememberCover(image, for: url)
        lock.lock()
        failed.remove(url.absoluteString as NSString)
        lock.unlock()
    }

    func removeCached(for url: URL) {
        let key = url.absoluteString as NSString
        cache.removeObject(forKey: key)
        let identity = parsedArtwork(for: url).coverID ?? Self.coverIdentity(for: url)
        if let identity {
            coverCache.removeObject(forKey: identity as NSString)
            let prefix = Self.diskPrefix(coverID: identity, host: url.host ?? "")
            let directory = diskDirectory
            diskQueue.async {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                else { return }
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        lock.lock()
        failed.remove(key)
        parsedRequests.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }

    // MARK: - Fetch

    private func fetchAndDecode(
        url: URL,
        key: NSString,
        priority: TaskPriority,
        allowDisk: Bool = true
    ) async -> UIImage? {
        let parsed = parsedArtwork(for: url)
        // File URLs may carry a synthetic `?size=` tag for cache/decode sizing —
        // strip it before reading so FileManager / URLSession can open the path.
        let data: Data?
        let response: URLResponse?
        var fromDisk = false
        if parsed.isFile {
            data = try? Data(contentsOf: parsed.resource)
            response = nil
        } else if allowDisk, let cached = readDiskCover(parsed) {
            data = cached
            response = nil
            fromDisk = true
        } else {
            let result = try? await session.data(from: parsed.resource)
            data = result?.0
            response = result?.1
        }
        guard let data,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else {
            markFailed(key)
            return nil
        }

        let maxPixel = parsed.maxPixel
        let image = await Task.detached(priority: priority) {
            Self.downsampledImage(data: data, maxPixel: maxPixel)
        }.value
        guard let image else {
            if fromDisk {
                // Corrupt cache file — forget it and pull the cover again.
                if let file = diskFileURL(parsed) {
                    try? FileManager.default.removeItem(at: file)
                }
                return await fetchAndDecode(url: url, key: key, priority: priority, allowDisk: false)
            }
            markFailed(key)
            return nil
        }
        let cost = Self.approximateCost(of: image)
        cache.setObject(image, forKey: key, cost: cost)
        rememberCover(image, for: url)
        // Media URLs carry a per-launch salt, so URLCache never survives a
        // relaunch. Keep the server's already-sized bytes under the cover id.
        if !parsed.isFile, !fromDisk {
            writeDiskCover(data, parsed: parsed)
        }
        return image
    }

    /// Any previously decoded size for this cover — used so the player never
    /// flashes a placeholder while a larger fetch is in flight.
    /// Oversized hero bitmaps are withheld from list-sized requests so scroll
    /// cells don't composite 1200px textures.
    func previewImage(for url: URL) -> UIImage? {
        if let exact = cachedImage(for: url) { return exact }
        let parsed = parsedArtwork(for: url)
        if let id = parsed.coverID,
           let preview = coverCache.object(forKey: id as NSString) {
            let pixels = max(preview.size.width, preview.size.height) * preview.scale
            if pixels <= parsed.maxPixel * 1.35 {
                return preview
            }
        }
        return nil
    }

    /// Off-main downsample for freshly saved offline covers.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        downsampledImage(data: data, maxPixel: maxPixel)
    }

    /// Strip synthetic query items from file URLs before disk I/O.
    static func resourceURL(for url: URL) -> URL {
        guard url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query != nil
        else { return url }
        components.query = nil
        return components.url ?? url
    }

    /// Tag a local cover file with the requested display size so decode/cache
    /// keys match remote `size=` URLs.
    static func sizedFileURL(_ url: URL, size: Int) -> URL {
        guard url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "size" }
        items.append(URLQueryItem(name: "size", value: String(max(1, size))))
        components.queryItems = items
        return components.url ?? url
    }

    /// Instant cover lookup by Navidrome ids (no network).
    func previewCover(ids: [String]) -> UIImage? {
        for id in ids where !id.isEmpty {
            if let image = coverCache.object(forKey: id as NSString) {
                return image
            }
        }
        return nil
    }

    private func rememberCover(_ image: UIImage, for url: URL) {
        guard let id = parsedArtwork(for: url).coverID else { return }
        let key = id as NSString
        if let existing = coverCache.object(forKey: key) {
            let old = max(existing.size.width, existing.size.height) * existing.scale
            let new = max(image.size.width, image.size.height) * image.scale
            if new < old { return }
        }
        coverCache.setObject(image, forKey: key, cost: Self.approximateCost(of: image))
    }

    private struct ParsedArtwork {
        var resource: URL
        var coverID: String?
        var maxPixel: CGFloat
        var isFile: Bool
    }

    private func parsedArtwork(for url: URL) -> ParsedArtwork {
        let key = url.absoluteString
        lock.lock()
        if let cached = parsedRequests[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let parsed = Self.makeParsedArtwork(url)
        lock.lock()
        if parsedRequests.count > 2500 {
            parsedRequests.removeAll(keepingCapacity: true)
        }
        parsedRequests[key] = parsed
        lock.unlock()
        return parsed
    }

    private static func makeParsedArtwork(_ url: URL) -> ParsedArtwork {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems
        let coverID: String? = {
            if let id = items?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
                return id
            }
            if url.isFileURL {
                let name = url.deletingPathExtension().lastPathComponent
                return name.isEmpty ? nil : name
            }
            return nil
        }()
        let maxPixel: CGFloat = {
            if let value = items?.first(where: { $0.name == "size" })?.value,
               let size = Double(value), size > 0 {
                return CGFloat(min(max(size * 2, 120), 1200))
            }
            return url.isFileURL ? 1200 : 600
        }()
        let resource: URL = {
            guard url.isFileURL, components?.query != nil, var stripped = components else { return url }
            stripped.query = nil
            return stripped.url ?? url
        }()
        return ParsedArtwork(
            resource: resource,
            coverID: coverID,
            maxPixel: maxPixel,
            isFile: url.isFileURL)
    }

    /// Original server bytes, keyed by cover id + decode size so a relaunch
    /// (new media salt, home/away host) still paints from disk.
    private func diskFileURL(_ parsed: ParsedArtwork) -> URL? {
        guard let id = parsed.coverID else { return nil }
        let name = Self.diskPrefix(coverID: id, host: parsed.resource.host ?? "")
            + "\(Int(parsed.maxPixel.rounded())).img"
        return diskDirectory.appendingPathComponent(name)
    }

    /// Host is part of the key so two Navidrome servers can't share a cover id
    /// and paint the wrong album.
    private static func diskPrefix(coverID: String, host: String) -> String {
        func safe(_ raw: String) -> String {
            let mapped = raw.map { $0.isLetter || $0.isNumber ? $0 : "_" }
            return "\(mapped.count)_\(String(mapped))"
        }
        return "h\(safe(host))__c\(safe(coverID))__"
    }

    private func readDiskCover(_ parsed: ParsedArtwork) -> Data? {
        guard let file = diskFileURL(parsed) else { return nil }
        return try? Data(contentsOf: file)
    }

    private func writeDiskCover(_ data: Data, parsed: ParsedArtwork) {
        guard data.count > 24, data.count < 4_000_000, let file = diskFileURL(parsed) else { return }
        let directory = diskDirectory
        diskQueue.async { [weak self] in
            try? data.write(to: file, options: .atomic)
            guard let self else { return }
            self.diskWritesSinceTrim += 1
            if self.diskWritesSinceTrim >= 24 {
                self.diskWritesSinceTrim = 0
                Self.trimCoverDisk(directory)
            }
        }
    }

    /// Keep roughly 120 MB / 1500 covers. Oldest files go first.
    private static func trimCoverDisk(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let ranked = files.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        let maxFiles = 1500
        let maxBytes = 120_000_000
        var total = ranked.reduce(0) { $0 + $1.2 }
        for (index, entry) in ranked.enumerated() {
            if index < maxFiles && total <= maxBytes { continue }
            total -= entry.2
            try? fm.removeItem(at: entry.0)
        }
    }

    static func coverIdentity(for url: URL) -> String? {
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return id
        }
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
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

    /// Prefer the Subsonic `size=` query (already list-sized). Local cover
    /// files have no size query — decode them large enough for Now Playing.
    private static func maxPixelDimension(for url: URL) -> CGFloat {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let sizeItem = items.first(where: { $0.name == "size" }),
              let value = sizeItem.value, let size = Double(value), size > 0
        else {
            return url.isFileURL ? 1200 : 600
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
    /// When true, keep the last bitmap until the next cover is ready so the
    /// player never flashes the music-note placeholder.
    var holdImageWhileLoading: Bool = false

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        // Prefer state, but fall back to the memory cache on the first frame so a
        // remount (e.g. dismiss gesture tree churn) never flashes the placeholder.
        let displayed = image ?? url.flatMap { ImageLoader.shared.previewImage(for: $0) }
        ZStack {
            Rectangle()
                .fill(Color(white: 0.16))
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onAppear { applyURL(url, preferKeepExisting: true) }
        .onChange(of: url) { _, newURL in
            applyURL(newURL, preferKeepExisting: holdImageWhileLoading)
        }
        .task(id: url) {
            guard let url else { return }
            if loadedURL == url, image != nil { return }
            if let preview = ImageLoader.shared.previewImage(for: url), image == nil || loadedURL != url {
                image = preview
                if ImageLoader.shared.cachedImage(for: url) != nil {
                    loadedURL = url
                    return
                }
            }
            if ImageLoader.shared.cachedImage(for: url) != nil { return }
            if let loaded = await ImageLoader.shared.image(for: url) {
                guard !Task.isCancelled else { return }
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
            if !preferKeepExisting {
                image = nil
                loadedURL = nil
            }
            return
        }
        if loadedURL == newURL, image != nil { return }
        if let cached = ImageLoader.shared.previewImage(for: newURL) {
            image = cached
            if ImageLoader.shared.cachedImage(for: newURL) != nil {
                loadedURL = newURL
            }
            return
        }
        if !preferKeepExisting {
            image = nil
            loadedURL = nil
        }
    }
}
