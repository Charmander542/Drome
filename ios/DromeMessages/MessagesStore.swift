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
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func val(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        let id = val("song")
        guard !id.isEmpty else { return nil }
        return ShareTrack(
            id: id,
            title: val("title").removingPercentEncoding ?? val("title"),
            artist: val("artist").removingPercentEncoding ?? val("artist"),
            album: val("album").removingPercentEncoding ?? val("album"),
            coverArt: val("cover").isEmpty ? nil : val("cover"))
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
