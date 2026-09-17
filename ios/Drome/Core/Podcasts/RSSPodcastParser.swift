import Foundation

/// Parses RSS 2.0 podcast feeds with iTunes/Apple Podcast namespace extensions.
enum RSSPodcastParser {

    // MARK: - Parse Feed

    /// Parse an RSS feed XML string into a `PodcastShow` and its episodes.
    static func parseFeed(xml: String, feedURL: String) throws -> (show: PodcastShow, episodes: [PodcastEpisode]) {
        guard let data = xml.data(using: .utf8) else {
            throw PodcastError.invalidFeed
        }

        let parser = XMLParser(data: data)
        let delegate = FeedParserDelegate(feedURL: feedURL)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw PodcastError.invalidFeed
        }

        guard let show = delegate.show else {
            throw PodcastError.invalidFeed
        }

        return (show, delegate.episodes)
    }

    /// Fetch and parse a podcast feed from a URL.
    static func fetchFeed(url: URL) async throws -> (show: PodcastShow, episodes: [PodcastEpisode]) {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw PodcastError.invalidFeed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Drome/1.0 (Podcast)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...399).contains(httpResponse.statusCode) else {
            throw PodcastError.feedUnavailable
        }

        // Try common encodings — some feeds declare ISO-8859-1 / windows-1252.
        let xml: String
        if let utf8 = String(data: data, encoding: .utf8) {
            xml = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            xml = latin1
        } else {
            throw PodcastError.invalidFeed
        }

        let finalURL = httpResponse.url ?? url
        return try parseFeed(xml: xml, feedURL: finalURL.absoluteString)
    }

    /// True when a string looks like an http(s) URL we can fetch.
    static func isHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    /// Parses iTunes duration strings: seconds, `MM:SS`, or `HH:MM:SS`.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        PodcastEpisodeBuilder.parseDuration(raw)
    }
}

// MARK: - Feed Parser Delegate

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: String
    var show: PodcastShow?
    var episodes: [PodcastEpisode] = []

    private var currentElement = ""
    private var textBuffer = ""
    private var currentEpisode: PodcastEpisodeBuilder?
    private var inItem = false
    private var inChannel = false
    private var inRSSImage = false

    // Channel-level accumulators
    private var channelTitle = ""
    private var channelAuthor = ""
    private var channelDescription = ""
    private var channelImageURL: URL?
    private var channelLanguage: String?
    private var channelCategory: String?
    private var channelExplicit = false
    private var channelLink: URL?

    init(feedURL: String) {
        self.feedURL = feedURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        textBuffer = ""

        let local = Self.localName(elementName)

        if local == "channel" {
            inChannel = true
        } else if local == "item" {
            inItem = true
            currentEpisode = PodcastEpisodeBuilder()
        } else if inItem {
            if local == "enclosure" {
                if let url = attributeDict["url"], RSSPodcastParser.isHTTPURL(url) {
                    currentEpisode?.enclosureURL = url
                }
                if let length = attributeDict["length"], let size = Int64(length) {
                    currentEpisode?.enclosureLength = size
                }
                currentEpisode?.enclosureType = attributeDict["type"]
            } else if elementName == "itunes:image" || (local == "image" && elementName.contains("itunes")) {
                if let href = attributeDict["href"], RSSPodcastParser.isHTTPURL(href) {
                    currentEpisode?.imageURL = URL(string: href)
                }
            }
        } else if inChannel {
            if elementName == "itunes:image" || (local == "image" && elementName.contains("itunes")) {
                if let href = attributeDict["href"], RSSPodcastParser.isHTTPURL(href) {
                    channelImageURL = URL(string: href)
                }
            } else if local == "image" && !elementName.contains("itunes") {
                inRSSImage = true
            } else if elementName == "itunes:category" {
                if channelCategory == nil {
                    channelCategory = attributeDict["text"]
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            textBuffer += text
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = Self.localName(elementName)

        if local == "item", inItem, let builder = currentEpisode {
            if let episode = builder.build(feedURL: feedURL, showImageURL: channelImageURL) {
                episodes.append(episode)
            }
            currentEpisode = nil
            inItem = false
        } else if local == "channel" {
            inChannel = false
            show = PodcastShow(
                id: feedURL,
                title: channelTitle.isEmpty ? "Unknown Podcast" : channelTitle,
                author: channelAuthor.isEmpty ? nil : channelAuthor,
                description: channelDescription.isEmpty ? nil : channelDescription,
                imageURL: channelImageURL,
                language: channelLanguage,
                category: channelCategory,
                explicit: channelExplicit,
                link: channelLink,
                episodeCount: episodes.count,
                lastUpdated: Date(),
                feedURL: feedURL
            )
        } else if inItem, let builder = currentEpisode {
            applyItemText(elementName: elementName, local: local, text: trimmed, builder: builder)
        } else if inChannel {
            applyChannelText(elementName: elementName, local: local, text: trimmed)
        }

        if local == "image" { inRSSImage = false }
        currentElement = ""
        textBuffer = ""
    }

    private func applyItemText(elementName: String, local: String, text: String, builder: PodcastEpisodeBuilder) {
        guard !text.isEmpty else { return }
        switch elementName {
        case "title":
            builder.title += text
        case "description", "content:encoded", "itunes:summary", "itunes:subtitle":
            if builder.description.isEmpty || elementName == "description" {
                if builder.description.isEmpty { builder.description = text }
            }
        case "guid":
            builder.guid += text
        case "pubDate":
            builder.pubDate = text
        case "link":
            builder.link = text
        case "itunes:duration", "duration":
            builder.rawDuration = text
        case "itunes:episode":
            builder.episodeNumber = Int(text)
        case "itunes:season":
            builder.seasonNumber = Int(text)
        case "itunes:episodeType":
            builder.episodeType = text
        case "itunes:explicit":
            builder.explicit = Self.isExplicit(text)
        default:
            if local == "title" { builder.title += text }
            else if local == "description", builder.description.isEmpty { builder.description = text }
            else if local == "guid" { builder.guid += text }
            else if local == "pubDate" { builder.pubDate = text }
        }
    }

    private func applyChannelText(elementName: String, local: String, text: String) {
        guard !text.isEmpty else { return }
        switch elementName {
        case "title":
            if !inRSSImage { channelTitle += text }
        case "itunes:author", "managingEditor", "dc:creator", "author":
            if channelAuthor.isEmpty { channelAuthor = text }
        case "description", "itunes:summary", "itunes:subtitle":
            if channelDescription.isEmpty { channelDescription = text }
        case "language":
            channelLanguage = text
        case "link":
            if !inRSSImage, channelLink == nil {
                channelLink = URL(string: text)
            }
        case "url" where inRSSImage:
            if channelImageURL == nil, RSSPodcastParser.isHTTPURL(text) {
                channelImageURL = URL(string: text)
            }
        case "itunes:explicit":
            channelExplicit = Self.isExplicit(text)
        default:
            if local == "title", !inRSSImage { channelTitle += text }
            else if local == "description", channelDescription.isEmpty { channelDescription = text }
            else if local == "url", inRSSImage, channelImageURL == nil, RSSPodcastParser.isHTTPURL(text) {
                channelImageURL = URL(string: text)
            }
        }
    }

    private static func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...])
        }
        return elementName
    }

    private static func isExplicit(_ text: String) -> Bool {
        let value = text.lowercased()
        return value == "yes" || value == "true" || value == "explicit"
    }
}

