import Foundation

struct DailyMix: Codable, Identifiable, Hashable {
    var id: String
    var index: Int
    var title: String
    var subtitle: String
    var colors: [String]
    var coverArtIds: [String]
    var songs: [Song]
}

struct DailyMixResponse: Codable {
    var date: String
    var mixes: [DailyMix]
}

struct VibeMix: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var songs: [Song]
}
