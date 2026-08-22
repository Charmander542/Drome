package main

import (
	"hash/fnv"
	"math"
	"math/rand/v2"
	"sort"
	"strings"
)

const (
	maxDailyMixes   = 6
	minDailyMixes   = 3
	dailyMixLength  = 46
	vibeMixLength   = 50
	maxSongsPerArtist = 4
	minClusterSongs   = 8
)

// mixTrack is the working unit for Daily Mix / vibe generation.
type mixTrack struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Album      string `json:"album,omitempty"`
	AlbumID    string `json:"albumId,omitempty"`
	Artist     string `json:"artist,omitempty"`
	ArtistID   string `json:"artistId,omitempty"`
	Genre      string `json:"genre,omitempty"`
	CoverArt   string `json:"coverArt,omitempty"`
	Duration   int    `json:"duration,omitempty"`
	Year       int    `json:"year,omitempty"`
	Track      int    `json:"track,omitempty"`
	PlayCount  int    `json:"playCount,omitempty"`
	UserRating int    `json:"userRating,omitempty"`
	Starred    string `json:"starred,omitempty"`
}

func (t mixTrack) genreKey() string {
	return normalizeGenre(t.Genre)
}

func (t mixTrack) artistKey() string {
	if t.ArtistID != "" {
		return t.ArtistID
	}
	return strings.ToLower(strings.TrimSpace(t.Artist))
}

func (t mixTrack) isStarred() bool { return t.Starred != "" }

func (t mixTrack) tasteScore() float64 {
	if t.UserRating == 1 {
		return 0.05
	}
	s := 1.0
	if t.isStarred() {
		s += 6
	}
	if t.UserRating > 0 {
		s += float64(t.UserRating * t.UserRating)
	} else {
		s += 4 // unrated sits near 2★ so new libraries still mix
	}
	if t.PlayCount > 0 {
		s += math.Log2(1 + float64(t.PlayCount))
	}
	return s
}

type dailyMix struct {
	ID          string     `json:"id"`
	Index       int        `json:"index"`
	Title       string     `json:"title"`
	Subtitle    string     `json:"subtitle"`
	Colors      []string   `json:"colors"`
	CoverArtIDs []string   `json:"coverArtIds"`
	Songs       []mixTrack `json:"songs"`
}

type vibeMix struct {
	ID       string     `json:"id"`
	Title    string     `json:"title"`
	Subtitle string     `json:"subtitle"`
	Songs    []mixTrack `json:"songs"`
}

var mixPalettes = [][]string{
	{"#2A9D8F", "#1D3557"},
	{"#E76F51", "#6D2E4B"},
	{"#7B61FF", "#1B1340"},
	{"#F4A261", "#9B2226"},
	{"#40916C", "#081C15"},
	{"#C9184A", "#370617"},
}

type artistStat struct {
	key    string
	name   string
	genre  string
	score  float64
	tracks int
}

type mixCluster struct {
	artists map[string]string // id -> display name
	genre   string
	score   float64
}

func mixRNG(seed string) *rand.Rand {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	n := h.Sum64()
	return rand.New(rand.NewPCG(n, n^0x9E3779B97F4A7C15))
}

func buildDailyMixes(tracks []mixTrack, similar map[string][]mixTrack, seed string) []dailyMix {
	rng := mixRNG(seed)
	pool := usableTracks(tracks)
	if len(pool) < minClusterSongs {
		return nil
	}
	clusters := pickClusters(pool, rng)
	if len(clusters) == 0 {
		return nil
	}

	used := map[string]struct{}{}
	out := make([]dailyMix, 0, len(clusters))
	for i, c := range clusters {
		songs := fillCluster(c, pool, similar, used, rng, dailyMixLength)
		if len(songs) < minClusterSongs {
			continue
		}
		idx := len(out) + 1
		out = append(out, dailyMix{
			ID:          "daily-" + itoa(idx),
			Index:       idx,
			Title:       "Daily Mix " + itoa(idx),
			Subtitle:    mixSubtitle(c),
			Colors:      mixPalettes[i%len(mixPalettes)],
			CoverArtIDs: mixCovers(songs),
			Songs:       songs,
		})
	}
	if len(out) < minDailyMixes && len(pool) >= minClusterSongs*minDailyMixes {
		// Genre collapsed — split leftover high-score artists into extra mixes.
		extra := artistFallbackClusters(pool, used, minDailyMixes-len(out))
		for _, c := range extra {
			songs := fillCluster(c, pool, similar, used, rng, dailyMixLength)
			if len(songs) < minClusterSongs {
				continue
			}
			idx := len(out) + 1
			out = append(out, dailyMix{
				ID:          "daily-" + itoa(idx),
				Index:       idx,
				Title:       "Daily Mix " + itoa(idx),
				Subtitle:    mixSubtitle(c),
				Colors:      mixPalettes[(idx-1)%len(mixPalettes)],
				CoverArtIDs: mixCovers(songs),
				Songs:       songs,
			})
		}
	}
	return out
}