// MARK: - Episode Builder

private final class PodcastEpisodeBuilder {
    var title = ""
    var description = ""
    var guid = ""
    var pubDate: String?
    var link: String?
    var enclosureURL: String?
    var enclosureLength: Int64?
    var enclosureType: String?
    var imageURL: URL?
    var rawDuration = ""
    var episodeNumber: Int?
    var seasonNumber: Int?
    var episodeType: String?
    var explicit = false

    func build(feedURL: String, showImageURL: URL?) -> PodcastEpisode? {
        guard let audioURLString = enclosureURL,
              RSSPodcastParser.isHTTPURL(audioURLString),
              let audioURL = URL(string: audioURLString) else {
            return nil
        }

        let pubDateParsed = Self.parsePubDate(pubDate)
        let duration = Self.parseDuration(rawDuration)
        let episodeID = guid.isEmpty ? audioURLString : guid

        return PodcastEpisode(
            id: episodeID,
            showID: feedURL,
            title: title.isEmpty ? "Untitled Episode" : title,
            description: description.isEmpty ? nil : Self.stripHTML(description),
            pubDate: pubDateParsed,
            duration: duration,
            audioURL: audioURL,
            imageURL: imageURL ?? showImageURL,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            episodeType: episodeType,
            explicit: explicit,
            fileSize: enclosureLength,
            mimeType: enclosureType
        )
    }

    private static func parsePubDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    static func parseDuration(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let seconds = TimeInterval(cleaned) {
            return seconds
        }

        let components = cleaned.split(separator: ":").compactMap { Int($0) }
        switch components.count {
        case 3:
            return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
        case 2:
            return TimeInterval(components[0] * 60 + components[1])
        default:
            return nil
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Podcast Error

enum PodcastError: LocalizedError, Equatable {
    case invalidFeed
    case feedUnavailable
    case networkError
    case notAPodcast
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidFeed: return "Invalid podcast feed"
        case .feedUnavailable: return "Podcast feed is unavailable"
        case .networkError: return "Network error"
        case .notAPodcast: return "This feed does not appear to be a podcast"
        case .unknown: return "An unknown error occurred"
        }
    }
}
