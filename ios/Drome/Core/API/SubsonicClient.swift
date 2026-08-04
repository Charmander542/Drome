import Foundation
import CryptoKit

/// Client for the Subsonic/OpenSubsonic REST API as implemented by Navidrome.
/// Uses token authentication: a fresh random salt per request and
/// `token = md5(password + salt)`, so the password itself is never sent.
final class SubsonicClient {
    static let apiVersion = "1.16.1"
    static let clientName = "Drome"

    let account: Account
    let session: URLSession
    private let password: String
    /// Stable salt/token for media URLs (cover art, stream, download) so SwiftUI
    /// image views and AVPlayer items keep a constant URL across redraws.
    private let mediaSalt: String
    private let mediaToken: String

    init(account: Account, password: String) {
        self.account = account
        self.password = password
        let salt = Self.randomSalt()
        self.mediaSalt = salt
        self.mediaToken = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
        let delegate = account.allowSelfSigned
            ? ServerTrustDelegate(trustedHost: account.serverURL.host)
            : nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Auth

    /// Fresh salt + md5 token per API call, per the Subsonic auth spec.
    func authQueryItems() -> [URLQueryItem] {
        authQueryItems(salt: Self.randomSalt())
    }

    /// Session-stable credentials for long-lived media URLs.
    private func mediaAuthQueryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: mediaToken),
            URLQueryItem(name: "s", value: mediaSalt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    private func authQueryItems(salt: String) -> [URLQueryItem] {
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    static func randomSalt(length: Int = 16) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    // MARK: - Request plumbing

    func endpointURL(_ endpoint: String, parameters: [URLQueryItem] = [],
                     stableMediaAuth: Bool = false) -> URL? {
        guard var components = URLComponents(url: account.serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/rest/" + endpoint
        let auth = stableMediaAuth ? mediaAuthQueryItems() : authQueryItems()
        components.queryItems = auth + parameters
        return components.url
    }

    @discardableResult
    func request<P: Decodable>(_ payload: P.Type, endpoint: String,
                               parameters: [URLQueryItem] = []) async throws -> P {
        guard let url = endpointURL(endpoint, parameters: parameters) else {
            throw SubsonicError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicError.http(status: http.statusCode)
        }
        return try JSONDecoder().decode(SubsonicEnvelope<P>.self, from: data).payload
    }

    // MARK: - System

    func ping() async throws {
        _ = try await request(PingPayload.self, endpoint: "ping.view")
    }

    // MARK: - Library browsing

    func artists() async throws -> [ArtistIndex] {
        try await request(ArtistsPayload.self, endpoint: "getArtists").artists.index ?? []
    }

    func artist(id: String) async throws -> ArtistWithAlbums {
        try await request(ArtistPayload.self, endpoint: "getArtist",
                          parameters: [URLQueryItem(name: "id", value: id)]).artist
    }

    func album(id: String) async throws -> AlbumWithSongs {
        try await request(AlbumPayload.self, endpoint: "getAlbum",
                          parameters: [URLQueryItem(name: "id", value: id)]).album
    }

    func song(id: String) async throws -> Song {
        try await request(SongPayload.self, endpoint: "getSong",
                          parameters: [URLQueryItem(name: "id", value: id)]).song
    }

    func albumList(type: AlbumListType, size: Int = 40, offset: Int = 0,
                   genre: String? = nil) async throws -> [Album] {
        var params = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let genre {
            params.append(URLQueryItem(name: "genre", value: genre))
        }
        return try await request(AlbumList2Payload.self, endpoint: "getAlbumList2",
                                 parameters: params).albumList2.album ?? []
    }

    func genres() async throws -> [Genre] {
        try await request(GenresPayload.self, endpoint: "getGenres").genres.genre ?? []
    }

    func songsByGenre(_ genre: String, count: Int = 100, offset: Int = 0) async throws -> [Song] {
        try await request(SongsByGenrePayload.self, endpoint: "getSongsByGenre", parameters: [
            URLQueryItem(name: "genre", value: genre),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]).songsByGenre.songs
    }

    func randomSongs(size: Int = 50, genre: String? = nil) async throws -> [Song] {
        var params = [URLQueryItem(name: "size", value: String(size))]
        if let genre {
            params.append(URLQueryItem(name: "genre", value: genre))
        }
        return try await request(RandomSongsPayload.self, endpoint: "getRandomSongs",
                                 parameters: params).randomSongs.songs
    }

    /// Songs similar to the given artist (id3), used for autoplay.
    func similarSongs(artistId: String, count: Int = 30) async throws -> [Song] {
        try await request(SimilarSongs2Payload.self, endpoint: "getSimilarSongs2", parameters: [
            URLQueryItem(name: "id", value: artistId),
            URLQueryItem(name: "count", value: String(count)),
        ]).similarSongs2.songs
    }

    func topSongs(artistName: String, count: Int = 20) async throws -> [Song] {
        try await request(TopSongsPayload.self, endpoint: "getTopSongs", parameters: [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: String(count)),
        ]).topSongs.songs
    }

    // MARK: - Search

    func search(_ query: String, artistCount: Int = 8, albumCount: Int = 12,
                songCount: Int = 30) async throws -> SearchResult3 {
        try await request(Search3Payload.self, endpoint: "search3", parameters: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(artistCount)),
            URLQueryItem(name: "albumCount", value: String(albumCount)),
            URLQueryItem(name: "songCount", value: String(songCount)),
        ]).searchResult3
    }

