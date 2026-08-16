import Foundation

/// Platform-agnostic Drome Connect wire models (match `server/CONNECT.md`).
/// Keep JSON keys stable so web/desktop clients can share the same contract.

struct ConnectDevice: Codable, Identifiable, Hashable, Equatable {
    var id: String
    var owner: String?
    var name: String
    var platform: String
    var model: String?
    var isActive: Bool?
    var isPlaying: Bool?
    var songId: String?
    var songTitle: String?
    var songArtist: String?
    var elapsed: Double?
    var duration: Double?
    var lastSeenAt: Double?
    var capabilities: [String]?

    var systemImage: String {
        switch platform {
        case "tvos": return "appletv"
        case "web": return "safari"
        case "desktop": return "desktopcomputer"
        case "android": return "smartphone"
        default: return "iphone"
        }
    }
}

struct ConnectSession: Codable, Equatable {
    var owner: String?
    var activeDeviceId: String
    var isPlaying: Bool
    var updatedAt: Double
    var snapshot: PlaybackSessionSnapshot?
}

struct ConnectCommand: Codable, Identifiable, Equatable {
    var id: String
    var owner: String?
    var type: String
    var fromDeviceId: String
    var targetDeviceId: String
    var seekTo: Double?
    var createdAt: Double
}

enum ConnectCommandType {
    static let transfer = "transfer"
    static let takeControl = "takeControl"
    static let play = "play"
    static let pause = "pause"
    static let next = "next"
    static let previous = "previous"
    static let seek = "seek"
}

enum ConnectPlatform {
    #if os(tvOS)
    static let current = "tvos"
    #elseif os(iOS)
    static let current = "ios"
    #else
    static let current = "other"
    #endif
}
