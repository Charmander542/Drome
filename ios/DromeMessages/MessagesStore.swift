import Foundation
import Security

struct AccountSnapshot: Codable {
    var id: UUID
    var serverURL: URL
    var username: String
    var allowSelfSigned: Bool
    var wishlistURL: URL?
}

struct ShareTrack: Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var coverArt: String?

    init(id: String, title: String, artist: String, album: String, coverArt: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.coverArt = coverArt
    }

    init?(subsonic: [String: Any]) {
        guard let id = subsonic["id"] as? String else { return nil }
        self.id = id
        self.title = (subsonic["title"] as? String) ?? "Track"
        self.artist = (subsonic["artist"] as? String) ?? ""
        self.album = (subsonic["album"] as? String) ?? ""
        self.coverArt = subsonic["coverArt"] as? String
    }

    static func from(url: URL?) -> ShareTrack? {
        guard let url else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        var id = val("song")
        if id.isEmpty, url.scheme == "drome", url.host == "track" {
            id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !id.isEmpty else { return nil }
        func decode(_ raw: String) -> String {
            raw.removingPercentEncoding ?? raw
        }
        return ShareTrack(
            id: decode(id),
            title: decode(val("title")),
            artist: decode(val("artist")),
            album: decode(val("album")),
            coverArt: val("cover").isEmpty ? nil : decode(val("cover")))
    }
}

enum MessagesStore {
    static let appGroup = "group.drome.app"
    static let accessGroup = "LURJ69YS93.group.drome.app"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func loadAccount() -> (AccountSnapshot, String)? {
        guard let data = defaults?.data(forKey: "drome.accounts"),
              let accounts = try? JSONDecoder().decode([AccountSnapshot].self, from: data),
              !accounts.isEmpty
        else { return nil }
        let active: AccountSnapshot
        if let raw = defaults?.string(forKey: "drome.activeAccount"),
           let id = UUID(uuidString: raw),
           let match = accounts.first(where: { $0.id == id }) {
            active = match
        } else {
            active = accounts[0]
        }
        guard let password = keychainPassword(for: active.id) else { return nil }
        return (active, password)
    }

    static func recents() -> [ShareTrack] {
        guard let data = defaults?.data(forKey: "drome.messages.recents"),
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [] }
        return rows.map {
            ShareTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, coverArt: $0.coverArt)
        }
    }

    static func setPendingOpen(_ track: ShareTrack) {
        guard !track.id.isEmpty else { return }
        let row = Row(id: track.id, title: track.title, artist: track.artist, album: track.album, coverArt: track.coverArt)
        guard let data = try? JSONEncoder().encode(row) else { return }
        defaults?.set(data, forKey: "drome.pendingOpenTrack")
        defaults?.synchronize()
    }

    static func save(_ track: ShareTrack) {
        guard !track.id.isEmpty else { return }
        var all = payloads()
        all[track.id] = Row(
            id: track.id, title: track.title, artist: track.artist,
            album: track.album, coverArt: track.coverArt)
        if let data = try? JSONEncoder().encode(all) {
            defaults?.set(data, forKey: "drome.messages.payloads")
        }
    }

    static func cachedTrack(id: String) -> ShareTrack? {
        guard let row = payloads()[id] else { return nil }
        return ShareTrack(id: row.id, title: row.title, artist: row.artist, album: row.album, coverArt: row.coverArt)
    }

    private static func payloads() -> [String: Row] {
        guard let data = defaults?.data(forKey: "drome.messages.payloads"),
              let rows = try? JSONDecoder().decode([String: Row].self, from: data)
        else { return [:] }
        return rows
    }

    static func serverHost() -> String? {
        loadAccount()?.0.serverURL.host
    }

    static func client() -> MessagesSubsonic? {
        guard let (account, password) = loadAccount() else { return nil }
        return MessagesSubsonic(account: account, password: password)
    }

    private static func keychainPassword(for accountID: UUID) -> String? {
        let key = "drome.password.\(accountID.uuidString)"
        if let value = keychainGet(key, accessGroup: accessGroup) { return value }
        return keychainGet(key, accessGroup: nil)
    }

    private static func keychainGet(_ account: String, accessGroup: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.drome.app",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct Row: Codable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var coverArt: String?
    }
}
