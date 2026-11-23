import Foundation

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
