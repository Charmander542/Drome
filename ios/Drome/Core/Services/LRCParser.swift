import Foundation

/// Parses LRC and Enhanced LRC lyrics.
///
/// - Standard LRC: `[mm:ss.xx] line text`
/// - Enhanced LRC (word-timed): `[mm:ss.xx] <mm:ss.xx>word <mm:ss.xx>word`
///
/// When only line timestamps exist, word timings are synthesized
/// (character-weighted) so the karaoke UI can highlight the word being sung.
enum LRCParser {
    struct Word: Identifiable, Equatable, Hashable {
        let id: UUID
        var text: String
        var startMs: Int
        var endMs: Int?

        init(id: UUID = UUID(), text: String, startMs: Int, endMs: Int? = nil) {
            self.id = id
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    struct Line: Identifiable, Equatable {
        enum Side: Equatable {
            /// Main vocalist — left-aligned (Spotify duet style).
            case primary
            /// Featured / second singer — right-aligned.
            case secondary
            /// Chorus / both — centered.
            case group
        }

        let id: UUID
        var startMs: Int?
        var text: String
        var words: [Word]
        var side: Side
        var singerLabel: String?

        init(id: UUID = UUID(), startMs: Int?, text: String, words: [Word] = [],
             side: Side = .primary, singerLabel: String? = nil) {
            self.id = id
            self.startMs = startMs
            self.text = text
            self.words = words
            self.side = side
            self.singerLabel = singerLabel
        }

        static func == (lhs: Line, rhs: Line) -> Bool { lhs.id == rhs.id }
    }

    private static let bracketTime = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let angleTime = try! NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    static func isSynced(_ raw: String) -> Bool {
        bracketTime.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }

    static func parse(_ raw: String) -> [Line] {
        var timed: [Line] = []
        var untimed: [Line] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let full = NSRange(location: 0, length: nsLine.length)
            let bracketMatches = bracketTime.matches(in: rawLine, range: full)

            if bracketMatches.isEmpty {
                let text = rawLine.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("["), text.hasSuffix("]"), text.contains(":") { continue }
                if text.isEmpty { continue }
                untimed.append(Line(startMs: nil, text: text, words: tokenize(text).map {
                    Word(text: $0, startMs: 0)
                }))
                continue
            }

            guard let last = bracketMatches.last else { continue }
            let remainderStart = last.range.location + last.range.length
            let remainder = nsLine.substring(from: remainderStart)
            let (display, words) = parseEnhancedRemainder(remainder)

            for match in bracketMatches {
                let ms = milliseconds(in: rawLine, match: match)
                let lineWords: [Word]
                if remainder.contains("<"), !words.isEmpty {
                    lineWords = words
                } else {
                    lineWords = tokenize(display).map { Word(text: $0, startMs: ms) }
                }
                timed.append(Line(startMs: ms, text: display, words: lineWords))
            }
        }

        let lines = timed.isEmpty ? untimed : timed.sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        return assignSingerSides(hydrateWordTimings(lines))
    }

    /// Detect duet / multi-singer labels and map them to left / right / center.
    static func assignSingerSides(_ lines: [Line]) -> [Line] {
        guard !lines.isEmpty else { return lines }

        var speakerOrder: [String] = []
        var result = lines

        for i in result.indices {
            let (label, cleaned) = extractSpeaker(from: result[i].text)
            if let label {
                result[i].singerLabel = label
                if cleaned != result[i].text {
                    result[i].text = cleaned
                    // Rebuild words from cleaned text if they still mirrored the label.
                    let start = result[i].startMs ?? result[i].words.first?.startMs ?? 0
                    let end = result[i].words.last?.endMs ?? (start + 2000)
                    result[i].words = distributeWords(tokenize(cleaned), from: start, to: end)
                }
                let key = label.lowercased()
                if !speakerOrder.contains(key), !isGroupLabel(label) {
                    speakerOrder.append(key)
                }
            } else if looksLikeBackgroundVocal(result[i].text) {
                result[i].side = .secondary
            }
        }

        // Map first unique speaker → primary (left), second → secondary (right),
        // group labels → center. If no labels, leave everything primary (left).
        for i in result.indices {
            guard let label = result[i].singerLabel else { continue }
            if isGroupLabel(label) {
                result[i].side = .group
                continue
            }
            let key = label.lowercased()
            if let idx = speakerOrder.firstIndex(of: key) {
                result[i].side = idx == 0 ? .primary : .secondary
            }
        }

        // If we only found one labeled speaker but many unlabeled lines after
        // them, keep unlabeled as primary (main vocal).
        return result
    }

    private static func isGroupLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["both", "all", "chorus", "choir", "together", "everyone", "duo"]
            .contains(where: { l == $0 || l.contains($0) })
    }

