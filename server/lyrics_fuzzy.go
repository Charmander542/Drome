package main

import (
	"math"
	"sort"
	"strings"
	"unicode"
	"unicode/utf16"

	"golang.org/x/text/unicode/norm"
)

// Lyrics fuzzy matching — mirrors ios/Drome/Core/Services/LyricsFuzzySearch.swift.
// Keep behavior aligned so on-device and companion rankings feel the same.

type lyricsDocument struct {
	SongID     string
	Title      string
	Artist     string
	Album      string
	Lines      []string
	LineTokens [][]string
}

type lyricsScoredLine struct {
	LineIndex        int
	Line             string
	Score            float64
	MatchRanges      [][2]int // UTF-16 (location, length) into Line
	ContextBefore    string
	ContextAfter     string
	HasContextBefore bool
	HasContextAfter  bool
}

type lyricsHit struct {
	SongID        string  `json:"songId"`
	Title         string  `json:"title"`
	Artist        string  `json:"artist"`
	Album         string  `json:"album"`
	Snippet       string  `json:"snippet"`
	MatchedLine   string  `json:"matchedLine"`
	Score         float64 `json:"score"`
	MatchRanges   [][]int `json:"matchRanges"` // UTF-16 [location, length] into snippet
	Accessibility string  `json:"accessibilityLabel,omitempty"`
}

