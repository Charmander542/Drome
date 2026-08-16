import Foundation

enum SubsonicJSON {
    /// Subsonic servers sometimes emit numbers as strings (or a single object
    /// where the spec says an array).
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    struct OneOrMany<T: Decodable>: Decodable {
        var values: [T]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                values = []
            } else if let many = try? container.decode([T].self) {
                values = many
            } else if let one = try? container.decode(T.self) {
                values = [one]
            } else {
                values = []
            }
        }
    }
}
