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
    /// A line sung `passes` times ("… x4") — Aura `LyricRepeat`.
    struct LyricRepeat: Equatable, Hashable {
        let lineStartMs: Int
        let periodMs: Int
        let passes: Int
        /// Uneven pass starts when measured by ear; otherwise even `periodMs` slices.
        var startsMs: [Int]? = nil
    }

    struct Word: Identifiable, Equatable, Hashable {
        let id: UUID
        var text: String
        var startMs: Int
        var endMs: Int?
        /// Present on "… x4" phrase words so highlight restarts each pass.
        var cycle: LyricRepeat? = nil
        /// The "x4" marker itself — not sung as a word.
        var marker: Bool = false
        /// True for Enhanced LRC / server word cues (not pace-interpolated).
        var measured: Bool = false

        init(
            id: UUID = UUID(),
            text: String,
            startMs: Int,
            endMs: Int? = nil,
            cycle: LyricRepeat? = nil,
            marker: Bool = false,
            measured: Bool = false
        ) {
            self.id = id
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
            self.cycle = cycle
            self.marker = marker
            self.measured = measured
        }

        /// Ms since this word was reached in the pass being sung at `time`
        /// (Aura `LyricWord.elapsed`). Negative ⇒ not yet lit this pass.
        func elapsed(atMs time: Int) -> Int {
            guard let cycle else { return time - startMs }
            if let heard = cycle.startsMs, let first = heard.first {
                let pass = heard.last(where: { $0 <= time }) ?? first
                return time - (pass - first) - startMs
            }
            let period = max(cycle.periodMs, 1)
            let pass = min(max((time - cycle.lineStartMs) / period, 0), cycle.passes - 1)
            return time - pass * period - startMs
        }

        func isLit(atMs time: Int) -> Bool { elapsed(atMs: time) >= 0 }
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
                if var cycle = w.cycle {
                    cycle = LyricRepeat(
                        lineStartMs: max(0, cycle.lineStartMs + deltaMs),
                        periodMs: cycle.periodMs,
                        passes: cycle.passes,
                        startsMs: cycle.startsMs?.map { max(0, $0 + deltaMs) })
                    w.cycle = cycle
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
                if let cycle = word.cycle {
                    let scaledPeriod = max(1, Int((Double(cycle.periodMs) * ratio).rounded()))
                    w.cycle = LyricRepeat(
                        lineStartMs: map(cycle.lineStartMs),
                        periodMs: scaledPeriod,
                        passes: cycle.passes,
                        startsMs: cycle.startsMs?.map(map))
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

            // Measured Enhanced LRC on a "… x4" line — wrap first-pass cues in a cycle
            // so later passes re-light (Aura `repeatedPasses`).
            if result[i].words.contains(where: \.measured),
               let cycled = repeatedPasses(of: result[i].words, lines: result, index: i, paceMs: songPace) {
                result[i].words = cycled
                continue
            }

            // Interpolated "… x4": phrase lights once per pass; marker on last pass.
            if let marked = repeated(result[i].text),
               !result[i].words.contains(where: \.measured),
               let end = lineEndMs(lines: result, index: i, paceMs: songPace),
               end > lineStart {
                let passes = marked.passes
                let period = max((end - lineStart) / passes, 1)
                let phraseLen = max(1_500, marked.phrase.count * songPace * 12 / 10)
                let phraseEnd = lineStart + min(period, phraseLen)
                let cycle = LyricRepeat(lineStartMs: lineStart, periodMs: period, passes: passes)
                var words = distributeWords(tokenize(marked.phrase), from: lineStart, to: phraseEnd)
                for w in words.indices {
                    words[w].cycle = cycle
                }
                if let last = words.indices.last, !words[last].text.hasSuffix(" ") {
                    words[last].text += " "
                }
                words.append(Word(
                    text: marked.marker.trimmingCharacters(in: .whitespaces),
                    startMs: lineStart + period * (passes - 1),
                    endMs: end,
                    marker: true))
                result[i].words = words
                continue
            }

            let uniqueStarts = Set(result[i].words.map(\.startMs))
            if uniqueStarts.count <= 1 {
                result[i].words = distributeWords(
                    result[i].words.map(\.text), from: lineStart, to: wordWindowEnd)
            } else {
                // Measured words — keep starts, fill ends through the sung window.
                var words = result[i].words
                for w in words.indices {
                    let end = w + 1 < words.count ? words[w + 1].startMs : wordWindowEnd
                    words[w].endMs = max(end, words[w].startMs + 80)
                    words[w].measured = true
                }
                result[i].words = words
            }
        }
        return result
    }

    /// Measured first-pass words on a repeat line → cycle for remaining passes.
    private static func repeatedPasses(
        of real: [Word],
        lines: [Line],
        index: Int,
        paceMs: Int
    ) -> [Word]? {
        guard let marked = repeated(lines[index].text),
              let start = lines[index].startMs,
              let end = lineEndMs(lines: lines, index: index, paceMs: paceMs),
              end > start
        else { return nil }
        let markerText = marked.marker.trimmingCharacters(in: .whitespaces)
        let heard = real.filter { $0.text.isEmpty }.map(\.startMs)
        var sung = real.filter { !$0.text.isEmpty }
        if sung.last?.text.trimmingCharacters(in: .whitespaces) == markerText {
            sung.removeLast()
        }
        guard let first = sung.first, let last = sung.last else { return nil }
        let period = max(
            (end - first.startMs) / marked.passes,
            last.startMs - first.startMs + 600)
        let starts = heard.isEmpty ? nil : [first.startMs] + heard.sorted()
        let cycle = LyricRepeat(
            lineStartMs: first.startMs,
            periodMs: period,
            passes: marked.passes,
            startsMs: starts)
        var words = sung.map { word -> Word in
            var w = word
            w.cycle = cycle
            w.measured = true
            return w
        }
        if let tail = words.indices.last, !words[tail].text.hasSuffix(" ") {
            words[tail].text += " "
        }
        words.append(Word(
            text: marked.marker,
            startMs: starts?.last ?? first.startMs + period * (marked.passes - 1),
            marker: true,
            measured: true))
        return words
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
        // Aura: need a few fair samples; otherwise default pace.
        guard samples.count >= 3 else { return defaultPaceMsPerChar }
        samples.sort()
        return min(max(samples[samples.count / 2], 40), 300)
    }

    /// When the line at `index` stops being sung (word karaoke window end).
    ///
    /// Aura `LyricWordTiming.lineEnd`: paced sung length × 1.2, capped by the
    /// next stamp. Ordinary gaps run to the next line; instrumentals end early.
    static func lineEndMs(lines: [Line], index: Int, paceMs: Int? = nil) -> Int? {
        guard lines.indices.contains(index), let start = lines[index].startMs else { return nil }
        let pace = paceMs ?? paceMsPerChar(of: lines)

        if repeated(lines[index].text) != nil,
           let next = nextStartMs(after: index, in: lines), next > start {
            return next
        }

        let sung = start + max(1_500, sungLength(lines[index].text) * pace * 12 / 10)
        if let next = nextStartMs(after: index, in: lines), next > start {
            return min(next, sung)
        }
        return sung
    }

    /// When the line has been sung — Aura `lineFinish`.
    /// Measured cues: last word start + 600ms. Interpolated: `lineEndMs`.
    static func lineFinishMs(lines: [Line], index: Int) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        if repeated(lines[index].text) == nil,
           let last = lines[index].words.last,
           lines[index].words.contains(where: \.measured) {
            return last.startMs + 600
        }
        return lineEndMs(lines: lines, index: index)
    }

    /// Last line whose stamp has started (heard position).
    static func activeLineIndex(lines: [Line], atMs elapsedMs: Int) -> Int {
        var last = 0
        for (i, line) in lines.enumerated() {
            guard let start = line.startMs else { continue }
            if start <= elapsedMs { last = i } else { break }
        }
        return last
    }

    /// Focus line at `elapsedMs` (Aura `focusIndex`): after a real instrumental
    /// (>2s past finish), move halfway to the coming line so the sheet isn’t
    /// stuck on a finished line. Karaoke still keys off `Word.isLit`; the UI
    /// may scale the preview line, but words stay unlit until their starts.
    static func focusIndex(lines: [Line], after last: Int?, atMs elapsedMs: Int) -> Int? {
        guard let index = last, index + 1 < lines.count,
              let nextStart = lines[index + 1].startMs,
              let finished = lineFinishMs(lines: lines, index: index)
        else { return last }
        let breakLength = nextStart - finished
        guard breakLength > 2_000, elapsedMs >= finished + breakLength / 2 else { return index }
        return index + 1
    }

    /// Heard stamp + Aura mid-break focus — one index for scroll and line chrome.
    static func currentLineIndex(lines: [Line], atMs elapsedMs: Int) -> Int {
        let last = activeLineIndex(lines: lines, atMs: elapsedMs)
        return focusIndex(lines: lines, after: last, atMs: elapsedMs) ?? last
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
            words.append(Word(text: wordText, startMs: start, measured: true))
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
