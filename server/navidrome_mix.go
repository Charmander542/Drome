package main

import (
	"context"
	"encoding/json"
	"net/url"
	"sync"
)

type ndSong struct {
	ID         flexString `json:"id"`
	Title      string     `json:"title"`
	Album      string     `json:"album"`
	AlbumID    flexString `json:"albumId"`
	Artist     string     `json:"artist"`
	ArtistID   flexString `json:"artistId"`
	Genre      string     `json:"genre"`
	CoverArt   flexString `json:"coverArt"`
	Duration   int        `json:"duration"`
	Year       int        `json:"year"`
	Track      int        `json:"track"`
	PlayCount  int        `json:"playCount"`
	UserRating int        `json:"userRating"`
	Starred    string     `json:"starred"`
}

func (s ndSong) asMix() mixTrack {
	cover := s.CoverArt.String()
	if cover == "" {
		cover = s.AlbumID.String()
	}
	return mixTrack{
		ID:         s.ID.String(),
		Title:      s.Title,
		Album:      s.Album,
		AlbumID:    s.AlbumID.String(),
		Artist:     s.Artist,
		ArtistID:   s.ArtistID.String(),
		Genre:      s.Genre,
		CoverArt:   cover,
		Duration:   s.Duration,
		Year:       s.Year,
		Track:      s.Track,
		PlayCount:  s.PlayCount,
		UserRating: s.UserRating,
		Starred:    s.Starred,
	}
}

type ndSongList []ndSong

func (p *ndSongList) UnmarshalJSON(b []byte) error {
	b = bytesTrim(b)
	if len(b) == 0 || string(b) == "null" {
		*p = nil
		return nil
	}
	if b[0] == '{' {
		var one ndSong
		if err := json.Unmarshal(b, &one); err != nil {
			return err
		}
		*p = []ndSong{one}
		return nil
	}
	var many []ndSong
	if err := json.Unmarshal(b, &many); err != nil {
		return err
	}
	*p = many
	return nil
}

func bytesTrim(b []byte) []byte {
	i, j := 0, len(b)
	for i < j && (b[i] == ' ' || b[i] == '\n' || b[i] == '\t' || b[i] == '\r') {
		i++
	}
	for j > i && (b[j-1] == ' ' || b[j-1] == '\n' || b[j-1] == '\t' || b[j-1] == '\r') {
		j--
	}
	return b[i:j]
}

func (v *navidromeVerifier) mixSnapshot(ctx context.Context, creds subsonicCreds) []mixTrack {
	var (
		mu    sync.Mutex
		songs []mixTrack
		seen  = map[string]struct{}{}
	)
	add := func(list []ndSong, star bool) {
		mu.Lock()
		defer mu.Unlock()
		for _, s := range list {
			t := s.asMix()
			if t.ID == "" {
				continue
			}
			if _, ok := seen[t.ID]; ok {
				if star && t.Starred == "" {
					for i := range songs {
						if songs[i].ID == t.ID {
							songs[i].Starred = "true"
							break
						}
					}
				}
				continue
			}
			seen[t.ID] = struct{}{}
			if star && t.Starred == "" {
				t.Starred = "true"
			}
			songs = append(songs, t)
		}
	}

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		add(v.getStarredSongs(ctx, creds), true)
	}()
	go func() {
		defer wg.Done()
		add(v.getRandomSongs(ctx, creds, 280), false)
	}()
	go func() {
		defer wg.Done()
		add(v.frequentAlbumSongs(ctx, creds, 8), false)
	}()
	wg.Wait()
	return songs
}

