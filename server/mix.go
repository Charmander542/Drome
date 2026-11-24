package main

import (
	"hash/fnv"
	"math"
	"math/rand/v2"
	"sort"
	"strings"
)

const (
	maxDailyMixes     = 6
	minDailyMixes     = 3
	dailyMixLength    = 46
	vibeMixLength     = 50
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
	// New release from an artist or style already in this listener's mix.
	Fresh bool `json:"fresh,omitempty"`
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
		// Unrated used to sit near 2★ (+4). On shared Navidrome libraries that
		// let other users' music dominate Daily Mixes — keep a tiny base so
		// cold-start still works, but require stars/ratings to climb.
		s += 0.75
	}
	if t.PlayCount > 0 {
		boost := math.Log2(1 + float64(t.PlayCount))
		// Play counts on a shared server mix every listener. Only trust them
		// fully when this user has starred or rated the track.
		if t.UserRating > 0 || t.isStarred() {
			s += boost
		} else {
			s += boost * 0.15
		}
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

func buildDailyMixes(tracks []mixTrack, similar map[string][]mixTrack, seed string, exclude map[string]struct{}) []dailyMix {
	rng := mixRNG(seed)
	pool := usableTracks(tracks)
	if len(exclude) > 0 {
		pool = filterExcluded(pool, exclude)
		similar = filterSimilarExcluded(similar, exclude)
	}
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
		songs = filterExcluded(songs, exclude)
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
			songs = filterExcluded(songs, exclude)
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

func filterExcluded(tracks []mixTrack, exclude map[string]struct{}) []mixTrack {
	if len(exclude) == 0 {
		return tracks
	}
	out := make([]mixTrack, 0, len(tracks))
	for _, t := range tracks {
		if _, skip := exclude[t.ID]; skip {
			continue
		}
		out = append(out, t)
	}
	return out
}

func filterSimilarExcluded(similar map[string][]mixTrack, exclude map[string]struct{}) map[string][]mixTrack {
	if len(exclude) == 0 || len(similar) == 0 {
		return similar
	}
	out := make(map[string][]mixTrack, len(similar))
	for k, list := range similar {
		filtered := filterExcluded(list, exclude)
		if len(filtered) > 0 {
			out[k] = filtered
		}
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
	var familiar, discover, fresh []mixTrack
	for _, t := range pool {
		if _, ok := used[t.ID]; ok {
			continue
		}
		inArtists := false
		if _, ok := c.artists[t.artistKey()]; ok {
			inArtists = true
		}
		inGenre := c.genre != "" && t.genreKey() == c.genre
		if t.Fresh && (inArtists || inGenre) {
			fresh = append(fresh, t)
			continue
		}
		if inArtists || inGenre {
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

	// Familiar, then a new release from the same artists when we have one,
	// otherwise an adjacent discovery. Cap how many "new" songs land so the
	// mix stays the listener's music with a few fresh arrivals.
	freshBudget := length / 5
	if freshBudget < 1 {
		freshBudget = 1
	}
	freshUsed := 0
	for len(out) < length {
		progress := false
		if take(&familiar, maxSongsPerArtist) {
			progress = true
		}
		if len(out) < length && take(&familiar, maxSongsPerArtist) {
			progress = true
		}
		if len(out) < length && freshUsed < freshBudget && take(&fresh, maxSongsPerArtist) {
			freshUsed++
			progress = true
		} else if len(out) < length && take(&discover, maxSongsPerArtist) {
			progress = true
		}
		if !progress {
			break
		}
	}
	for len(out) < length && take(&familiar, maxSongsPerArtist*2) {
	}
	for len(out) < length && take(&fresh, maxSongsPerArtist*2) {
	}
	for len(out) < length && take(&discover, maxSongsPerArtist*2) {
	}
	return sequenceMix(out, rng)
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

// mixCovers returns a single stable cover ID for the mix tile — the first
// track's artist image (Navidrome artist cover art ID).
func mixCovers(songs []mixTrack) []string {
	if len(songs) == 0 {
		return nil
	}
	t := songs[0]
	id := t.ArtistID
	if id == "" {
		id = t.CoverArt
	}
	if id == "" {
		id = t.AlbumID
	}
	if id == "" {
		id = t.ID
	}
	return []string{id}
}

// sequenceMix walks a chosen set so the next song stays near the last one.
// Same artist waits three slots when another artist is available. Genre
// neighbors count as "near"; a jazz → metal jump only happens when the
// current room has run out.
func sequenceMix(tracks []mixTrack, rng *rand.Rand) []mixTrack {
	pool := append([]mixTrack{}, tracks...)
	out := make([]mixTrack, 0, len(pool))
	var recent []string
	prev := ""
	for len(pool) > 0 {
		var beam []int
		var best float64
		for gap := 3; gap >= 0; gap-- {
			beam = beam[:0]
			best = -1
			for i, t := range pool {
				key := t.artistKey()
				if gap > 0 && key != "" && containsRecent(recent, key, gap) {
					continue
				}
				score := t.tasteScore()
				if prev != "" {
					score *= genreFit(t.genreKey(), prev)
				}
				if score > best {
					best = score
				}
				beam = append(beam, i)
				_ = score
			}
			// Rescore into a real beam: keep indexes whose score is close to best.
			if len(beam) == 0 {
				continue
			}
			type pair struct {
				i int
				s float64
			}
			scored := make([]pair, 0, len(beam))
			best = -1
			for _, i := range beam {
				t := pool[i]
				score := t.tasteScore()
				if prev != "" {
					score *= genreFit(t.genreKey(), prev)
				}
				if score > best {
					best = score
				}
				scored = append(scored, pair{i, score})
			}
			sort.Slice(scored, func(a, b int) bool { return scored[a].s > scored[b].s })
			keep := scored[:0]
			for _, p := range scored {
				if p.s >= best*0.72 {
					keep = append(keep, p)
				}
			}
			total := 0.0
			for _, p := range keep {
				total += p.s
			}
			if total <= 0 {
				total = float64(len(keep))
			}
			ticket := rng.Float64() * total
			pick := keep[0].i
			for _, p := range keep {
				w := p.s
				if w <= 0 {
					w = 1
				}
				ticket -= w
				if ticket <= 0 {
					pick = p.i
					break
				}
			}
			chosen := pool[pick]
			pool = append(pool[:pick], pool[pick+1:]...)
			out = append(out, chosen)
			recent = append(recent, chosen.artistKey())
			prev = chosen.genreKey()
			break
		}
	}
	return out
}

func containsRecent(recent []string, key string, gap int) bool {
	if gap <= 0 || key == "" {
		return false
	}
	start := len(recent) - gap
	if start < 0 {
		start = 0
	}
	for _, id := range recent[start:] {
		if id == key {
			return true
		}
	}
	return false
}

func genreFit(a, b string) float64 {
	if a == "" || b == "" || a == b {
		return 1
	}
	if genreNeighbors(a, b) {
		return 0.78
	}
	return 0.22
}

func genreNeighbors(a, b string) bool {
	_, ok := genreNeighborSet[a][b]
	if ok {
		return true
	}
	_, ok = genreNeighborSet[b][a]
	return ok
}

var genreNeighborSet = map[string]map[string]struct{}{
	"Jazz":        genreSet("Blues", "Soul", "Ambient", "Soundtrack"),
	"Blues":       genreSet("Jazz", "Soul", "Rock", "Folk"),
	"Soul":        genreSet("Jazz", "R&B", "Funk", "Blues", "Pop"),
	"R&B":         genreSet("Soul", "Hip-Hop", "Pop", "Funk"),
	"Funk":        genreSet("Soul", "R&B", "Pop"),
	"Hip-Hop":     genreSet("R&B", "Dance", "Electronic"),
	"Pop":         genreSet("Funk", "Soul", "Dance", "Indie", "R&B", "Reggae"),
	"Dance":       genreSet("Pop", "Electronic", "Hip-Hop", "Funk"),
	"Electronic":  genreSet("Dance", "Ambient", "Hip-Hop"),
	"Ambient":     genreSet("Electronic", "Jazz", "Classical", "Soundtrack"),
	"Classical":   genreSet("Ambient", "Soundtrack"),
	"Soundtrack":  genreSet("Classical", "Ambient", "Jazz"),
	"Folk":        genreSet("Country", "Indie", "Blues", "Alternative"),
	"Country":     genreSet("Folk", "Rock", "Blues"),
	"Indie":       genreSet("Folk", "Alternative", "Pop", "Rock"),
	"Alternative": genreSet("Indie", "Rock", "Punk", "Folk"),
	"Rock":        genreSet("Alternative", "Punk", "Country", "Blues", "Metal"),
	"Punk":        genreSet("Rock", "Alternative", "Metal"),
	"Metal":       genreSet("Rock", "Punk"),
	"Reggae":      genreSet("Soul", "Pop", "Folk"),
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
	title     string
	blurb     string
	primary   string
	genres    map[string]struct{}
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
		title: "Chill", blurb: "Story-first and unhurried — country & folk", primary: "Folk",
		genres:    genreSet("Country", "Folk", "Indie"),
		calmBoost: true,
	},
	"hype": {
		title: "Hype", blurb: "Go full send", primary: "Electronic",
		genres:    genreSet("Electronic", "Dance", "Hip-Hop", "Rock", "Metal", "Punk"),
		hypeBoost: true,
	},
	"lateNight": {
		title: "Late Night", blurb: "Quiet songs with words, for winding down", primary: "Jazz",
		genres: genreSet("Jazz", "Soul", "R&B", "Blues", "Folk", "Ambient"),
	},
	"feelGood": {
		title: "Feel-Good", blurb: "Sun coming through the windows", primary: "Pop",
		genres:    genreSet("Pop", "Funk", "Soul", "Reggae", "Indie", "Dance"),
		hypeBoost: true,
	},
	"focus": {
		title: "Focus", blurb: "Slow instrumentals — jazz & classical", primary: "Jazz",
		genres:    genreSet("Jazz", "Classical", "Ambient", "Soundtrack", "Blues"),
		calmBoost: true,
	},
	"heartbreak": {
		title: "Heartbreak", blurb: "The sad ones, on purpose", primary: "Indie",
		genres: genreSet("Indie", "Folk", "Alternative", "R&B", "Soul", "Pop"),
	},
	"lucky": {
		title: "I'm Feeling Lucky", blurb: "Surprise me", primary: "",
		genres: nil,
	},
}
