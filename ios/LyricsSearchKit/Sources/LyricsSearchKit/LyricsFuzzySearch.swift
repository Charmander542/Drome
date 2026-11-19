import Foundation

/// Pure lyrics fuzzy-matching helpers: normalization, Damerau–Levenshtein
/// token tolerance, bag-of-tokens line scoring, and highlight ranges.
/// Kept free of UI / database so LyricsSearchKit can unit-test the same file.
enum LyricsFuzzySearch: Sendable {

    struct ScoredLine: Sendable, Equatable {
        var lineIndex: Int
        var line: String
        var score: Double
        /// UTF-16 ranges into `line` for matched display words (VoiceOver / bold).
        var matchRanges: [Range<String.Index>]
        var contextBefore: String?
        var contextAfter: String?
    }

    struct Document: Sendable {
        var songId: String
        var title: String
        var artist: String
        var album: String
        /// Plain lyric lines (timestamps already stripped).
        var lines: [String]
        /// Precomputed normalized tokens per line.
        var lineTokens: [[String]]
    }

    struct Hit: Sendable, Identifiable {
        var id: String { songId }
        var songId: String
        var title: String
        var artist: String
        var album: String
        var snippet: String
        var matchedLine: String
        var score: Double
        var matchRanges: [Range<String.Index>]
        /// Spoken form, e.g. "Lyric match: never gonna give you up".
        var accessibilityLabel: String
    }

    // MARK: - Normalization