func normalizeLyricsText(raw string) string {
	// NFD + drop marks so café → cafe; then lowercase and strip punctuation.
	folded := strings.ToLower(norm.NFD.String(raw))
	var b strings.Builder
	b.Grow(len(folded))
	lastSpace := true
	for _, r := range folded {
		switch {
		case r == '\'' || r == '’' || r == '`' || r == '‘':
			// Drop apostrophes so don't == dont.
			continue
		case unicode.Is(unicode.Mn, r):
			continue
		case unicode.IsLetter(r) || unicode.IsNumber(r):
			b.WriteRune(r)
			lastSpace = false
		default:
			if !lastSpace {
				b.WriteByte(' ')
				lastSpace = true
			}
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

func lyricsTokens(raw string) []string {
	n := normalizeLyricsText(raw)
	if n == "" {
		return nil
	}
	return strings.Fields(n)
}

func maxEditDistance(tokenLen int) int {
	if tokenLen <= 1 {
		return 0
	}
	if tokenLen <= 4 {
		return 1
	}
	return 2
}

func damerauLevenshtein(a, b string, threshold int) int {
	if a == b {
		return 0
	}
	aRunes := []rune(a)
	bRunes := []rune(b)
	n, m := len(aRunes), len(bRunes)
	if absInt(n-m) > threshold {
		return threshold + 1
	}
	if n == 0 {
		return m
	}
	if m == 0 {
		return n
	}
	prevPrev := make([]int, m+1)
	prev := make([]int, m+1)
	curr := make([]int, m+1)
	for j := 0; j <= m; j++ {
		prev[j] = j
	}
	for i := 1; i <= n; i++ {
		curr[0] = i
		rowMin := curr[0]
		for j := 1; j <= m; j++ {
			cost := 1
			if aRunes[i-1] == bRunes[j-1] {
				cost = 0
			}
			best := minInt(prev[j]+1, curr[j-1]+1, prev[j-1]+cost)
			if i > 1 && j > 1 && aRunes[i-1] == bRunes[j-2] && aRunes[i-2] == bRunes[j-1] {
				best = minInt(best, prevPrev[j-2]+1)
			}
			curr[j] = best
			if best < rowMin {
				rowMin = best
			}
		}
		if rowMin > threshold {
			return threshold + 1
		}
		copy(prevPrev, prev)
		copy(prev, curr)
	}
	return prev[m]
}

func tokenSimilarity(query, candidate string) float64 {
	if query == "" || candidate == "" {
		return 0
	}
	if query == candidate {
		return 1
	}
	maxDist := maxEditDistance(minInt(len([]rune(query)), len([]rune(candidate))))
	if len([]rune(query)) >= 3 && strings.HasPrefix(candidate, query) {
		return 0.9
	}
	if len([]rune(candidate)) >= 3 && strings.HasPrefix(query, candidate) {
		return 0.85
	}
	dist := damerauLevenshtein(query, candidate, maxDist)
	if dist > maxDist {
		return 0
	}
	switch dist {
	case 0:
		return 1
	case 1:
		return 0.78
	default:
		return 0.58
	}
}

type lyricsTokenPair struct {
	qi, li int
	q      float64
}

func scoreLyricsLine(line string, lineTokens, queryTokens []string, lineIndex int, before, after string) *lyricsScoredLine {
	if len(queryTokens) == 0 || len(lineTokens) == 0 {
		return nil
	}
	used := map[int]bool{}
	var matched []lyricsTokenPair
	for qi, qt := range queryTokens {
		bestJ := -1
		bestQ := 0.0
		for ji, lt := range lineTokens {
			if used[ji] {
				continue
			}
			q := tokenSimilarity(qt, lt)
			if q > bestQ {
				bestQ = q
				bestJ = ji
			}
		}
		if bestJ >= 0 && bestQ >= 0.58 {
			used[bestJ] = true
			matched = append(matched, lyricsTokenPair{qi, bestJ, bestQ})
		}
	}
	if len(matched) == 0 {
		return nil
	}
	coverage := float64(len(matched)) / float64(len(queryTokens))
	minCoverage := 0.5
	switch {
	case len(queryTokens) <= 2:
		minCoverage = 1.0
	case len(queryTokens) <= 4:
		minCoverage = 0.6
	}
	if coverage+0.001 < minCoverage {
		return nil
	}
	qualitySum := 0.0
	for _, p := range matched {
		qualitySum += p.q
	}
	avgQuality := qualitySum / float64(len(matched))

	sort.Slice(matched, func(i, j int) bool { return matched[i].qi < matched[j].qi })
	inOrder := true
	adjacent := 0
	for i := 1; i < len(matched); i++ {
		if matched[i].li < matched[i-1].li {
			inOrder = false
		}
		if matched[i].li == matched[i-1].li+1 && matched[i].qi == matched[i-1].qi+1 {
			adjacent++
		}
	}
	orderBonus := 0.0
	if inOrder {
		orderBonus = 12
	}
	adjacentBonus := float64(adjacent) * 8
	extra := len(lineTokens) - len(matched)
	if extra < 0 {
		extra = 0
	}
	extraPenalty := math.Min(float64(extra)*1.5, 10)

	score := coverage*100 + avgQuality*40 + orderBonus + adjacentBonus - extraPenalty
	matchedIdx := map[int]bool{}
	for _, p := range matched {
		matchedIdx[p.li] = true
	}
	ranges := highlightUTF16Ranges(line, matchedIdx)
	scored := &lyricsScoredLine{
		LineIndex:   lineIndex,
		Line:        line,
		Score:       score,
		MatchRanges: ranges,
	}
	if before != "" {
		scored.ContextBefore = before
		scored.HasContextBefore = true
	}
	if after != "" {
		scored.ContextAfter = after
		scored.HasContextAfter = true
	}
	return scored
}

func highlightUTF16Ranges(line string, matchedTokenIndices map[int]bool) [][2]int {
	if len(matchedTokenIndices) == 0 {
		return nil
	}
	type wordSpan struct {
		start, end int // rune offsets
		tokenIndex int
	}
	runes := []rune(line)
	var spans []wordSpan
	tokenIndex := 0
	i := 0
	for i < len(runes) {
		for i < len(runes) && !isLyricWordRune(runes[i]) {
			i++
		}
		if i >= len(runes) {
			break
		}
		start := i
		for i < len(runes) && isLyricWordRune(runes[i]) {
			i++
		}
		end := i
		word := string(runes[start:end])
		if len(lyricsTokens(word)) > 0 {
			spans = append(spans, wordSpan{start: start, end: end, tokenIndex: tokenIndex})
			tokenIndex++
		}
	}
	var ranges [][2]int
	for _, sp := range spans {
		if !matchedTokenIndices[sp.tokenIndex] {
			continue
		}
		// Convert rune offsets to UTF-16 code units.
		prefix := string(runes[:sp.start])
		word := string(runes[sp.start:sp.end])
		loc := len(utf16.Encode([]rune(prefix)))
		length := len(utf16.Encode([]rune(word)))
		ranges = append(ranges, [2]int{loc, length})
	}
	return ranges
}

func isLyricWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || r == '\'' || r == '’' || r == '`'
}

// Cheap bag check before per-line scoring.
func docHasQueryCoverage(doc lyricsDocument, queryTokens []string) bool {
	unique := map[string]struct{}{}
	for _, lineToks := range doc.LineTokens {
		for _, t := range lineToks {
			unique[t] = struct{}{}
		}
	}
	matched := 0
	for _, qt := range queryTokens {
		for cand := range unique {
			if tokenSimilarity(qt, cand) >= 0.58 {
				matched++
				break
			}
		}
	}
	minCoverage := 0.5
	switch {
	case len(queryTokens) <= 2:
		minCoverage = 1.0
	case len(queryTokens) <= 4:
		minCoverage = 0.6
	}
	return float64(matched)/float64(len(queryTokens))+0.001 >= minCoverage
}

func bestLyricsLine(doc lyricsDocument, queryTokens []string) *lyricsScoredLine {
	var best *lyricsScoredLine
	for i, line := range doc.Lines {
		var toks []string
		if i < len(doc.LineTokens) {
			toks = doc.LineTokens[i]
		} else {
			toks = lyricsTokens(line)
		}
		if len(toks) == 0 {
			continue
		}
		before, after := "", ""
		if i > 0 {
			before = doc.Lines[i-1]
		}
		if i+1 < len(doc.Lines) {
			after = doc.Lines[i+1]
		}
		scored := scoreLyricsLine(line, toks, queryTokens, i, before, after)
		if scored == nil {
			continue
		}
		if best == nil || scored.Score > best.Score {
			best = scored
		}
	}
	return best
}

func makeLyricsSnippet(scored *lyricsScoredLine) string {
	if scored == nil {
		return ""
	}
	if len([]rune(scored.Line)) >= 48 {
		return scored.Line
	}
	parts := make([]string, 0, 3)
	if scored.HasContextBefore {
		parts = append(parts, scored.ContextBefore)
	}
	parts = append(parts, scored.Line)
	if scored.HasContextAfter {
		parts = append(parts, scored.ContextAfter)
	}
	if len(parts) == 1 {
		return scored.Line
	}
	return strings.Join(parts, " … ")
}

func lyricsBucketKey(token string) string {
	runes := []rune(token)
	// 3-char prefixes avoid coarse collisions (gonna ≠ good).
	if len(runes) >= 3 {
		return string(runes[:3])
	}
	if len(runes) >= 2 {
		return string(runes[:2])
	}
	return token
}

func candidateBucketKeys(token string) map[string]struct{} {
	keys := map[string]struct{}{lyricsBucketKey(token): {}}
	runes := []rune(token)
	if len(runes) < 2 {
		return keys
	}
	// Limit typo expansion to the first 3 characters of the token.
	alphabet := []rune("abcdefghijklmnopqrstuvwxyz0123456789")
	width := minInt(3, len(runes))
	for i := 0; i < width; i++ {
		for _, ch := range alphabet {
			if ch == runes[i] {
				continue
			}
			copyRunes := append([]rune{}, runes...)
			copyRunes[i] = ch
			keys[lyricsBucketKey(string(copyRunes))] = struct{}{}
		}
	}
	if len(runes) >= 2 {
		keys[lyricsBucketKey(string(runes[1:]))] = struct{}{}
		withoutSecond := append([]rune{runes[0]}, runes[2:]...)
		keys[lyricsBucketKey(string(withoutSecond))] = struct{}{}
		swapped := append([]rune{}, runes...)
		swapped[0], swapped[1] = swapped[1], swapped[0]
		keys[lyricsBucketKey(string(swapped))] = struct{}{}
	}
	if len(runes) >= 3 {
		withoutThird := append([]rune{}, runes[:2]...)
		withoutThird = append(withoutThird, runes[3:]...)
		keys[lyricsBucketKey(string(withoutThird))] = struct{}{}
	}
	return keys
}

func newLyricsDocument(songID, title, artist, album, plain string) lyricsDocument {
	rawLines := strings.Split(plain, "\n")
	lines := make([]string, 0, len(rawLines))
	for _, line := range rawLines {
		line = strings.TrimSpace(line)
		if line != "" {
			lines = append(lines, line)
		}
	}
	toks := make([][]string, len(lines))
	for i, line := range lines {
		toks[i] = lyricsTokens(line)
	}
	return lyricsDocument{
		SongID:     songID,
		Title:      title,
		Artist:     artist,
		Album:      album,
		Lines:      lines,
		LineTokens: toks,
	}
}

func searchLyricsDocuments(docs []lyricsDocument, buckets map[string][]int, query string, limit, candidateCap int) []lyricsHit {
	queryTokens := lyricsTokens(query)
	if len(queryTokens) == 0 || len(docs) == 0 {
		return nil
	}
	// Prefer exact prefix buckets first (fast path). Only expand typo-neighbor
	// buckets for tokens that contributed nothing — keeps large libraries snappy.
	candidateSet := map[int]struct{}{}
	addKey := func(key string) {
		for _, di := range buckets[key] {
			candidateSet[di] = struct{}{}
			if len(candidateSet) >= candidateCap {
				return
			}
		}
	}
	// Count how many query tokens "vote" for each document via exact buckets.
	votes := map[int]int{}
	emptyExact := make([]string, 0, len(queryTokens))
	for _, qt := range queryTokens {
		key := lyricsBucketKey(qt)
		seen := map[int]struct{}{}
		matchedAny := false
		for _, di := range buckets[key] {
			matchedAny = true
			if _, ok := seen[di]; ok {
				continue
			}
			seen[di] = struct{}{}
			votes[di]++
		}
		if !matchedAny {
			emptyExact = append(emptyExact, qt)
		}
	}
	minVotes := 1
	if len(queryTokens) >= 3 {
		minVotes = 2
	}
	for di, n := range votes {
		if n >= minVotes {
			candidateSet[di] = struct{}{}
			if len(candidateSet) >= candidateCap {
				break
			}
		}
	}
	if len(candidateSet) < 80 {
		for _, qt := range emptyExact {
			for key := range candidateBucketKeys(qt) {
				for _, di := range buckets[key] {
					// Fuzzy vote: accept if the doc already has ≥1 exact vote, or query is short.
					if votes[di] >= 1 || len(queryTokens) <= 2 {
						candidateSet[di] = struct{}{}
					}
					if len(candidateSet) >= candidateCap {
						break
					}
				}
				if len(candidateSet) >= candidateCap {
					break
				}
			}
			if len(candidateSet) >= candidateCap {
				break
			}
		}
	}
	candidates := make([]int, 0, len(candidateSet))
	if len(candidateSet) == 0 {
		// Last resort: fuzzy-expand the longest query token alone.
		longest := queryTokens[0]
		for _, qt := range queryTokens[1:] {
			if len(qt) > len(longest) {
				longest = qt
			}
		}
		for key := range candidateBucketKeys(longest) {
			addKey(key)
			if len(candidateSet) >= candidateCap {
				break
			}
		}
		for di := range candidateSet {
			candidates = append(candidates, di)
		}
	} else {
		for di := range candidateSet {
			candidates = append(candidates, di)
		}
	}

	hits := make([]lyricsHit, 0, minInt(limit, len(candidates)))
	for _, di := range candidates {
		doc := docs[di]
		if !docHasQueryCoverage(doc, queryTokens) {
			continue
		}
		scored := bestLyricsLine(doc, queryTokens)
		if scored == nil {
			continue
		}
		snippet := makeLyricsSnippet(scored)
		ranges := remapUTF16Ranges(scored.MatchRanges, scored.Line, snippet)
		matchRanges := make([][]int, 0, len(ranges))
		for _, r := range ranges {
			matchRanges = append(matchRanges, []int{r[0], r[1]})
		}
		hits = append(hits, lyricsHit{
			SongID:        doc.SongID,
			Title:         doc.Title,
			Artist:        doc.Artist,
			Album:         doc.Album,
			Snippet:       snippet,
			MatchedLine:   scored.Line,
			Score:         scored.Score,
			MatchRanges:   matchRanges,
			Accessibility: "Lyric match: " + scored.Line,
		})
	}
	sort.Slice(hits, func(i, j int) bool {
		if math.Abs(hits[i].Score-hits[j].Score) > 0.25 {
			return hits[i].Score > hits[j].Score
		}
		return strings.ToLower(hits[i].Title) < strings.ToLower(hits[j].Title)
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
}

func buildLyricsBuckets(docs []lyricsDocument) map[string][]int {
	buckets := map[string][]int{}
	for di, doc := range docs {
		seen := map[string]struct{}{}
		for _, lineToks := range doc.LineTokens {
			for _, tok := range lineToks {
				key := lyricsBucketKey(tok)
				if _, ok := seen[key]; ok {
					continue
				}
				seen[key] = struct{}{}
				buckets[key] = append(buckets[key], di)
			}
		}
	}
	return buckets
}

func remapUTF16Ranges(ranges [][2]int, source, snippet string) [][2]int {
	if source == snippet {
		return ranges
	}
	idx := strings.Index(snippet, source)
	if idx < 0 {
		return nil
	}
	prefixUTF16 := len(utf16.Encode([]rune(snippet[:idx])))
	out := make([][2]int, 0, len(ranges))
	for _, r := range ranges {
		out = append(out, [2]int{r[0] + prefixUTF16, r[1]})
	}
	return out
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func minInt(vals ...int) int {
	if len(vals) == 0 {
		return 0
	}
	m := vals[0]
	for _, v := range vals[1:] {
		if v < m {
			m = v
		}
	}
	return m
}

// stripLRCTimestamps removes [mm:ss.xx] / <mm:ss.xx> tags for indexing.
func stripLRCTimestamps(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	i := 0
	for i < len(raw) {
		if raw[i] == '[' || raw[i] == '<' {
			closeCh := byte(']')
			if raw[i] == '<' {
				closeCh = '>'
			}
			j := i + 1
			for j < len(raw) && raw[j] != closeCh && raw[j] != '\n' {
				j++
			}
			if j < len(raw) && raw[j] == closeCh {
				// Heuristic: treat as timestamp if digits/colon inside.
				inner := raw[i+1 : j]
				if looksLikeTimestamp(inner) {
					i = j + 1
					continue
				}
			}
		}
		b.WriteByte(raw[i])
		i++
	}
	return b.String()
}

func looksLikeTimestamp(s string) bool {
	s = strings.TrimSpace(strings.ToLower(s))
	if strings.HasPrefix(s, "offset:") {
		return true
	}
	hasDigit := false
	hasColon := false
	for _, r := range s {
		if unicode.IsDigit(r) {
			hasDigit = true
		} else if r == ':' || r == '.' {
			hasColon = true
		} else if !unicode.IsSpace(r) {
			return false
		}
	}
	return hasDigit && hasColon
}