func buildVibeMix(tracks []mixTrack, similar map[string][]mixTrack, vibe string, seed string) vibeMix {
	rng := mixRNG(seed + "|" + vibe)
	spec, ok := vibeSpecs[vibe]
	if !ok {
		spec = vibeSpecs["lucky"]
	}
	pool := usableTracks(tracks)
	scored := make([]mixTrack, 0, len(pool))
	for _, t := range pool {
		if spec.matches(t) || vibe == "lucky" {
			scored = append(scored, t)
		}
	}
	if len(scored) < 12 && vibe != "lucky" {
		// Soften: keep anything adjacent via similar-to-matching anchors.
		anchors := topArtistKeys(scored, 8)
		extra := map[string]struct{}{}
		for _, a := range anchors {
			for _, t := range similar[a] {
				extra[t.ID] = struct{}{}
			}
		}
		for _, t := range pool {
			if _, ok := extra[t.ID]; ok {
				scored = append(scored, t)
			}
		}
		scored = uniqueTracks(scored)
	}
	if len(scored) < 8 {
		scored = pool
	}

	// Re-weight for the vibe's energy, then treat as a single cluster.
	for i := range scored {
		scored[i] = spec.reweight(scored[i])
	}
	cluster := mixCluster{
		artists: map[string]string{},
		genre:   spec.primary,
		score:   0,
	}
	for _, a := range topArtists(scored, 8) {
		cluster.artists[a.key] = a.name
		cluster.score += a.score
		if cluster.genre == "" {
			cluster.genre = a.genre
		}
	}
	used := map[string]struct{}{}
	songs := fillCluster(cluster, scored, similar, used, rng, vibeMixLength)
	if len(songs) < vibeMixLength {
		// Pad from remaining scored tracks so a sparse library still plays.
		rest := append([]mixTrack{}, scored...)
		weightedShuffle(rest, rng)
		for _, t := range rest {
			if _, ok := used[t.ID]; ok {
				continue
			}
			songs = append(songs, t)
			used[t.ID] = struct{}{}
			if len(songs) >= vibeMixLength {
				break
			}
		}
	}
	return vibeMix{
		ID:       vibe,
		Title:    spec.title,
		Subtitle: spec.blurb,
		Songs:    songs,
	}
}

func usableTracks(tracks []mixTrack) []mixTrack {
	out := make([]mixTrack, 0, len(tracks))
	seen := map[string]struct{}{}
	for _, t := range tracks {
		if t.ID == "" || t.Title == "" {
			continue
		}
		if t.UserRating == 1 {
			continue
		}
		if _, ok := seen[t.ID]; ok {
			continue
		}
		seen[t.ID] = struct{}{}
		out = append(out, t)
	}
	return out
}

func uniqueTracks(tracks []mixTrack) []mixTrack {
	seen := map[string]struct{}{}
	out := make([]mixTrack, 0, len(tracks))
	for _, t := range tracks {
		if t.ID == "" {
			continue
		}
		if _, ok := seen[t.ID]; ok {
			continue
		}
		seen[t.ID] = struct{}{}
		out = append(out, t)
	}
	return out
}

func pickClusters(tracks []mixTrack, rng *rand.Rand) []mixCluster {
	artists := topArtists(tracks, 40)
	if len(artists) == 0 {
		return nil
	}
	byGenre := map[string][]artistStat{}
	for _, a := range artists {
		g := a.genre
		if g == "" {
			g = "Mix"
		}
		byGenre[g] = append(byGenre[g], a)
	}
	type bucket struct {
		genre   string
		artists []artistStat
		score   float64
	}
	var buckets []bucket
	for g, list := range byGenre {
		b := bucket{genre: g, artists: list}
		for _, a := range list {
			b.score += a.score
		}
		if len(list) >= 1 && b.score > 0 {
			buckets = append(buckets, b)
		}
	}
	sort.Slice(buckets, func(i, j int) bool { return buckets[i].score > buckets[j].score })

	k := maxDailyMixes
	if len(buckets) < k {
		k = len(buckets)
	}
	if k > maxDailyMixes {
		k = maxDailyMixes
	}

	usedArtist := map[string]struct{}{}
	var clusters []mixCluster
	for _, b := range buckets {
		c := mixCluster{artists: map[string]string{}, genre: b.genre}
		for _, a := range b.artists {
			if _, taken := usedArtist[a.key]; taken {
				continue
			}
			if len(c.artists) >= 6 {
				break
			}
			c.artists[a.key] = a.name
			c.score += a.score
			usedArtist[a.key] = struct{}{}
		}
		if len(c.artists) == 0 {
			continue
		}
		clusters = append(clusters, c)
		if len(clusters) >= k {
			break
		}
	}
	_ = rng
	return clusters
}

