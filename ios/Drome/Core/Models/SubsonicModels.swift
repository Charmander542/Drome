import Foundation

// MARK: - Envelope

/// Every Subsonic response is wrapped in `{"subsonic-response": {...}}` with a
/// status field. The envelope validates the status and then lets the payload
/// type decode its own fields from the same nested object.
struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let payload: Payload

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ string: String) { self.stringValue = string }
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        let responseKey = AnyKey("subsonic-response")
        let response = try root.nestedContainer(keyedBy: AnyKey.self, forKey: responseKey)
        let status = try response.decode(String.self, forKey: AnyKey("status"))
        if status != "ok" {
            let apiError = try? response.decode(SubsonicAPIError.self, forKey: AnyKey("error"))
            throw SubsonicError.api(code: apiError?.code ?? -1,
                                    message: apiError?.message ?? "Unknown server error")
        }
        payload = try Payload(from: try root.superDecoder(forKey: responseKey))
    }
}

struct SubsonicAPIError: Decodable {
    let code: Int
    let message: String?
}

struct EmptyPayload: Decodable {}

// MARK: - Songs

struct Song: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var album: String?
    var albumId: String?
    var artist: String?
    var artistId: String?
    /// OpenSubsonic multi-artist credits when the server provides them.
    var artists: [ArtistRef]?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var size: Int64?
    var suffix: String?
    var duration: Int?
    var bitRate: Int?
    /// OpenSubsonic / Navidrome: Hz (e.g. 44100, 96000).
    var samplingRate: Int?
    /// OpenSubsonic / Navidrome: bits per sample (e.g. 16, 24).
    var bitDepth: Int?
    var contentType: String?
    var path: String?
    var playCount: Int?
    var userRating: Int?
    /// Present (usually an ISO date) when the current user has starred the track.
    var starred: String?
    var created: String?

    var durationText: String {
        Formatters.duration(seconds: duration ?? 0)
    }

    var displayArtist: String {
        ArtistCredits.display(for: self)
    }
}

struct ArtistRef: Codable, Hashable, Identifiable {
    /// Server artist id when present.
    var artistId: String?
    var name: String

    var id: String { artistId ?? name }

    enum CodingKeys: String, CodingKey {
        case artistId = "id"
        case name
    }
}

struct SongList: Decodable {
    var song: [Song]?
    var songs: [Song] { song ?? [] }
}

// MARK: - Albums

struct Album: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var playCount: Int?
    var created: String?
    var year: Int?
    var genre: String?
    var userRating: Int?
}

struct AlbumWithSongs: Decodable {
    let id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var userRating: Int?
    var song: [Song]?

    var songs: [Song] { song ?? [] }

    var asAlbum: Album {
        Album(id: id, name: name, artist: artist, artistId: artistId, coverArt: coverArt,
              songCount: songCount, duration: duration, playCount: nil, created: nil,
              year: year, genre: genre, userRating: userRating)
    }
}

enum AlbumListType: String {
    case newest, recent, frequent, random, starred
    case alphabeticalByName, alphabeticalByArtist
    case byGenre, byYear, highest
}

// MARK: - Artists

struct Artist: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var albumCount: Int?
    var coverArt: String?
    var artistImageUrl: String?
}

struct ArtistIndex: Decodable, Identifiable {
    var id: String { name }
    let name: String
    var artist: [Artist]?
    var artists: [Artist] { artist ?? [] }
}

struct ArtistWithAlbums: Decodable {
    let id: String
    var name: String
    var coverArt: String?
    var artistImageUrl: String?
    var albumCount: Int?
    var album: [Album]?
    var albums: [Album] { album ?? [] }
}

// MARK: - Genres

struct Genre: Decodable, Identifiable, Hashable {
    var id: String { value }
    let value: String
    var songCount: Int?
    var albumCount: Int?
}

// MARK: - Playlists

