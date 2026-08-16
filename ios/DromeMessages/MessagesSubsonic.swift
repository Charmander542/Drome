import Foundation
import CryptoKit

/// Minimal Subsonic client for the iMessage extension (search, cover, stream).
final class MessagesSubsonic {
    let account: AccountSnapshot
    private let password: String
    private let mediaSalt: String
    private let mediaToken: String
    let session: URLSession

    init?(account: AccountSnapshot, password: String) {
        self.account = account
        self.password = password
        let salt = Self.randomSalt()
        self.mediaSalt = salt
        self.mediaToken = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let delegate = account.allowSelfSigned
            ? MessagesTrustDelegate(trustedHost: account.serverURL.host)
            : nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func searchSongs(_ query: String) async -> [ShareTrack] {
        guard let url = endpoint("search3", extra: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: "24"),
        ], stable: false) else { return [] }
        guard let data = try? await session.data(from: url).0,
              let songs = parseSearchSongs(data)
        else { return [] }
        return songs
    }

    func coverJPEG(coverArt: String?, size: Int = 240) async -> Data? {
        guard let coverArt, !coverArt.isEmpty,
              let url = endpoint("getCoverArt", extra: [
                  URLQueryItem(name: "id", value: coverArt),
                  URLQueryItem(name: "size", value: String(size)),
              ], stable: true)
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return try? await session.data(for: request).0
    }

    func streamURL(songId: String) -> URL? {
        endpoint("stream", extra: [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "format", value: "mp3"),
            URLQueryItem(name: "maxBitRate", value: "192"),
        ], stable: true)
    }

    func createShareURL(track: ShareTrack, coverJPEG: Data?) async -> URL? {
        guard let base = account.wishlistURL else { return nil }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/share/track"
        components.queryItems = [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: mediaToken),
            URLQueryItem(name: "s", value: mediaSalt),
        ]
        guard let url = components.url else { return nil }
        struct Body: Encodable {
            var songId: String
            var title: String
            var artist: String
            var album: String
            var accent: String
            var coverJpegBase64: String?
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        request.httpBody = try? JSONEncoder().encode(Body(
            songId: track.id, title: track.title, artist: track.artist,
            album: track.album, accent: "#3D7EFF",
            coverJpegBase64: coverJPEG?.base64EncodedString()))
        guard let data = try? await session.data(for: request).0,
              let created = try? JSONDecoder().decode(ShareCreated.self, from: data),
              var out = URL(string: created.url)
        else { return nil }
        if var comps = URLComponents(url: out, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            if !items.contains(where: { $0.name == "song" }) {
                items.append(URLQueryItem(name: "song", value: track.id))
            }
            Self.mergePayload(&items, track: track, serverHost: account.serverURL.host ?? "")
            comps.queryItems = items
            out = comps.url ?? out
        }
        return out
    }

    /// iMessage strips custom schemes from `MSMessage.url`. Only http(s) survives.
    func messageURL(track: ShareTrack, shareURL: URL?) -> URL {
        let base = shareURL
            ?? account.wishlistURL.map { wishlist in
                var comps = URLComponents(url: wishlist, resolvingAgainstBaseURL: false)
                var path = comps?.path ?? ""
                if path.hasSuffix("/") { path.removeLast() }
                comps?.path = path + "/s/imessage"
                comps?.query = nil
                return comps?.url ?? wishlist
            }
            ?? account.serverURL
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        if comps.scheme != "http" && comps.scheme != "https" {
            comps.scheme = "https"
        }
        var items = comps.queryItems ?? []
        Self.mergePayload(&items, track: track, serverHost: account.serverURL.host ?? "")
        comps.queryItems = items
        return comps.url ?? base
    }

    static func mergePayload(_ items: inout [URLQueryItem], track: ShareTrack, serverHost: String) {
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            if !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        set("song", track.id)
        set("title", track.title)
        set("artist", track.artist)
        set("album", track.album)
        set("cover", track.coverArt ?? "")
        set("server", serverHost)
    }

    private func endpoint(_ name: String, extra: [URLQueryItem], stable: Bool) -> URL? {
        guard var components = URLComponents(url: account.serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/rest/" + name
        let salt = stable ? mediaSalt : Self.randomSalt()
        let token = stable ? mediaToken : Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        components.queryItems = [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Drome"),
            URLQueryItem(name: "f", value: "json"),
        ] + extra
        return components.url
    }

    private func parseSearchSongs(_ data: Data) -> [ShareTrack]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["subsonic-response"] as? [String: Any],
              response["status"] as? String == "ok",
              let result = response["searchResult3"] as? [String: Any]
        else { return nil }
        let raw = result["song"] as? [[String: Any]] ?? []
        return raw.compactMap { ShareTrack(subsonic: $0) }
    }

    func song(id: String) async -> ShareTrack? {
        guard let url = endpoint("getSong", extra: [URLQueryItem(name: "id", value: id)], stable: true) else {
            return nil
        }
        guard let data = try? await session.data(from: url).0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["subsonic-response"] as? [String: Any],
              response["status"] as? String == "ok",
              let song = response["song"] as? [String: Any]
        else { return nil }
        return ShareTrack(subsonic: song)
    }

    private static func randomSalt(length: Int = 16) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    private struct ShareCreated: Decodable { var url: String }
}

final class MessagesTrustDelegate: NSObject, URLSessionDelegate {
    private let trustedHost: String?
    init(trustedHost: String?) { self.trustedHost = trustedHost }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trustedHost,
              challenge.protectionSpace.host.caseInsensitiveCompare(trustedHost) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
