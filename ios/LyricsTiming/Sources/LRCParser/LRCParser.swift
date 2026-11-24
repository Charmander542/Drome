import Foundation

/// Parses LRC and Enhanced LRC lyrics.
///
/// - Standard LRC: `[mm:ss.xx] line text`
/// - Enhanced LRC (word-timed): `[mm:ss.xx] <mm:ss.xx>word <mm:ss.xx>word`
/// - Global offset tag: `[offset:±NNNN]` (milliseconds applied to every stamp)
///
/// When only line timestamps exist, word timings are synthesized from the
/// song’s own median pace (Aura `LyricWordTiming`, GPL-3.0 — see NOTICE):
/// spread across the *sung* portion of the line, not the full gap to the next
/// stamp (instrumental breaks used to make karaoke crawl).
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

    /// Result of parsing, including any `[offset:]` tag from the file.
    struct ParseResult {
        var lines: [Line]
        /// Milliseconds from `[offset:±NNNN]` (already applied to `lines` when
        /// `applyEmbeddedOffset` was true).
        var embeddedOffsetMs: Int
    }

    private static let bracketTime = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let angleTime = try! NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#,
        options: .caseInsensitive)

    static func isSynced(_ raw: String) -> Bool {
        bracketTime.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }

    static func parse(_ raw: String, applyEmbeddedOffset: Bool = true) -> [Line] {
        parseDetailed(raw, applyEmbeddedOffset: applyEmbeddedOffset).lines
    }

    static func parseDetailed(_ raw: String, applyEmbeddedOffset: Bool = true) -> ParseResult {
        var timed: [Line] = []
        var untimed: [Line] = []
        var embeddedOffsetMs = 0

        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmedMeta = rawLine.trimmingCharacters(in: .whitespaces)
            if let offset = parseOffsetTag(trimmedMeta) {
                embeddedOffsetMs = offset
                continue
            }

            let nsLine = rawLine as NSString
            let full = NSRange(location: 0, length: nsLine.length)
            let bracketMatches = bracketTime.matches(in: rawLine, range: full)

            if bracketMatches.isEmpty {
                let text = trimmedMeta
                // Skip other metadata tags: [ti:], [ar:], [al:], [length:], …
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

        var lines = timed.isEmpty ? untimed : timed.sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        lines = assignSingerSides(hydrateWordTimings(lines))
        if applyEmbeddedOffset, embeddedOffsetMs != 0 {
            lines = shift(lines, byMs: embeddedOffsetMs)
        }
        return ParseResult(lines: lines, embeddedOffsetMs: embeddedOffsetMs)
    }

    /// Shift every line / word timestamp by `deltaMs` (may be negative).
    static func shift(_ lines: [Line], byMs deltaMs: Int) -> [Line] {
        guard deltaMs != 0 else { return lines }
        return lines.map { line in
            var copy = line
            if let start = copy.startMs {
                copy.startMs = max(0, start + deltaMs)
            }
            copy.words = copy.words.map { word in
                var w = word
                w.startMs = max(0, word.startMs + deltaMs)
                if let end = word.endMs {
                    w.endMs = max(w.startMs + 40, end + deltaMs)
                }
                return w
            }
            return copy
        }
    }

    /// Linearly scale timestamps so lyrics timed for `fromDurationMs` land on a
    /// song of `toDurationMs`.
    ///
    /// Only tiny near-cuts (±2.5%). Larger stretches used to “sometimes” look
    /// fine at the start and drift seconds off by the chorus — better to leave
    /// a constant nudge the user can fix than progressive drift.
    static func scale(_ lines: [Line], fromDurationMs: Int, toDurationMs: Int) -> [Line] {
        guard fromDurationMs > 1_000, toDurationMs > 1_000 else { return lines }
        let ratio = Double(toDurationMs) / Double(fromDurationMs)
        if abs(ratio - 1) < 0.005 { return lines }
        if abs(ratio - 1) > 0.025 { return lines }

        func map(_ ms: Int) -> Int {
            max(0, Int((Double(ms) * ratio).rounded()))
        }

        return lines.map { line in
            var copy = line
            if let start = copy.startMs {
                copy.startMs = map(start)
            }
            copy.words = copy.words.map { word in
                var w = word
                w.startMs = map(word.startMs)
                if let end = word.endMs {
                    w.endMs = max(w.startMs + 40, map(end))
                }
                return w
            }
            return copy
        }
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
        if lower.count > 24 { return false }
        let banned = ["http", "https", "verse", "chorus", "bridge", "intro", "outro", "hook"]
        if banned.contains(lower) { return false }
        return true
    }

    static func hydrateWordTimings(_ lines: [Line]) -> [Line] {
        guard !lines.isEmpty else { return lines }
        var result = lines
        let songPace = paceMsPerChar(of: result)

        for i in result.indices {
            let lineStart = result[i].startMs ?? 0
            let wordWindowEnd = lineEndMs(lines: result, index: i, paceMs: songPace) ?? (lineStart + 2_500)

            if result[i].words.isEmpty {
                result[i].words = tokenize(result[i].text).map { Word(text: $0, startMs: lineStart) }
            }

            // "… x4": phrase lights once per pass across the sung window.
            if let marked = repeated(result[i].text),
               let end = lineEndMs(lines: result, index: i, paceMs: songPace),
               end > lineStart {
                let passes = marked.passes
                let period = (end - lineStart) / passes
                let phraseEnd = lineStart + min(period, max(1_500, marked.phrase.count * songPace * 13 / 10))
                var words = distributeWords(tokenize(marked.phrase), from: lineStart, to: phraseEnd)
                if let last = words.indices.last {
                    // Keep a space so joins stay lossless if we ever re-serialize.
                    if !words[last].text.hasSuffix(" ") {
                        words[last].text += " "
                    }
                }
                words.append(Word(
                    text: marked.marker.trimmingCharacters(in: .whitespaces),
                    startMs: lineStart + period * (passes - 1),
                    endMs: end))
                result[i].words = words
                continue
            }

            let uniqueStarts = Set(result[i].words.map(\.startMs))
            if uniqueStarts.count <= 1 {
                result[i].words = distributeWords(
                    result[i].words.map(\.text), from: lineStart, to: wordWindowEnd)
            } else {
                // Server / Enhanced LRC measured words — keep starts, fill ends.
                var words = result[i].words
                for w in words.indices {
                    let end = w + 1 < words.count ? words[w + 1].startMs : wordWindowEnd
                    words[w].endMs = max(end, words[w].startMs + 80)
                }
                result[i].words = words
            }
        }
        return result
    }

    // MARK: - Song-relative sync (Aura LyricWordTiming)

    /// Fallback when there aren’t enough timed lines to learn a pace (ms / character).
    static let defaultPaceMsPerChar = 90

    /// Median gap÷length over long enough lines — slow for ballads, quick for rap.
    /// Breaks are outliers; the median shrugs them off.
    static func paceMsPerChar(of lines: [Line]) -> Int {
        var samples: [Int] = []
        for index in lines.indices {
            guard let start = lines[index].startMs,
                  lines[index].text.count >= 8,
                  repeated(lines[index].text) == nil,
                  let next = nextStartMs(after: index, in: lines),
                  next > start
            else { continue }
            samples.append((next - start) / lines[index].text.count)
        }
        guard !samples.isEmpty else { return defaultPaceMsPerChar }
        samples.sort()
        return min(max(samples[samples.count / 2], 40), 300)
    }

    /// When the line at `index` stops being sung (word karaoke window end).
    ///
    /// Aura `LyricWordTiming.lineEnd`: paced sung length with slack, capped by
    /// the next stamp. Ordinary gaps (≈ song pace) run all the way to the next
    /// line so words land with the vocal; only a real instrumental ends early.
    static func lineEndMs(lines: [Line], index: Int, paceMs: Int? = nil) -> Int? {
        guard lines.indices.contains(index), let start = lines[index].startMs else { return nil }
        let pace = paceMs ?? paceMsPerChar(of: lines)

        if repeated(lines[index].text) != nil,
           let next = nextStartMs(after: index, in: lines), next > start {
            return next
        }

        // 30% slack (Aura used 20%) — slight underestimates used to finish the
        // last words early while the vocal was still on the line.
        let sung = start + max(1_500, sungLength(lines[index].text) * pace * 13 / 10)
        if let next = nextStartMs(after: index, in: lines), next > start {
            return min(next, sung)
        }
        return sung
    }

    /// When the active line has been fully sung.
    ///
    /// Prefer the last word’s `endMs` (filled by hydrate). Never treat
    /// pace-synthesized unique starts as Enhanced LRC — that used
    /// `last.startMs + 600` and made every line “finish” seconds early.
    static func lineFinishMs(lines: [Line], index: Int) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        if let end = lines[index].words.last?.endMs {
            return end
        }
        return lineEndMs(lines: lines, index: index)
    }

    /// Line that should be highlighted at `elapsedMs`: the last stamp that has
    /// started. Never advances before the next line’s `startMs` — early jumps
    /// during instrumentals made karaoke feel “not even close.”
    static func activeLineIndex(lines: [Line], atMs elapsedMs: Int) -> Int {
        var last = 0
        for (i, line) in lines.enumerated() {
            guard let start = line.startMs else { continue }
            if start <= elapsedMs { last = i } else { break }
        }
        return last
    }

    /// Scroll anticipation during a long instrumental (>2s after the sung
    /// window). Must not drive karaoke highlight — use `activeLineIndex` for that.
    static func focusIndex(lines: [Line], after last: Int?, atMs elapsedMs: Int) -> Int? {
        guard let index = last, index + 1 < lines.count,
              let nextStart = lines[index + 1].startMs,
              let finished = lineFinishMs(lines: lines, index: index)
        else { return last }
        let breakLength = nextStart - finished
        guard breakLength > 2_000, elapsedMs >= finished + breakLength / 2 else { return index }
        // Cap at the next stamp — never claim the next line is “active” early.
        return elapsedMs >= nextStart ? index + 1 : index
    }

    /// Line ending in a repeat marker — "x4", "(x4)", "[4x]", "×4".
    static func repeated(_ line: String) -> (phrase: String, marker: String, passes: Int)? {
        let pattern = #"\s+([(\[]?\s*(?:[x×]\s?([2-9])|([2-9])\s?[x×])\s*[)\]]?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whole = Range(match.range, in: line),
              let marker = Range(match.range(at: 1), in: line)
        else { return nil }
        let digit = [2, 3].compactMap { Range(match.range(at: $0), in: line) }.first.flatMap { Int(line[$0]) }
        let phrase = String(line[..<whole.lowerBound])
        guard let passes = digit, !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (phrase, String(line[marker]), passes)
    }

    private static func sungLength(_ line: String) -> Int {
        guard let marked = repeated(line) else { return line.count }
        return marked.phrase.count * marked.passes
    }

    private static func nextStartMs(after index: Int, in lines: [Line]) -> Int? {
        lines[(index + 1)...].first(where: { $0.startMs != nil })?.startMs
    }

    // MARK: - Internals

    private static func parseOffsetTag(_ line: String) -> Int? {
        let ns = line as NSString
        guard let match = offsetTag.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private static func milliseconds(in string: String, match: NSTextCheckingResult) -> Int {
        func group(_ idx: Int) -> String {
            let range = match.range(at: idx)
            guard range.location != NSNotFound else { return "0" }
            return (string as NSString).substring(with: range)
        }
        let minutes = Int(group(1)) ?? 0
        let seconds = Int(group(2)) ?? 0
        let rawFraction = group(3)
        // LRC uses centiseconds (2 digits) or milliseconds (3). Pad carefully:
        // "5" → 500ms, "50" → 500ms, "500" → 500ms.
        let fractionMs: Int = {
            if rawFraction.isEmpty { return 0 }
            if rawFraction.count == 1 { return (Int(rawFraction) ?? 0) * 100 }
            if rawFraction.count == 2 { return (Int(rawFraction) ?? 0) * 10 }
            return Int(rawFraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        }()
        return (minutes * 60 + seconds) * 1000 + fractionMs
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

    /// Weight is `count + 1` per word (Aura): the +1 pays for the following space
    /// so a line of short words doesn’t race ahead of one with fewer, longer words.
    private static func distributeWords(_ tokens: [String], from start: Int, to end: Int) -> [Word] {
        guard !tokens.isEmpty else { return [] }
        guard end > start else {
            return [Word(text: tokens.joined(separator: " "), startMs: start, endMs: start + 80)]
        }
        let duration = Double(max(end - start, tokens.count * 120))
        let weights = tokens.map { Double(max($0.count, 0) + 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var elapsed = 0.0
        var result: [Word] = []
        result.reserveCapacity(tokens.count)
        for (idx, token) in tokens.enumerated() {
            let wordStart = start + Int(elapsed.rounded())
            elapsed += duration * (weights[idx] / totalWeight)
            let wordEnd = idx == tokens.count - 1
                ? end
                : min(end, start + Int(elapsed.rounded()))
            // Ensure strictly increasing starts so karaoke never stalls on a tie.
            let clampedStart = result.last.map { max(wordStart, $0.startMs + 40) } ?? wordStart
            result.append(Word(
                text: token,
                startMs: min(clampedStart, max(start, end - (tokens.count - idx) * 40)),
                endMs: max(wordEnd, clampedStart + 80)))
        }
        if let last = result.indices.last {
            result[last].endMs = end
        }
        return result
    }

    static func plainText(from raw: String) -> String {
        parse(raw).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func serialize(lines: [(startMs: Int?, text: String)], offsetMs: Int = 0) -> String {
        var out: [String] = []
        if offsetMs != 0 {
            out.append("[offset:\(offsetMs)]")
        }
        out += lines.map { line in
            if let ms = line.startMs {
                let m = ms / 60000
                let s = (ms % 60000) / 1000
                let hundredths = (ms % 1000) / 10
                return String(format: "[%02d:%02d.%02d]%@", m, s, hundredths, line.text)
            }
            return line.text
        }
        return out.joined(separator: "\n")
    }
}
