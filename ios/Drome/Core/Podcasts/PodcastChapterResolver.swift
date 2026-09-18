import Foundation

/// Resolves episode chapters from Podcasting 2.0 JSON, Podlove Simple Chapters,
/// or timestamped show notes (Spotify-style manual chapters).
enum PodcastChapterResolver {

    /// Prefer already-resolved chapters, else fetch `chaptersURL`, else parse description.
    static func resolve(for episode: PodcastEpisode) async -> [PodcastChapter] {
        let existing = episode.chapters.filter(\.toc).sorted { $0.startTime < $1.startTime }
        if existing.count >= 2 { return existing }

        if let url = episode.chaptersURL {
            if let remote = try? await fetchJSONChapters(from: url), remote.count >= 2 {
                return remote
            }
        }

        if let fromNotes = parseDescriptionTimestamps(episode.description), fromNotes.count >= 2 {
            return fromNotes
        }

        return existing
    }

    // MARK: - Podcasting 2.0 JSON

    static func fetchJSONChapters(from url: URL) async throws -> [PodcastChapter] {
        guard url.scheme == "http" || url.scheme == "https" else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Drome/1.0 (Podcast)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json+chapters, application/json, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
            return []
        }
        return parseJSONChapters(data: data)
    }

    static func parseJSONChapters(data: Data) -> [PodcastChapter] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["chapters"] as? [[String: Any]] else {
            return []
        }

        var chapters: [PodcastChapter] = []
        for item in array {
            let start: TimeInterval
            if let number = item["startTime"] as? Double {
                start = number
            } else if let number = item["startTime"] as? Int {
                start = TimeInterval(number)
            } else if let string = item["startTime"] as? String,
                      let parsed = parseClock(string) {
                start = parsed
            } else {
                continue
            }

            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { continue }

            let end: TimeInterval?
            if let number = item["endTime"] as? Double {
                end = number
            } else if let number = item["endTime"] as? Int {
                end = TimeInterval(number)
            } else {
                end = nil
            }

            let toc: Bool
            if let flag = item["toc"] as? Bool {
                toc = flag
            } else {
                toc = true
            }

            let imageURL = (item["img"] as? String).flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil }
            let linkURL = (item["url"] as? String).flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil }

            chapters.append(PodcastChapter(
                startTime: start,
                title: title,
                endTime: end,
                imageURL: imageURL,
                linkURL: linkURL,
                toc: toc
            ))
        }

        return normalize(chapters)
    }

    // MARK: - Description timestamps (Spotify manual format)

    /// Parses lines like `(00:00) Intro`, `00:00 Intro`, `1:02:03 Title`.
    static func parseDescriptionTimestamps(_ description: String?) -> [PodcastChapter]? {
        guard let description, !description.isEmpty else { return nil }

        let pattern = #"(?m)^\s*[\[\(\{]?(?:(?:(\d{1,2}):)?(\d{1,2}):(\d{2})|(\d{1,2}):(\d{2}))[\]\)\}]?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let ns = description as NSString
        let matches = regex.matches(in: description, range: NSRange(location: 0, length: ns.length))
        var chapters: [PodcastChapter] = []

        for match in matches {
            let start: TimeInterval
            if match.range(at: 1).location != NSNotFound {
                let h = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let m = Int(ns.substring(with: match.range(at: 2))) ?? 0
                let s = Int(ns.substring(with: match.range(at: 3))) ?? 0
                start = TimeInterval(h * 3600 + m * 60 + s)
            } else if match.range(at: 4).location != NSNotFound {
                let m = Int(ns.substring(with: match.range(at: 4))) ?? 0
                let s = Int(ns.substring(with: match.range(at: 5))) ?? 0
                start = TimeInterval(m * 60 + s)
            } else {
                continue
            }

            let title = ns.substring(with: match.range(at: 6))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            chapters.append(PodcastChapter(startTime: start, title: title))
        }

        let normalized = normalize(chapters)
        return normalized.count >= 2 ? normalized : nil
    }

    // MARK: - Helpers

    static func parseClock(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(cleaned) { return seconds }

        // Allow fractional seconds on the last component: 8:26.250
        let parts = cleaned.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part) else { return nil }
            values.append(value)
        }
        switch values.count {
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        case 2: return values[0] * 60 + values[1]
        case 1: return values[0]
        default: return nil
        }
    }

    static func normalize(_ chapters: [PodcastChapter]) -> [PodcastChapter] {
        let visible = chapters.filter(\.toc)
        let sorted = visible.sorted { $0.startTime < $1.startTime }
        var unique: [PodcastChapter] = []
        var seen = Set<TimeInterval>()
        for chapter in sorted {
            let key = (chapter.startTime * 10).rounded() / 10
            if seen.insert(key).inserted {
                unique.append(chapter)
            }
        }
        return unique
    }

    static func currentIndex(in chapters: [PodcastChapter], at elapsed: TimeInterval) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var current = 0
        for (idx, chapter) in chapters.enumerated() {
            if chapter.startTime <= elapsed {
                current = idx
            } else {
                break
            }
        }
        return current
    }
}