    // MARK: - Playlists

    func playlists() async throws -> [Playlist] {
        try await request(PlaylistsPayload.self, endpoint: "getPlaylists").playlists.playlist ?? []
    }

    func playlist(id: String) async throws -> PlaylistWithSongs {
        try await request(PlaylistPayload.self, endpoint: "getPlaylist",
                          parameters: [URLQueryItem(name: "id", value: id)]).playlist
    }

    @discardableResult
    func createPlaylist(name: String, songIds: [String] = []) async throws -> PlaylistWithSongs {
        var params = [URLQueryItem(name: "name", value: name)]
        params += songIds.map { URLQueryItem(name: "songId", value: $0) }
        return try await request(PlaylistPayload.self, endpoint: "createPlaylist",
                                 parameters: params).playlist
    }

    /// Incremental playlist edit. `removeIndices` are positions in the
    /// playlist's current song list (Subsonic removes by index, not id).
    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil,
                        isPublic: Bool? = nil, addSongIds: [String] = [],
                        removeIndices: [Int] = []) async throws {
        var params = [URLQueryItem(name: "playlistId", value: id)]
        if let name { params.append(URLQueryItem(name: "name", value: name)) }
        if let comment { params.append(URLQueryItem(name: "comment", value: comment)) }
        if let isPublic { params.append(URLQueryItem(name: "public", value: isPublic ? "true" : "false")) }
        params += addSongIds.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        params += removeIndices.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) }
        _ = try await request(EmptyPayload.self, endpoint: "updatePlaylist", parameters: params)
    }

    /// Replaces the full track list (used for reordering).
    func replacePlaylist(id: String, name: String, songIds: [String]) async throws {
        var params = [
            URLQueryItem(name: "playlistId", value: id),
            URLQueryItem(name: "name", value: name),
        ]
        params += songIds.map { URLQueryItem(name: "songId", value: $0) }
        _ = try await request(EmptyPayload.self, endpoint: "createPlaylist", parameters: params)
    }

    func deletePlaylist(id: String) async throws {
        _ = try await request(EmptyPayload.self, endpoint: "deletePlaylist",
                              parameters: [URLQueryItem(name: "id", value: id)])
    }

    // MARK: - Ratings, stars & scrobbling

    func starred() async throws -> Starred2Payload.Starred2 {
        try await request(Starred2Payload.self, endpoint: "getStarred2").starred2
    }

    /// rating: 1...5, or 0 to clear.
    func setRating(id: String, rating: Int) async throws {
        _ = try await request(EmptyPayload.self, endpoint: "setRating", parameters: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "rating", value: String(rating)),
        ])
    }

    func star(id: String) async throws {
        _ = try await request(EmptyPayload.self, endpoint: "star",
                              parameters: [URLQueryItem(name: "id", value: id)])
    }

    func unstar(id: String) async throws {
        _ = try await request(EmptyPayload.self, endpoint: "unstar",
                              parameters: [URLQueryItem(name: "id", value: id)])
    }

    func scrobble(id: String, submission: Bool) async throws {
        _ = try await request(EmptyPayload.self, endpoint: "scrobble", parameters: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        ])
    }

    // MARK: - Lyrics

    func lyrics(songId: String) async throws -> [StructuredLyrics] {
        try await request(LyricsBySongPayload.self, endpoint: "getLyricsBySongId",
                          parameters: [URLQueryItem(name: "id", value: songId)])
            .lyricsList.structuredLyrics ?? []
    }

    // MARK: - Media URLs

    /// Streaming URL. `format=raw` asks Navidrome for the original (lossless)
    /// bytes with no transcoding. Uses session-stable auth so AVPlayer isn't
    /// handed a new URL on every SwiftUI redraw.
    func streamURL(songId: String) -> URL? {
        endpointURL("stream", parameters: [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "format", value: "raw"),
        ], stableMediaAuth: true)
    }

    /// Original-file download URL (no transcoding ever happens on this one).
    func downloadURL(songId: String) -> URL? {
        endpointURL("download", parameters: [
            URLQueryItem(name: "id", value: songId),
        ], stableMediaAuth: true)
    }

    func coverArtURL(id: String?, size: Int = 600) -> URL? {
        guard let id else { return nil }
        return endpointURL("getCoverArt", parameters: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "size", value: String(size)),
        ], stableMediaAuth: true)
    }
}
