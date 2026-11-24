import Foundation

/// Playlist cover policy.
///
/// Prefer Navidrome’s `getCoverArt` for the playlist itself — that serves both
/// custom uploads and the server mosaic. Local collage ids are only a fallback
/// when the playlist has no cover id yet (rare).
enum PlaylistCoverStore {
    private static func customKey(userKey: String) -> String {
        "drome.playlistCustomCover.\(userKey)"
    }

    private static func collageKey(userKey: String, playlistID: String) -> String {
        "drome.playlistCollage.\(userKey).\(playlistID)"
    }

    /// Cover art id for `getCoverArt` — always resolvable from a playlist id.
    static func serverCoverID(coverArt: String?, playlistID: String) -> String {
        let trimmed = coverArt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? playlistID : trimmed
    }

    static func hasCustom(_ playlistID: String, userKey: String) -> Bool {
        customIDs(userKey: userKey).contains(playlistID)
    }

    static func markCustom(_ playlistID: String, userKey: String) {
        var ids = customIDs(userKey: userKey)
        ids.insert(playlistID)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: customKey(userKey: userKey))
    }

    static func clearCustom(_ playlistID: String, userKey: String) {
        var ids = customIDs(userKey: userKey)
        ids.remove(playlistID)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: customKey(userKey: userKey))
    }

    /// First unique album/cover ids in playlist track order — same every time.
    static func coverIDs(from songs: [Song], limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for song in songs {
            let id = song.coverArt ?? song.albumId
            guard let id, !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= limit { break }
        }
        return out
    }

    static func rememberedCoverIDs(playlistID: String, userKey: String) -> [String] {
        UserDefaults.standard.stringArray(
            forKey: collageKey(userKey: userKey, playlistID: playlistID)) ?? []
    }

    /// Persist collage ids as a soft fallback for list rows.
    static func rememberCoverIDs(_ coverIDs: [String], playlistID: String, userKey: String) {
        guard !coverIDs.isEmpty else { return }
        UserDefaults.standard.set(
            coverIDs, forKey: collageKey(userKey: userKey, playlistID: playlistID))
    }

    private static func customIDs(userKey: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: customKey(userKey: userKey)) ?? [])
    }
}

/// Back-compat alias used by earlier call sites.
typealias PlaylistCustomCoverStore = PlaylistCoverStore

/// Per-user playlist order + hidden set in the Library tab.
///
/// Hidden is local to this account — it never deletes a Navidrome playlist, so
/// shared / public lists stay intact for everyone else on the server.
enum PlaylistOrderStore {
    private static func orderKey(userKey: String) -> String {
        "drome.playlistOrder.\(userKey)"
    }

    private static func legacyOrderKey(serverKey: String) -> String {
        "drome.playlistOrder.\(serverKey)"
    }

    private static func hiddenKey(userKey: String) -> String {
        "drome.playlistHidden.\(userKey)"
    }

    // MARK: - Order

    static func ordered(_ playlists: [Playlist], userKey: String, serverKey: String) -> [Playlist] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey(userKey: userKey))
            ?? UserDefaults.standard.stringArray(forKey: legacyOrderKey(serverKey: serverKey))
        guard let saved, !saved.isEmpty else { return playlists }
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

    static func save(_ playlistIDs: [String], userKey: String) {
        UserDefaults.standard.set(playlistIDs, forKey: orderKey(userKey: userKey))
    }

    // MARK: - Hidden

    static func hiddenIDs(userKey: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey(userKey: userKey)) ?? [])
    }

    static func isHidden(_ playlistID: String, userKey: String) -> Bool {
        hiddenIDs(userKey: userKey).contains(playlistID)
    }

    static func hide(_ playlistID: String, userKey: String) {
        var ids = hiddenIDs(userKey: userKey)
        guard ids.insert(playlistID).inserted else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: hiddenKey(userKey: userKey))
    }

    static func unhide(_ playlistID: String, userKey: String) {
        var ids = hiddenIDs(userKey: userKey)
        guard ids.remove(playlistID) != nil else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: hiddenKey(userKey: userKey))
    }

    // MARK: - Bulk Out of Rotation (playlist-level)

    /// Playlists the user has run “Mark All Out of Rotation” on. A song that
    /// lives in several playlists is only added to the OOR system playlist once
    /// every non-hidden playlist it belongs to is in this set.
    private static func bulkOORIDsKey(userKey: String) -> String {
        "drome.playlistBulkOOR.\(userKey)"
    }

    static func bulkOORMarkedIDs(userKey: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: bulkOORIDsKey(userKey: userKey)) ?? [])
    }

    static func markBulkOOR(_ playlistID: String, userKey: String) {
        var ids = bulkOORMarkedIDs(userKey: userKey)
        guard ids.insert(playlistID).inserted else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: bulkOORIDsKey(userKey: userKey))
    }

    static func clearBulkOOR(_ playlistID: String, userKey: String) {
        var ids = bulkOORMarkedIDs(userKey: userKey)
        guard ids.remove(playlistID) != nil else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: bulkOORIDsKey(userKey: userKey))
    }

    /// Visible playlists in the user's preferred order.
    static func visibleOrdered(
        _ playlists: [Playlist],
        userKey: String,
        serverKey: String
    ) -> [Playlist] {
        let hidden = hiddenIDs(userKey: userKey)
        let visible = playlists.filter { !hidden.contains($0.id) }
        return ordered(visible, userKey: userKey, serverKey: serverKey)
    }

    /// True when removing this playlist from *your* library must not hit the
    /// server — public lists and lists owned by someone else stay for the house.
    static func shouldHideInsteadOfDelete(_ playlist: Playlist, username: String) -> Bool {
        if playlist.isPublic == true { return true }
        guard let owner = playlist.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
              !owner.isEmpty else { return false }
        return owner.caseInsensitiveCompare(username) != .orderedSame
    }
}