struct Playlist: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var comment: String?
    var owner: String?
    var isPublic: Bool?
    var songCount: Int?
    var duration: Int?
    var created: String?
    var changed: String?
    var coverArt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, created, changed, coverArt
        case isPublic = "public"
    }

    init(id: String, name: String, comment: String? = nil, owner: String? = nil,
         isPublic: Bool? = nil, songCount: Int? = nil, duration: Int? = nil,
         created: String? = nil, changed: String? = nil, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.isPublic = isPublic
        self.songCount = songCount
        self.duration = duration
        self.created = created
        self.changed = changed
        self.coverArt = coverArt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic)
        songCount = SubsonicJSON.int(c, .songCount)
        duration = SubsonicJSON.int(c, .duration)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        changed = try c.decodeIfPresent(String.self, forKey: .changed)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(isPublic, forKey: .isPublic)
        try c.encodeIfPresent(songCount, forKey: .songCount)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(changed, forKey: .changed)
        try c.encodeIfPresent(coverArt, forKey: .coverArt)
    }

    /// `12 songs`, `1 song`, or `Playlist` when the server omitted a count.
    var songCountLabel: String {
        Self.songCountLabel(songCount)
    }

    static func songCountLabel(_ count: Int?) -> String {
        guard let count else { return "Playlist" }
        return count == 1 ? "1 song" : "\(count) songs"
    }
}

struct PlaylistWithSongs: Decodable {
    let id: String
    var name: String
    var comment: String?
    var owner: String?
    var isPublic: Bool?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var entry: [Song]?

    var songs: [Song] { entry ?? [] }

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, coverArt, entry
        case isPublic = "public"
    }

    var asPlaylist: Playlist {
        Playlist(id: id, name: name, comment: comment, owner: owner, isPublic: isPublic,
                 songCount: songCount ?? songs.count, duration: duration, created: nil, changed: nil, coverArt: coverArt)
    }

    init(id: String, name: String, comment: String? = nil, owner: String? = nil,
         isPublic: Bool? = nil, songCount: Int? = nil, duration: Int? = nil,
         coverArt: String? = nil, entry: [Song]? = nil) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.isPublic = isPublic
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.entry = entry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic)
        songCount = SubsonicJSON.int(c, .songCount)
        duration = SubsonicJSON.int(c, .duration)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        entry = try c.decodeIfPresent([Song].self, forKey: .entry)
    }
}

// MARK: - Search

struct SearchResult3: Decodable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?

    var artists: [Artist] { artist ?? [] }
    var albums: [Album] { album ?? [] }
    var songs: [Song] { song ?? [] }
}

// MARK: - Lyrics (OpenSubsonic)

struct StructuredLyrics: Decodable {
    var lang: String?
    var synced: Bool?
    var offset: Int?
    var displayArtist: String?
    var displayTitle: String?
    var line: [StructuredLyricsLine]?
}

struct StructuredLyricsLine: Decodable {
    var start: Int?
    var value: String
}

// MARK: - Payloads

struct PingPayload: Decodable {}
struct ScanStatus: Decodable {
    var scanning: Bool?
    var count: Int?
    var folderCount: Int?
    var lastScan: String?
}
struct ScanStatusPayload: Decodable {
    var scanStatus: ScanStatus
}
struct ArtistsPayload: Decodable {
    struct Indexes: Decodable { var index: [ArtistIndex]? }
    var artists: Indexes
}
struct ArtistPayload: Decodable { var artist: ArtistWithAlbums }
struct AlbumPayload: Decodable { var album: AlbumWithSongs }
struct AlbumList2Payload: Decodable {
    struct List: Decodable { var album: [Album]? }
    var albumList2: List
}
struct GenresPayload: Decodable {
    struct List: Decodable { var genre: [Genre]? }
    var genres: List
}
struct SongPayload: Decodable { var song: Song }
struct SongsByGenrePayload: Decodable { var songsByGenre: SongList }
struct RandomSongsPayload: Decodable { var randomSongs: SongList }
struct SimilarSongs2Payload: Decodable { var similarSongs2: SongList }
struct TopSongsPayload: Decodable { var topSongs: SongList }
struct Starred2Payload: Decodable {
    struct Starred2: Decodable {
        var artist: [Artist]?
        var album: [Album]?
        var song: [Song]?

        var artists: [Artist] { artist ?? [] }
        var albums: [Album] { album ?? [] }
        var songs: [Song] { song ?? [] }
    }
    var starred2: Starred2
}
struct Search3Payload: Decodable { var searchResult3: SearchResult3 }
struct PlaylistsPayload: Decodable {
    struct List: Decodable {
        var playlist: [Playlist]?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlist = (try? c.decode(SubsonicJSON.OneOrMany<Playlist>.self, forKey: .playlist))?.values
        }
        enum CodingKeys: String, CodingKey { case playlist }
    }
    var playlists: List
}
struct PlaylistPayload: Decodable { var playlist: PlaylistWithSongs }
struct LyricsBySongPayload: Decodable {
    struct List: Decodable { var structuredLyrics: [StructuredLyrics]? }
    var lyricsList: List
}