    private static func looksLikeBackgroundVocal(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    /// Pulls `Adele:`, `M:`, `A -`, `Verse 1 - Artist:` style prefixes.
    private static func extractSpeaker(from text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // "Name: lyrics" or "Name：lyrics" (fullwidth colon)
        if let regex = try? NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9 .'\-]{0,24}?)\s*[:：]\s+(.+)$"#),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges >= 3 {
            let ns = trimmed as NSString
            let label = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let rest = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if isPlausibleSpeaker(label) {
                return (label, rest)
            }
        }
        // Short codes: "A:", "B:", "M:", "F:" with optional space
        if let regex = try? NSRegularExpression(pattern: #"^([A-Za-z])\s*[:：]\s*(.+)$"#),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges >= 3 {
            let ns = trimmed as NSString
            let label = ns.substring(with: match.range(at: 1))
            let rest = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return (label, rest)
        }
        return (nil, trimmed)
    }

    private static func isPlausibleSpeaker(_ label: String) -> Bool {
        let lower = label.lowercased()
        // Avoid treating timestamps or common lyric openers as speakers.
        if lower.count > 24 { return false }
        let banned = ["http", "https", "verse", "chorus", "bridge", "intro", "outro", "hook"]
        if banned.contains(lower) { return false }
        return true
    }

    static func hydrateWordTimings(_ lines: [Line]) -> [Line] {
        guard !lines.isEmpty else { return lines }
        var result = lines

        for i in result.indices {
            let lineStart = result[i].startMs ?? 0
            let lineEnd: Int = {
                if i + 1 < result.count, let next = result[i + 1].startMs {
                    return max(next, lineStart + 1)
                }
                let wordCount = max(result[i].words.count, 1)
                return lineStart + max(2500, wordCount * 350)
            }()

            if result[i].words.isEmpty {
                result[i].words = tokenize(result[i].text).map { Word(text: $0, startMs: lineStart) }
            }

            let uniqueStarts = Set(result[i].words.map(\.startMs))
            if uniqueStarts.count <= 1 {
                result[i].words = distributeWords(result[i].words.map(\.text), from: lineStart, to: lineEnd)
            } else {
                var words = result[i].words
                for w in words.indices {
                    let end = w + 1 < words.count ? words[w + 1].startMs : lineEnd
                    words[w].endMs = max(end, words[w].startMs + 80)
                }
                result[i].words = words
            }
        }
        return result
    }

    // MARK: - Internals

    private static func milliseconds(in string: String, match: NSTextCheckingResult) -> Int {
        func group(_ idx: Int) -> String {
            let range = match.range(at: idx)
            guard range.location != NSNotFound else { return "0" }
            return (string as NSString).substring(with: range)
        }
        let minutes = Int(group(1)) ?? 0
        let seconds = Int(group(2)) ?? 0
        let fraction = group(3).padding(toLength: 3, withPad: "0", startingAt: 0)
        return (minutes * 60 + seconds) * 1000 + (Int(fraction) ?? 0)
    }

    private static func parseEnhancedRemainder(_ remainder: String) -> (String, [Word]) {
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        let matches = angleTime.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return (trimmed, tokenize(trimmed).map { Word(text: $0, startMs: 0) })
        }

        var words: [Word] = []
        var displayParts: [String] = []
        for (idx, match) in matches.enumerated() {
            let start = milliseconds(in: trimmed, match: match)
            let textStart = match.range.location + match.range.length
            let textEnd = idx + 1 < matches.count ? matches[idx + 1].range.location : ns.length
            let wordText = ns.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                .trimmingCharacters(in: .whitespaces)
            guard !wordText.isEmpty else { continue }
            words.append(Word(text: wordText, startMs: start))
            displayParts.append(wordText)
        }
        return (displayParts.joined(separator: " "), words)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    private static func distributeWords(_ tokens: [String], from start: Int, to end: Int) -> [Word] {
        guard !tokens.isEmpty else { return [] }
        let duration = max(end - start, tokens.count * 120)
        let weights = tokens.map { max($0.count, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var cursor = start
        var result: [Word] = []
        for (idx, token) in tokens.enumerated() {
            let slice = idx == tokens.count - 1
                ? max(end - cursor, 80)
                : max(80, duration * weights[idx] / totalWeight)
            let wordEnd = min(end, cursor + slice)
            result.append(Word(text: token, startMs: cursor, endMs: wordEnd))
            cursor = wordEnd
        }
        if let last = result.indices.last {
            result[last].endMs = end
        }
        return result
    }

    static func plainText(from raw: String) -> String {
        parse(raw).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func serialize(lines: [(startMs: Int?, text: String)]) -> String {
        lines.map { line in
            if let ms = line.startMs {
                let m = ms / 60000
                let s = (ms % 60000) / 1000
                let hundredths = (ms % 1000) / 10
                return String(format: "[%02d:%02d.%02d]%@", m, s, hundredths, line.text)
            }
            return line.text
        }
        .joined(separator: "\n")
    }
}