    /// Fold case/diacritics, strip punctuation, drop apostrophes so
    /// `don't` / `dont` / `don’t` all become `dont`.
    static func normalize(_ raw: String) -> String {
        let folded = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars {
            // Apostrophes / quotes — drop so contractions collapse.
            if scalar == "'" || scalar == "\u{2019}" || scalar == "`" || scalar == "\u{2018}" {
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            } else if scalar == " " || CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar) {
                if scalars.last != " " {
                    scalars.append(" ")
                }
            } else {
                if scalars.last != " " {
                    scalars.append(" ")
                }
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func tokens(from raw: String) -> [String] {
        normalize(raw)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func maxEditDistance(forTokenLength length: Int) -> Int {
        if length <= 1 { return 0 }
        if length <= 4 { return 1 }
        return 2
    }

    // MARK: - Damerau–Levenshtein

    /// Restricted Damerau–Levenshtein (insert/delete/substitute/transpose).
    /// Returns `threshold + 1` as soon as the distance cannot beat `threshold`.
    static func damerauLevenshtein(_ a: String, _ b: String, threshold: Int) -> Int {
        if a == b { return 0 }
        let aChars = Array(a.utf8)
        let bChars = Array(b.utf8)
        let n = aChars.count
        let m = bChars.count
        if abs(n - m) > threshold { return threshold + 1 }
        if n == 0 { return m }
        if m == 0 { return n }

        var prevPrev = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            var rowMin = curr[0]
            let aByte = aChars[i - 1]
            for j in 1...m {
                let cost = aByte == bChars[j - 1] ? 0 : 1
                var best = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
                // Transposition of adjacent characters.
                if i > 1, j > 1,
                   aChars[i - 1] == bChars[j - 2],
                   aChars[i - 2] == bChars[j - 1] {
                    best = min(best, prevPrev[j - 2] + 1)
                }
                curr[j] = best
                rowMin = min(rowMin, best)
            }
            if rowMin > threshold {
                return threshold + 1
            }
            prevPrev = prev
            prev = curr
            curr = [Int](repeating: 0, count: m + 1)
        }
        return prev[m]
    }

    /// Quality in `0...1` for how well `query` matches `candidate`.
    static func tokenSimilarity(_ query: String, _ candidate: String) -> Double {
        if query.isEmpty || candidate.isEmpty { return 0 }
        if query == candidate { return 1 }

        let maxDist = maxEditDistance(forTokenLength: min(query.count, candidate.count))
        // Prefix / partial: "give" ↔ "giving", "never" ↔ "neve"
        if query.count >= 3, candidate.hasPrefix(query) {
            return 0.9
        }
        if candidate.count >= 3, query.hasPrefix(candidate) {
            return 0.85
        }
        let dist = damerauLevenshtein(query, candidate, threshold: maxDist)
        guard dist <= maxDist else { return 0 }
        if dist == 0 { return 1 }
        if dist == 1 { return 0.78 }
        return 0.58
    }

    // MARK: - Line scoring

    /// Score one lyric line against query tokens. Returns nil when the line
    /// is not a useful match (too few tokens, weak coverage).
    static func scoreLine(
        line: String,
        lineTokens: [String],
        queryTokens: [String],
        lineIndex: Int,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) -> ScoredLine? {
        guard !queryTokens.isEmpty, !lineTokens.isEmpty else { return nil }

        // Greedy one-to-one assignment of query tokens → best unused line tokens.
        var used = Set<Int>()
        var matchedPairs: [(queryIdx: Int, lineIdx: Int, quality: Double)] = []
        matchedPairs.reserveCapacity(queryTokens.count)

        for (qi, qt) in queryTokens.enumerated() {
            var bestJ: Int?
            var bestQ: Double = 0
            for (ji, lt) in lineTokens.enumerated() where !used.contains(ji) {
                let q = tokenSimilarity(qt, lt)
                if q > bestQ {
                    bestQ = q
                    bestJ = ji
                }
            }
            if let bestJ, bestQ >= 0.58 {
                used.insert(bestJ)
                matchedPairs.append((qi, bestJ, bestQ))
            }
        }

        let coverage = Double(matchedPairs.count) / Double(queryTokens.count)
        // Short queries need a solid hit; longer phrases tolerate missing words.
        let minCoverage = queryTokens.count <= 2 ? 1.0 : (queryTokens.count <= 4 ? 0.6 : 0.5)
        guard coverage + 0.001 >= minCoverage, !matchedPairs.isEmpty else { return nil }

        let qualitySum = matchedPairs.reduce(0.0) { $0 + $1.quality }
        let avgQuality = qualitySum / Double(matchedPairs.count)

        // Bag-of-tokens base + bonuses for preserving order / adjacency.
        let sortedByQuery = matchedPairs.sorted { $0.queryIdx < $1.queryIdx }
        var inOrder = true
        var adjacent = 0
        for i in 1..<sortedByQuery.count {
            if sortedByQuery[i].lineIdx < sortedByQuery[i - 1].lineIdx {
                inOrder = false
            }
            if sortedByQuery[i].lineIdx == sortedByQuery[i - 1].lineIdx + 1,
               sortedByQuery[i].queryIdx == sortedByQuery[i - 1].queryIdx + 1 {
                adjacent += 1
            }
        }
        let orderBonus = inOrder ? 12.0 : 0.0
        let adjacentBonus = Double(adjacent) * 8.0
        // Mild penalty when the line has many extra unmatched words.
        let extra = max(0, lineTokens.count - matchedPairs.count)
        let extraPenalty = min(Double(extra) * 1.5, 10.0)

        let score = coverage * 100.0
            + avgQuality * 40.0
            + orderBonus
            + adjacentBonus
            - extraPenalty

        let ranges = highlightRanges(in: line, matchedLineTokenIndices: Set(matchedPairs.map(\.lineIdx)))
        return ScoredLine(
            lineIndex: lineIndex,
            line: line,
            score: score,
            matchRanges: ranges,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }

    /// Map normalized token indices back onto display words in `line`.
    static func highlightRanges(in line: String, matchedLineTokenIndices: Set<Int>) -> [Range<String.Index>] {
        guard !matchedLineTokenIndices.isEmpty else { return [] }
        // Walk display words; normalize each the same way as indexing.
        var ranges: [Range<String.Index>] = []
        var tokenIndex = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            // Skip separators.
            while idx < line.endIndex {
                let ch = line[idx]
                if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "`" {
                    break
                }
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex else { break }
            let start = idx
            while idx < line.endIndex {
                let ch = line[idx]
                if !(ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "`") {
                    break
                }
                idx = line.index(after: idx)
            }
            let end = idx
            let word = String(line[start..<end])
            let norm = tokens(from: word)
            if !norm.isEmpty {
                if matchedLineTokenIndices.contains(tokenIndex) {
                    ranges.append(start..<end)
                }
                tokenIndex += 1
            }
        }
        return ranges
    }

    static func documentHasQueryCoverage(_ document: Document, queryTokens: [String]) -> Bool {
        var unique = Set<String>()
        for lineToks in document.lineTokens {
            unique.formUnion(lineToks)
        }
        var matched = 0
        for qt in queryTokens {
            if unique.contains(where: { tokenSimilarity(qt, $0) >= 0.58 }) {
                matched += 1
            }
        }
        let minCoverage: Double
        switch queryTokens.count {
        case 0...2: minCoverage = 1.0
        case 3...4: minCoverage = 0.6
        default: minCoverage = 0.5
        }
        return Double(matched) / Double(queryTokens.count) + 0.001 >= minCoverage
    }

    /// Best-scoring line in a document, if any.
    static func bestLine(in document: Document, queryTokens: [String]) -> ScoredLine? {
        guard !queryTokens.isEmpty else { return nil }
        var best: ScoredLine?
        for (i, line) in document.lines.enumerated() {
            let toks = i < document.lineTokens.count ? document.lineTokens[i] : tokens(from: line)
            guard !toks.isEmpty else { continue }
            let before = i > 0 ? document.lines[i - 1] : nil
            let after = i + 1 < document.lines.count ? document.lines[i + 1] : nil
            guard let scored = scoreLine(
                line: line,
                lineTokens: toks,
                queryTokens: queryTokens,
                lineIndex: i,
                contextBefore: before,
                contextAfter: after
            ) else { continue }
            if best == nil || scored.score > best!.score {
                best = scored
            }
        }
        return best
    }

    static func makeSnippet(from scored: ScoredLine) -> String {
        var parts: [String] = []
        if let before = scored.contextBefore, !before.isEmpty {
            parts.append(before)
        }
        parts.append(scored.line)
        if let after = scored.contextAfter, !after.isEmpty {
            parts.append(after)
        }
        if parts.count == 1 { return scored.line }
        // Prefer the matched line alone when context would drown Dynamic Type.
        if scored.line.count >= 48 { return scored.line }
        return parts.joined(separator: " … ")
    }

    /// Search a corpus. Caps how many documents are fully scored after a cheap
    /// token-bucket prefilter so large libraries stay responsive.
    static func search(
        documents: [Document],
        query: String,
        limit: Int = 40,
        candidateCap: Int = 600,
        prebuiltBuckets: [String: [Int]]? = nil
    ) -> [Hit] {
        let queryTokens = tokens(from: query)
        guard !queryTokens.isEmpty else { return [] }

        let buckets: [String: [Int]]
        if let prebuiltBuckets {
            buckets = prebuiltBuckets
        } else {
            var built: [String: [Int]] = [:]
            for (di, doc) in documents.enumerated() {
                var seen = Set<String>()
                for lineToks in doc.lineTokens {
                    for tok in lineToks {
                        let key = bucketKey(tok)
                        if seen.insert(key).inserted {
                            built[key, default: []].append(di)
                        }
                    }
                }
            }
            buckets = built
        }

        var candidateSet = Set<Int>()
        var votes: [Int: Int] = [:]
        var emptyExact: [String] = []
        for qt in queryTokens {
            let key = bucketKey(qt)
            let bucket = buckets[key] ?? []
            if bucket.isEmpty {
                emptyExact.append(qt)
                continue
            }
            var seen = Set<Int>()
            for di in bucket where seen.insert(di).inserted {
                votes[di, default: 0] += 1
            }
        }
        let minVotes = queryTokens.count >= 3 ? 2 : 1
        for (di, n) in votes where n >= minVotes {
            candidateSet.insert(di)
            if candidateSet.count >= candidateCap { break }
        }
        if candidateSet.count < 80 {
            for qt in emptyExact {
                for key in candidateBucketKeys(for: qt) {
                    for di in buckets[key] ?? [] {
                        if (votes[di] ?? 0) >= 1 || queryTokens.count <= 2 {
                            candidateSet.insert(di)
                        }
                        if candidateSet.count >= candidateCap { break }
                    }
                    if candidateSet.count >= candidateCap { break }
                }
                if candidateSet.count >= candidateCap { break }
            }
        }

        let candidates: [Int]
        if candidateSet.isEmpty {
            let longest = queryTokens.max(by: { $0.count < $1.count }) ?? queryTokens[0]
            for key in candidateBucketKeys(for: longest) {
                for di in buckets[key] ?? [] {
                    candidateSet.insert(di)
                    if candidateSet.count >= candidateCap { break }
                }
                if candidateSet.count >= candidateCap { break }
            }
            if candidateSet.isEmpty {
                candidates = Array(documents.indices.prefix(candidateCap))
            } else {
                candidates = Array(candidateSet.prefix(candidateCap))
            }
        } else {
            candidates = Array(candidateSet.prefix(candidateCap))
        }

        var hits: [Hit] = []
        hits.reserveCapacity(min(limit, candidates.count))
        for di in candidates {
            let doc = documents[di]
            guard documentHasQueryCoverage(doc, queryTokens: queryTokens) else { continue }
            guard let scored = bestLine(in: doc, queryTokens: queryTokens) else { continue }
            let snippet = makeSnippet(from: scored)
            // Remap highlight ranges onto snippet when we prepended context.
            let ranges: [Range<String.Index>]
            if snippet == scored.line {
                ranges = scored.matchRanges
            } else if let before = scored.contextBefore, snippet.hasPrefix(before) {
                ranges = remapRanges(scored.matchRanges, from: scored.line, into: snippet)
            } else {
                ranges = remapRanges(scored.matchRanges, from: scored.line, into: snippet)
            }
            hits.append(Hit(
                songId: doc.songId,
                title: doc.title,
                artist: doc.artist,
                album: doc.album,
                snippet: snippet,
                matchedLine: scored.line,
                score: scored.score,
                matchRanges: ranges,
                accessibilityLabel: "Lyric match: \(scored.line)"
            ))
        }

        hits.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.25 { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        if hits.count > limit {
            hits = Array(hits.prefix(limit))
        }
        return hits
    }

    static func document(songId: String, title: String, artist: String, album: String, plainContent: String) -> Document {
        let lines = plainContent
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lineTokens = lines.map { tokens(from: $0) }
        return Document(
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            lines: lines,
            lineTokens: lineTokens
        )
    }

    // MARK: - Buckets

    static func bucketKey(_ token: String) -> String {
        // 3-char prefixes avoid coarse collisions (gonna ≠ good).
        if token.count >= 3 {
            return String(token.prefix(3))
        }
        if token.count >= 2 {
            return String(token.prefix(2))
        }
        return token
    }

    /// Keys that could hold a fuzzy neighbor of `token` (same / 1-edit prefixes).
    static func candidateBucketKeys(for token: String) -> Set<String> {
        var keys: Set<String> = [bucketKey(token)]
        guard token.count >= 2 else { return keys }
        let chars = Array(token)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let width = min(3, chars.count)
        for i in 0..<width {
            for ch in alphabet where ch != chars[i] {
                var copy = chars
                copy[i] = ch
                keys.insert(bucketKey(String(copy)))
            }
        }
        keys.insert(bucketKey(String(chars.dropFirst())))
        var withoutSecond = chars
        withoutSecond.remove(at: 1)
        keys.insert(bucketKey(String(withoutSecond)))
        var swapped = chars
        swapped.swapAt(0, 1)
        keys.insert(bucketKey(String(swapped)))
        if chars.count >= 3 {
            var withoutThird = chars
            withoutThird.remove(at: 2)
            keys.insert(bucketKey(String(withoutThird)))
        }
        return keys
    }

    static func remapRanges(
        _ ranges: [Range<String.Index>],
        from source: String,
        into snippet: String
    ) -> [Range<String.Index>] {
        guard let found = snippet.range(of: source) else { return [] }
        return ranges.compactMap { range in
            guard range.lowerBound >= source.startIndex, range.upperBound <= source.endIndex else { return nil }
            let fromOffset = source.distance(from: source.startIndex, to: range.lowerBound)
            let toOffset = source.distance(from: source.startIndex, to: range.upperBound)
            let start = snippet.index(found.lowerBound, offsetBy: fromOffset)
            let end = snippet.index(found.lowerBound, offsetBy: toOffset)
            return start..<end
        }
    }
}
