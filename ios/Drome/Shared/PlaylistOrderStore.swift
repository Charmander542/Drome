import Foundation

/// User-defined playlist order in the Library tab (per server).
enum PlaylistOrderStore {
    private static func key(serverKey: String) -> String {
        "drome.playlistOrder.\(serverKey)"
    }

    static func ordered(_ playlists: [Playlist], serverKey: String) -> [Playlist] {
        guard let saved = UserDefaults.standard.stringArray(forKey: key(serverKey: serverKey)),
              !saved.isEmpty else { return playlists }
        let byID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        var result: [Playlist] = []
        var seen = Set<String>()
        for id in saved where seen.insert(id).inserted {
            if let playlist = byID[id] { result.append(playlist) }
        }
        for playlist in playlists where !seen.contains(playlist.id) {
            result.append(playlist)
        }
        return result
    }

    static func save(_ playlistIDs: [String], serverKey: String) {
        UserDefaults.standard.set(playlistIDs, forKey: key(serverKey: serverKey))
    }
}
