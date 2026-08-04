import UIKit
import SwiftUI

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
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = UIImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
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
                image = cached
                loadedURL = url
            } else if loadedURL != url {
                image = nil
                loadedURL = nil
            }
        }
    }
}
