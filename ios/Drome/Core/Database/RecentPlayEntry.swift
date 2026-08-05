import Foundation

/// A single card in the Home “Recently played” rail.
///
/// Context-aware: vibe mixes, playlists, albums, and similar sources collapse
/// to one card. Individual songs only appear from search / direct song plays.
enum RecentPlayEntry: Identifiable, Equatable {
    case song(Song)
    case album(id: String, name: String, coverSong: Song)
    case playlist(id: String, name: String, coverSong: Song)
    /// Generated / algorithmic sources (vibes, rated folders, genres, etc.).
    case mix(key: String, name: String, coverSong: Song, subtitle: String)

    var id: String {
        switch self {
        case .song(let song): return "song:\(song.id)"
        case .album(let id, _, _): return "album:\(id)"
        case .playlist(let id, _, _): return "playlist:\(id)"
        case .mix(let key, _, _, _): return "mix:\(key)"
        }
    }
}