func artistFallbackClusters(tracks []mixTrack, usedSongs map[string]struct{}, need int) []mixCluster {
	if need <= 0 {
		return nil
	}
	remaining := make([]mixTrack, 0, len(tracks))
	for _, t := range tracks {
		if _, ok := usedSongs[t.ID]; ok {
			continue
		}
		remaining = append(remaining, t)
	}
	artists := topArtists(remaining, need*4)
	var out []mixCluster
	taken := map[string]struct{}{}
	for _, a := range artists {
		if _, ok := taken[a.key]; ok {
			continue
		}
		c := mixCluster{artists: map[string]string{a.key: a.name}, genre: a.genre, score: a.score}
		taken[a.key] = struct{}{}
		out = append(out, c)
		if len(out) >= need {
			break
		}
	}
	return out
}

func fillCluster(c mixCluster, pool []mixTrack, similar map[string][]mixTrack, used map[string]struct{}, rng *rand.Rand, length int) []mixTrack {
	var familiar, discover []mixTrack
	for _, t := range pool {
		if _, ok := used[t.ID]; ok {
			continue
		}
		if _, ok := c.artists[t.artistKey()]; ok {
			familiar = append(familiar, t)
			continue
		}
		if c.genre != "" && t.genreKey() == c.genre {
			familiar = append(familiar, t)
		}
	}
	sort.SliceStable(familiar, func(i, j int) bool {
		return familiar[i].tasteScore() > familiar[j].tasteScore()
	})

	leads := make([]string, 0, len(c.artists))
	for id := range c.artists {
		leads = append(leads, id)
	}
	sort.Slice(leads, func(i, j int) bool { return leads[i] < leads[j] })
	if len(leads) > 4 {
		leads = leads[:4]
	}
	seenDisc := map[string]struct{}{}
	for _, id := range leads {
		for _, t := range similar[id] {
			if t.ID == "" {
				continue
			}
			if _, ok := used[t.ID]; ok {
				continue
			}
			if _, ok := seenDisc[t.ID]; ok {
				continue
			}
			seenDisc[t.ID] = struct{}{}
			discover = append(discover, t)
		}
	}
	weightedShuffle(discover, rng)

	out := make([]mixTrack, 0, length)
	artistN := map[string]int{}
	take := func(src *[]mixTrack, cap int) bool {
		for i := 0; i < len(*src); i++ {
			t := (*src)[i]
			if _, ok := used[t.ID]; ok {
				continue
			}
			ak := t.artistKey()
			if cap > 0 && ak != "" && artistN[ak] >= cap {
				continue
			}
			used[t.ID] = struct{}{}
			if ak != "" {
				artistN[ak]++
			}
			out = append(out, t)
			*src = append((*src)[:i], (*src)[i+1:]...)
			return true
		}
		return false
	}

	// ~70% familiar / 30% adjacent discovery, interleaved so it doesn't
	// dump all known tracks first. Cap per artist, then relax if the
	// cluster is a handful of big names.
	for len(out) < length {
		progress := false
		if take(&familiar, maxSongsPerArtist) {
			progress = true
		}
		if len(out) < length && take(&familiar, maxSongsPerArtist) {
			progress = true
		}
		if len(out) < length && take(&discover, maxSongsPerArtist) {
			progress = true
		}
		if !progress {
			break
		}
	}
	for len(out) < length && take(&familiar, maxSongsPerArtist*2) {
	}
	for len(out) < length && take(&discover, maxSongsPerArtist*2) {
	}
	return out
}

func topArtists(tracks []mixTrack, n int) []artistStat {
	by := map[string]*artistStat{}
	genreCount := map[string]map[string]int{}
	for _, t := range tracks {
		key := t.artistKey()
		if key == "" {
			continue
		}
		st := by[key]
		if st == nil {
			st = &artistStat{key: key, name: t.Artist}
			by[key] = st
			genreCount[key] = map[string]int{}
		}
		st.score += t.tasteScore()
		st.tracks++
		if g := t.genreKey(); g != "" {
			genreCount[key][g]++
		}
	}
	out := make([]artistStat, 0, len(by))
	for key, st := range by {
		best, bestN := "", 0
		for g, c := range genreCount[key] {
			if c > bestN {
				best, bestN = g, c
			}
		}
		st.genre = best
		out = append(out, *st)
		_ = key
	}
	sort.Slice(out, func(i, j int) bool { return out[i].score > out[j].score })
	if len(out) > n {
		out = out[:n]
	}
	return out
}

