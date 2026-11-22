package main

import (
	"strings"
	"unicode"
)

// normalizeGenre maps messy tags onto a small curated set so Daily Mixes
// cluster by taste, not by whatever string the files happened to carry.
func normalizeGenre(raw string) string {
	key := genreKey(raw)
	if key == "" {
		return ""
	}
	if mapped, ok := genreAliases[key]; ok {
		return mapped
	}
	return ""
}

func genreKey(raw string) string {
	var b strings.Builder
	pendingSpace := false
	for _, r := range strings.ToLower(strings.TrimSpace(raw)) {
		switch {
		case unicode.IsLetter(r) || unicode.IsNumber(r):
			if pendingSpace && b.Len() > 0 {
				b.WriteByte(' ')
			}
			pendingSpace = false
			b.WriteRune(r)
		case r == '&':
			// Collapse any pending whitespace into a single separator before "and".
			pendingSpace = false
			if b.Len() > 0 {
				b.WriteByte(' ')
			}
			b.WriteString("and")
			pendingSpace = true
		default:
			pendingSpace = true
		}
	}
	return strings.TrimSpace(b.String())
}

var genreAliases = map[string]string{
	"rock": "Rock", "classic rock": "Rock", "hard rock": "Rock", "soft rock": "Rock",
	"progressive rock": "Rock", "prog rock": "Rock", "prog": "Rock",
	"psychedelic rock": "Rock", "psych rock": "Rock", "grunge": "Rock",
	"post rock": "Rock", "garage rock": "Rock", "blues rock": "Rock",
	"album rock": "Rock", "pop rock": "Rock", "rock and roll": "Rock",
	"pop": "Pop", "synth pop": "Pop", "synthpop": "Pop", "electropop": "Pop",
	"k pop": "Pop", "kpop": "Pop", "dance pop": "Pop", "britpop": "Pop",
	"art pop": "Pop", "chamber pop": "Pop", "indie pop": "Indie",
	"hip hop": "Hip-Hop", "hiphop": "Hip-Hop", "rap": "Hip-Hop", "trap": "Hip-Hop",
	"gangsta rap": "Hip-Hop", "hip hop rap": "Hip-Hop",
	"r and b": "R&B", "rnb": "R&B", "neo soul": "R&B", "soul": "Soul",
	"rhythm and blues": "R&B",
	"electronic": "Electronic", "edm": "Electronic", "electronica": "Electronic",
	"idm": "Electronic", "downtempo": "Electronic", "synthwave": "Electronic",
	"new wave": "Electronic",
	"dance": "Dance", "house": "Dance", "techno": "Dance", "trance": "Dance",
	"disco": "Dance", "drum and bass": "Dance", "dubstep": "Dance",
	"jazz": "Jazz", "smooth jazz": "Jazz", "acid jazz": "Jazz",
	"classical": "Classical", "orchestral": "Classical",
	"soundtrack": "Soundtrack", "ost": "Soundtrack", "score": "Soundtrack",
	"film scores": "Soundtrack", "films games": "Soundtrack",
	"stage and screen": "Musical", "musical": "Musical", "broadway": "Musical",
	"show tunes": "Musical", "musical theatre": "Musical", "musical theater": "Musical",
	"metal": "Metal", "heavy metal": "Metal", "death metal": "Metal", "black metal": "Metal",
	"punk": "Punk", "pop punk": "Punk", "emo": "Punk",
	"folk": "Folk", "singer songwriter": "Folk", "americana": "Folk",
	"folk rock": "Folk",
	"country": "Country", "indie": "Indie", "indie rock": "Indie", "lo fi": "Indie",
	"lofi": "Indie", "dream pop": "Indie", "noise": "Indie",
	"alternative": "Alternative", "alt rock": "Alternative", "alternative rock": "Alternative",
	"shoegaze": "Alternative",
	"funk": "Funk", "blues": "Blues", "reggae": "Reggae", "ska": "Reggae",
	"latin": "Latin", "world": "World", "ambient": "Ambient", "chillout": "Ambient",
	"new age": "Ambient", "experimental": "Experimental",
}

func init() {
	// Every curated name should resolve to itself.
	for _, name := range []string{
		"Rock", "Pop", "Hip-Hop", "R&B", "Electronic", "Dance", "Jazz",
		"Classical", "Metal", "Punk", "Folk", "Country", "Indie", "Alternative",
		"Soul", "Funk", "Blues", "Reggae", "Latin", "Soundtrack", "Musical",
		"World", "Ambient", "Experimental",
	} {
		genreAliases[genreKey(name)] = name
	}
}
