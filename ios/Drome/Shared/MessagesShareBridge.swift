import Foundation

/// App Group payload so the iMessage extension can see the signed-in account
/// and recently played tracks. The share sheet still cannot insert a live
/// `MSMessage` — that only happens from Messages → Drome.
enum MessagesShareBridge {
    static let appGroup = "group.drome.app"
    static let accountsKey = "drome.accounts"
    static let activeKey = "drome.activeAccount"
    static let recentsKey = "drome.messages.recents"
    static let pendingOpenKey = "drome.pendingOpenTrack"
    static let maxRecents = 24

    struct RecentTrack: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var coverArt: String?
    }

    struct PendingOpen: Codable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var coverArt: String?
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func syncAccounts(_ accounts: [Account], activeID: UUID?) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(activeID?.uuidString, forKey: activeKey)
    }

    static func pushRecent(id: String, title: String, artist: String, album: String, coverArt: String?) {
        guard let defaults else { return }
        var list = recents()
        list.removeAll { $0.id == id }
        list.insert(
            RecentTrack(id: id, title: title, artist: artist, album: album, coverArt: coverArt),
            at: 0)
        if list.count > maxRecents {
            list = Array(list.prefix(maxRecents))
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: recentsKey)
        }
    }

    static func recents() -> [RecentTrack] {
        guard let data = defaults?.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([RecentTrack].self, from: data)
        else { return [] }
        return decoded
    }

    static func setPendingOpen(_ track: PendingOpen) {
        guard let defaults, let data = try? JSONEncoder().encode(track) else { return }
        defaults.set(data, forKey: pendingOpenKey)
    }

    static func consumePendingOpen() -> PendingOpen? {
        guard let defaults, let data = defaults.data(forKey: pendingOpenKey) else { return nil }
        defaults.removeObject(forKey: pendingOpenKey)
        return try? JSONDecoder().decode(PendingOpen.self, from: data)
    }

    static func peekPendingOpen() -> PendingOpen? {
        guard let data = defaults?.data(forKey: pendingOpenKey) else { return nil }
        return try? JSONDecoder().decode(PendingOpen.self, from: data)
    }
}