func topArtistKeys(tracks []mixTrack, n int) []string {
	arts := topArtists(tracks, n)
	keys := make([]string, 0, len(arts))
	for _, a := range arts {
		keys = append(keys, a.key)
	}
	return keys
}

func mixSubtitle(c mixCluster) string {
	names := make([]string, 0, len(c.artists))
	for _, n := range c.artists {
		n = strings.TrimSpace(n)
		if n != "" {
			names = append(names, n)
		}
	}
	sort.Slice(names, func(i, j int) bool { return names[i] < names[j] })
	if len(names) > 3 {
		names = names[:3]
	}
	if len(names) == 0 {
		if c.genre != "" && c.genre != "Mix" {
			return c.genre
		}
		return "Made for you"
	}
	if len(names) == 1 {
		return names[0]
	}
	if len(names) == 2 {
		return names[0] + " and " + names[1]
	}
	return names[0] + ", " + names[1] + ", and more"
}

func mixCovers(songs []mixTrack) []string {
	seen := map[string]struct{}{}
	var ids []string
	for _, t := range songs {
		id := t.CoverArt
		if id == "" {
			id = t.AlbumID
		}
		if id == "" {
			id = t.ID
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
		if len(ids) == 4 {
			break
		}
	}
	return ids
}

func weightedShuffle(tracks []mixTrack, rng *rand.Rand) {
	type pair struct {
		t mixTrack
		k float64
	}
	pairs := make([]pair, len(tracks))
	for i, t := range tracks {
		w := t.tasteScore()
		if w < 0.01 {
			w = 0.01
		}
		// Efraimidis–Spirakis: key = U^(1/w)
		u := rng.Float64()
		if u <= 0 {
			u = 1e-12
		}
		pairs[i] = pair{t: t, k: math.Pow(u, 1.0/w)}
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].k > pairs[j].k })
	for i := range pairs {
		tracks[i] = pairs[i].t
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

type vibeSpec struct {
	title    string
	blurb    string
	primary  string
	genres   map[string]struct{}
	hypeBoost bool
	calmBoost bool
}

func (v vibeSpec) matches(t mixTrack) bool {
	if len(v.genres) == 0 {
		return true
	}
	g := t.genreKey()
	if g == "" {
		return false
	}
	_, ok := v.genres[g]
	return ok
}

func (v vibeSpec) reweight(t mixTrack) mixTrack {
	s := t.tasteScore()
	if v.hypeBoost && t.PlayCount > 0 {
		t.PlayCount = t.PlayCount + int(math.Log2(1+float64(t.PlayCount))*3)
	}
	if v.calmBoost && t.PlayCount > 40 {
		t.PlayCount = t.PlayCount / 2
	}
	_ = s
	return t
}

func genreSet(names ...string) map[string]struct{} {
	m := map[string]struct{}{}
	for _, n := range names {
		m[n] = struct{}{}
	}
	return m
}

var vibeSpecs = map[string]vibeSpec{
	"chill": {
		title: "Chill", blurb: "Soft edges, low lights", primary: "Ambient",
		genres:    genreSet("Ambient", "Indie", "Jazz", "R&B", "Folk", "Electronic", "Soul"),
		calmBoost: true,
	},
	"hype": {
		title: "Hype", blurb: "Go full send", primary: "Electronic",
		genres:    genreSet("Electronic", "Dance", "Hip-Hop", "Rock", "Metal", "Punk"),
		hypeBoost: true,
	},
	"lateNight": {
		title: "Late Night", blurb: "Headphones at 1am", primary: "Jazz",
		genres: genreSet("Jazz", "Soul", "R&B", "Blues", "Electronic", "Ambient"),
	},
	"feelGood": {
		title: "Feel-Good", blurb: "Windows-down energy", primary: "Pop",
		genres:    genreSet("Pop", "Indie", "Funk", "Dance", "Reggae", "Soul"),
		hypeBoost: true,
	},
	"focus": {
		title: "Focus", blurb: "Get in the zone", primary: "Classical",
		genres:    genreSet("Classical", "Ambient", "Soundtrack", "Electronic", "Jazz"),
		calmBoost: true,
	},
	"heartbreak": {
		title: "Heartbreak", blurb: "Feel it fully", primary: "Indie",
		genres: genreSet("Indie", "Folk", "Alternative", "R&B", "Soul", "Pop"),
	},
	"lucky": {
		title: "I'm Feeling Lucky", blurb: "Surprise me", primary: "",
		genres: nil,
	},
}