func (v *navidromeVerifier) similarByArtists(ctx context.Context, creds subsonicCreds, artistIDs []string, per int) map[string][]mixTrack {
	out := make(map[string][]mixTrack, len(artistIDs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for _, id := range artistIDs {
		if id == "" {
			continue
		}
		wg.Add(1)
		go func(artistID string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			list := v.getSimilarSongs(ctx, creds, artistID, per)
			tracks := make([]mixTrack, 0, len(list))
			for _, s := range list {
				if t := s.asMix(); t.ID != "" {
					tracks = append(tracks, t)
				}
			}
			mu.Lock()
			out[artistID] = tracks
			mu.Unlock()
		}(id)
	}
	wg.Wait()
	return out
}

func (v *navidromeVerifier) getStarredSongs(ctx context.Context, creds subsonicCreds) []ndSong {
	raw, err := v.subsonicGET(ctx, "getStarred2", creds, nil)
	if err != nil {
		return nil
	}
	var body struct {
		Starred2 struct {
			Song ndSongList `json:"song"`
		} `json:"starred2"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body.Starred2.Song
}

func (v *navidromeVerifier) getRandomSongs(ctx context.Context, creds subsonicCreds, size int) []ndSong {
	extra := url.Values{}
	extra.Set("size", itoa(size))
	raw, err := v.subsonicGET(ctx, "getRandomSongs", creds, extra)
	if err != nil {
		return nil
	}
	var body struct {
		RandomSongs struct {
			Song ndSongList `json:"song"`
		} `json:"randomSongs"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body.RandomSongs.Song
}

func (v *navidromeVerifier) getSimilarSongs(ctx context.Context, creds subsonicCreds, artistID string, count int) []ndSong {
	extra := url.Values{}
	extra.Set("id", artistID)
	extra.Set("count", itoa(count))
	raw, err := v.subsonicGET(ctx, "getSimilarSongs2", creds, extra)
	if err != nil {
		return nil
	}
	var body struct {
		Similar struct {
			Song ndSongList `json:"song"`
		} `json:"similarSongs2"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body.Similar.Song
}

func (v *navidromeVerifier) getSongsByGenre(ctx context.Context, creds subsonicCreds, genre string, count int) []ndSong {
	extra := url.Values{}
	extra.Set("genre", genre)
	extra.Set("count", itoa(count))
	raw, err := v.subsonicGET(ctx, "getSongsByGenre", creds, extra)
	if err != nil {
		return nil
	}
	var body struct {
		Songs struct {
			Song ndSongList `json:"song"`
		} `json:"songsByGenre"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body.Songs.Song
}

func (v *navidromeVerifier) frequentAlbumSongs(ctx context.Context, creds subsonicCreds, albumLimit int) []ndSong {
	extra := url.Values{}
	extra.Set("type", "frequent")
	extra.Set("size", itoa(albumLimit))
	raw, err := v.subsonicGET(ctx, "getAlbumList2", creds, extra)
	if err != nil {
		return nil
	}
	var body struct {
		AlbumList2 struct {
			Album []struct {
				ID flexString `json:"id"`
			} `json:"album"`
		} `json:"albumList2"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	ids := body.AlbumList2.Album
	if len(ids) > albumLimit {
		ids = ids[:albumLimit]
	}
	var (
		mu   sync.Mutex
		out  []ndSong
		wg   sync.WaitGroup
	)
	for _, a := range ids {
		id := a.ID.String()
		if id == "" {
			continue
		}
		wg.Add(1)
		go func(albumID string) {
			defer wg.Done()
			songs := v.getAlbumSongs(ctx, creds, albumID)
			mu.Lock()
			out = append(out, songs...)
			mu.Unlock()
		}(id)
	}
	wg.Wait()
	return out
}

func (v *navidromeVerifier) getAlbumSongs(ctx context.Context, creds subsonicCreds, albumID string) []ndSong {
	extra := url.Values{}
	extra.Set("id", albumID)
	raw, err := v.subsonicGET(ctx, "getAlbum", creds, extra)
	if err != nil {
		return nil
	}
	var body struct {
		Album struct {
			Song ndSongList `json:"song"`
		} `json:"album"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return nil
	}
	return body.Album.Song
}

func (v *navidromeVerifier) vibeGenreSongs(ctx context.Context, creds subsonicCreds, vibe string) []mixTrack {
	spec, ok := vibeSpecs[vibe]
	if !ok || len(spec.genres) == 0 {
		return nil
	}
	var (
		mu  sync.Mutex
		out []mixTrack
	)
	var wg sync.WaitGroup
	for g := range spec.genres {
		wg.Add(1)
		go func(genre string) {
			defer wg.Done()
			list := v.getSongsByGenre(ctx, creds, genre, 40)
			mu.Lock()
			for _, s := range list {
				if t := s.asMix(); t.ID != "" {
					out = append(out, t)
				}
			}
			mu.Unlock()
		}(g)
	}
	wg.Wait()
	return out
}
