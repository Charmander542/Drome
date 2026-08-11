package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// spotifyClient resolves pasted Spotify links into track/album metadata.
// Prefer the official Web API when client credentials are configured; otherwise
// use Spotify's public pages / oEmbed (no API key required). SpotiFLAC downloads
// never need the official API.
type spotifyClient struct {
	clientID     string
	clientSecret string
	market       string
	http         *http.Client

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
}

func newSpotifyClient(id, secret, market string) *spotifyClient {
	if market == "" {
		market = "US"
	}
	return &spotifyClient{
		clientID:     id,
		clientSecret: secret,
		market:       market,
		http:         &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *spotifyClient) hasAPICreds() bool {
	return c.clientID != "" && c.clientSecret != ""
}

var spotifyIDPattern = regexp.MustCompile(`^[0-9A-Za-z]{15,40}$`)

// parseSpotifyLink accepts open.spotify.com URLs (including /intl-xx/ and
// /embed/ variants) and spotify:track:... URIs, returning the resource kind
// ("track", "album", or "playlist") and its Spotify ID.
func parseSpotifyLink(raw string) (kind, id string, err error) {
	raw = strings.TrimSpace(raw)

	if strings.HasPrefix(raw, "spotify:") {
		parts := strings.Split(raw, ":")
		if len(parts) == 3 && (parts[1] == "track" || parts[1] == "album" || parts[1] == "playlist") && spotifyIDPattern.MatchString(parts[2]) {
			return parts[1], parts[2], nil
		}
		return "", "", fmt.Errorf("unsupported spotify URI %q", raw)
	}

	u, err := url.Parse(raw)
	if err != nil {
		return "", "", fmt.Errorf("not a valid URL: %w", err)
	}
	host := strings.ToLower(u.Hostname())
	if host != "open.spotify.com" && host != "play.spotify.com" {
		return "", "", fmt.Errorf("not a spotify link (host %q)", host)
	}

	segments := []string{}
	for _, s := range strings.Split(u.Path, "/") {
		if s == "" || s == "embed" || strings.HasPrefix(s, "intl-") {
			continue
		}
		segments = append(segments, s)
	}
	if len(segments) >= 2 && (segments[0] == "track" || segments[0] == "album" || segments[0] == "playlist") && spotifyIDPattern.MatchString(segments[1]) {
		return segments[0], segments[1], nil
	}
	return "", "", fmt.Errorf("unsupported spotify link (only track, album, and playlist links are supported)")
}

func (c *spotifyClient) token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accessToken != "" && time.Now().Before(c.tokenExpiry) {
		return c.accessToken, nil
	}
	if !c.hasAPICreds() {
		return "", fmt.Errorf("spotify credentials are not configured on the server")
	}

	form := url.Values{"grant_type": {"client_credentials"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://accounts.spotify.com/api/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.SetBasicAuth(c.clientID, c.clientSecret)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("spotify token request failed: %s", resp.Status)
	}

	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	c.accessToken = body.AccessToken
	c.tokenExpiry = time.Now().Add(time.Duration(body.ExpiresIn-60) * time.Second)
	return c.accessToken, nil
}

func (c *spotifyClient) apiGET(ctx context.Context, path string, out any) error {
	tok, err := c.token(ctx)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.spotify.com/v1"+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return fmt.Errorf("spotify resource not found")
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		detail := strings.TrimSpace(string(body))
		if detail == "" {
			return fmt.Errorf("spotify API error: %s", resp.Status)
		}
		return fmt.Errorf("spotify API error: %s — %s", resp.Status, detail)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

type spotifyArtist struct {
	Name string `json:"name"`
}

type spotifyImage struct {
	URL    string `json:"url"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

func joinArtists(artists []spotifyArtist) string {
	names := make([]string, 0, len(artists))
	for _, a := range artists {
		names = append(names, a.Name)
	}
	return strings.Join(names, ", ")
}

func firstArtistName(artists []spotifyArtist) string {
	if len(artists) == 0 {
		return ""
	}
	return artists[0].Name
}

func bestImage(images []spotifyImage) string {
	best := ""
	bestW := -1
	for _, img := range images {
		if img.Width > bestW {
			best, bestW = img.URL, img.Width
		}
	}
	return best
}

// resolve fills in an entry's metadata. Uses the Web API when credentials are
// set; otherwise scrapes public Open Graph / oEmbed (no API key).
func (c *spotifyClient) resolve(ctx context.Context, kind, id string) (*entry, error) {
	e := &entry{Kind: kind, SpotifyID: id, SpotifyURL: "https://open.spotify.com/" + kind + "/" + id}
	if c.hasAPICreds() {
		if err := c.resolveAPI(ctx, e); err == nil {
			return e, nil
		} else {
			logf("spotify API resolve failed, falling back to public metadata: %v", err)
		}
	}
	if err := c.resolvePublic(ctx, e); err != nil {
		return nil, err
	}
	return e, nil
}

func (c *spotifyClient) resolveAPI(ctx context.Context, e *entry) error {
	switch e.Kind {
	case "track":
		var t struct {
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
			Album   struct {
				ID      string          `json:"id"`
				Name    string          `json:"name"`
				Artists []spotifyArtist `json:"artists"`
				Images  []spotifyImage  `json:"images"`
			} `json:"album"`
		}
		if err := c.apiGET(ctx, "/tracks/"+e.SpotifyID, &t); err != nil {
			return err
		}
		e.Title = t.Name
		e.Artist = joinArtists(t.Artists)
		e.AlbumArtist = firstArtistName(t.Album.Artists)
		if e.AlbumArtist == "" {
			e.AlbumArtist = firstArtistName(t.Artists)
		}
		e.Album = t.Album.Name
		e.CoverURL = bestImage(t.Album.Images)
		if t.Album.ID != "" {
			if upc, err := c.albumUPC(ctx, t.Album.ID); err == nil {
				e.UPC = upc
			}
		}
	case "album":
		var a struct {
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
			Images  []spotifyImage  `json:"images"`
			ExternalIDs struct {
				UPC string `json:"upc"`
			} `json:"external_ids"`
		}
		if err := c.apiGET(ctx, "/albums/"+e.SpotifyID, &a); err != nil {
			return err
		}
		e.Title = a.Name
		e.Artist = joinArtists(a.Artists)
		e.AlbumArtist = firstArtistName(a.Artists)
		if e.AlbumArtist == "" {
			e.AlbumArtist = e.Artist
		}
		e.Album = a.Name
		e.CoverURL = bestImage(a.Images)
		e.UPC = a.ExternalIDs.UPC
	case "playlist":
		var p struct {
			Name  string `json:"name"`
			Owner struct {
				DisplayName string `json:"display_name"`
			} `json:"owner"`
			Images []spotifyImage `json:"images"`
		}
		if err := c.apiGET(ctx, "/playlists/"+e.SpotifyID, &p); err != nil {
			return err
		}
		e.Title = p.Name
		e.Artist = p.Owner.DisplayName
		e.AlbumArtist = p.Owner.DisplayName
		e.Album = p.Name
		e.CoverURL = bestImage(p.Images)
	default:
		return fmt.Errorf("unsupported kind %q", e.Kind)
	}
	return nil
}

func (c *spotifyClient) albumUPC(ctx context.Context, albumID string) (string, error) {
	var a struct {
		ExternalIDs struct {
			UPC string `json:"upc"`
		} `json:"external_ids"`
	}
	if err := c.apiGET(ctx, "/albums/"+albumID, &a); err != nil {
		return "", err
	}
	return a.ExternalIDs.UPC, nil
}

// albumIdentity returns primary album artist + UPC for retagging downloads so
// Navidrome groups an album as one release even when tracks have guest artists.
func (c *spotifyClient) albumIdentity(ctx context.Context, e *entry) (albumArtist, upc string) {
	if e.AlbumArtist != "" {
		albumArtist = e.AlbumArtist
		upc = e.UPC
		if upc != "" || !c.hasAPICreds() {
			return albumArtist, upc
		}
	}
	if !c.hasAPICreds() {
		if albumArtist != "" {
			return albumArtist, upc
		}
		return e.Artist, ""
	}
	tmp := &entry{Kind: e.Kind, SpotifyID: e.SpotifyID}
	if err := c.resolveAPI(ctx, tmp); err != nil {
		if albumArtist != "" {
			return albumArtist, upc
		}
		return e.Artist, ""
	}
	if tmp.AlbumArtist != "" {
		albumArtist = tmp.AlbumArtist
	} else if albumArtist == "" {
		albumArtist = tmp.Artist
	}
	if tmp.UPC != "" {
		upc = tmp.UPC
	}
	return albumArtist, upc
}

var (
	ogTitleRe = regexp.MustCompile(`(?i)(?:property|name)="og:title"\s+content="([^"]+)"`)
	ogDescRe  = regexp.MustCompile(`(?i)(?:property|name)="og:description"\s+content="([^"]+)"`)
	ogImageRe = regexp.MustCompile(`(?i)(?:property|name)="og:image"\s+content="([^"]+)"`)
)

func (c *spotifyClient) resolvePublic(ctx context.Context, e *entry) error {
	if err := c.resolveOpenGraph(ctx, e); err == nil && e.Title != "" {
		return nil
	}
	return c.resolveOEmbed(ctx, e)
}

func (c *spotifyClient) resolveOpenGraph(ctx context.Context, e *entry) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, e.SpotifyURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; drome-server/1.0)")
	req.Header.Set("Accept-Language", "en")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("spotify page: %s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return err
	}
	html := string(body)

	title := htmlUnescape(firstSubmatch(ogTitleRe, html))
	desc := htmlUnescape(firstSubmatch(ogDescRe, html))
	image := htmlUnescape(firstSubmatch(ogImageRe, html))
	if title == "" && desc == "" {
		return fmt.Errorf("no open-graph metadata on spotify page")
	}

	e.CoverURL = image
	switch e.Kind {
	case "track":
		// og:description ≈ "Artist · Title · Song · 2017"
		parts := splitSpotifyDesc(desc)
		e.Title = title
		if e.Title == "" && len(parts) >= 2 {
			e.Title = parts[1]
		}
		if len(parts) >= 1 {
			e.Artist = parts[0]
			e.AlbumArtist = parts[0]
		}
		// Album isn't reliably in OG for tracks; leave empty.
	case "album":
		// og:title ≈ "Album - Album by Artist | Spotify"
		// og:description ≈ "Artist · album · 2012 · 18 songs"
		parts := splitSpotifyDesc(desc)
		e.Title = cleanAlbumTitle(title)
		e.Album = e.Title
		if len(parts) >= 1 {
			e.Artist = parts[0]
			e.AlbumArtist = parts[0]
		}
	}
	if e.Title == "" {
		return fmt.Errorf("could not parse title from public metadata")
	}
	if e.AlbumArtist == "" {
		e.AlbumArtist = e.Artist
	}
	return nil
}

func (c *spotifyClient) resolveOEmbed(ctx context.Context, e *entry) error {
	u := "https://open.spotify.com/oembed?url=" + url.QueryEscape(e.SpotifyURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("spotify oembed: %s", resp.Status)
	}
	var body struct {
		Title        string `json:"title"`
		ThumbnailURL string `json:"thumbnail_url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return err
	}
	if body.Title == "" {
		return fmt.Errorf("spotify oembed returned empty title")
	}
	e.Title = cleanAlbumTitle(body.Title)
	if e.Kind == "album" {
		e.Album = e.Title
	}
	e.CoverURL = body.ThumbnailURL
	return nil
}

type searchHit struct {
	Kind       string `json:"kind"`
	SpotifyID  string `json:"spotifyId"`
	SpotifyURL string `json:"spotifyUrl"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Album      string `json:"album"`
	CoverURL   string `json:"coverUrl"`
	TrackCount int    `json:"trackCount,omitempty"`
}

// playlistTrack is one track pulled from a Spotify playlist for wishlist import.
type playlistTrack struct {
	SpotifyID  string
	SpotifyURL string
	Title      string
	Artist     string
	Album      string
	CoverURL   string
}

func (c *spotifyClient) playlistTracks(ctx context.Context, playlistID string) (name string, tracks []playlistTrack, err error) {
	if !c.hasAPICreds() {
		return "", nil, fmt.Errorf("spotify playlist import requires API credentials")
	}
	var meta struct {
		Name string `json:"name"`
	}
	if err := c.apiGET(ctx, "/playlists/"+playlistID+"?fields=name", &meta); err != nil {
		return "", nil, err
	}
	name = meta.Name

	path := "/playlists/" + playlistID + "/tracks?limit=50&market=" + url.QueryEscape(c.market) +
		"&fields=next,items(track(id,name,artists(name),album(name,images),external_urls))"
	for path != "" {
		var page struct {
			Next  *string `json:"next"`
			Items []struct {
				Track *struct {
					ID      string          `json:"id"`
					Name    string          `json:"name"`
					Artists []spotifyArtist `json:"artists"`
					Album   struct {
						Name   string         `json:"name"`
						Images []spotifyImage `json:"images"`
					} `json:"album"`
					ExternalURLs struct {
						Spotify string `json:"spotify"`
					} `json:"external_urls"`
				} `json:"track"`
			} `json:"items"`
		}
		// apiGET expects path under /v1 — absolute next URLs need stripping.
		apiPath := path
		if strings.HasPrefix(apiPath, "https://api.spotify.com/v1") {
			apiPath = strings.TrimPrefix(apiPath, "https://api.spotify.com/v1")
		}
		if err := c.apiGET(ctx, apiPath, &page); err != nil {
			return name, tracks, err
		}
		for _, item := range page.Items {
			if item.Track == nil || item.Track.ID == "" {
				continue
			}
			t := item.Track
			u := t.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/track/" + t.ID
			}
			tracks = append(tracks, playlistTrack{
				SpotifyID:  t.ID,
				SpotifyURL: u,
				Title:      t.Name,
				Artist:     joinArtists(t.Artists),
				Album:      t.Album.Name,
				CoverURL:   bestImage(t.Album.Images),
			})
		}
		if page.Next == nil || *page.Next == "" {
			break
		}
		path = *page.Next
	}
	return name, tracks, nil
}

func (c *spotifyClient) artistImageURL(ctx context.Context, name string) (string, error) {
	if !c.hasAPICreds() {
		return "", fmt.Errorf("spotify artist images require API credentials")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("artist name is empty")
	}
	hits, err := c.search(ctx, name, "artist", 5)
	if err != nil {
		return "", err
	}
	for _, h := range hits {
		if h.Kind == "artist" && h.CoverURL != "" {
			return h.CoverURL, nil
		}
	}
	return "", fmt.Errorf("no artist image found")
}

// search queries the Spotify Web API. Requires client credentials.
//
// Spotify’s Feb 2026 Search changes cap `limit` at 10 and expect a `market`
// when using client-credentials tokens (no user country on the token).
func (c *spotifyClient) search(ctx context.Context, query, types string, limit int) ([]searchHit, error) {
	if !c.hasAPICreds() {
		return nil, fmt.Errorf("spotify search requires DROME_SPOTIFY_CLIENT_ID and DROME_SPOTIFY_CLIENT_SECRET")
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, fmt.Errorf("query is empty")
	}
	types = normalizeSearchTypes(types)
	if limit <= 0 {
		limit = 10
	}
	if limit > 10 {
		limit = 10
	}
	if len(query) > 250 {
		query = query[:250]
	}

	q := url.Values{}
	q.Set("q", query)
	q.Set("type", types)
	q.Set("limit", fmt.Sprintf("%d", limit))
	q.Set("market", c.market)

	var body struct {
		Tracks *struct {
			Items []struct {
				ID      string          `json:"id"`
				Name    string          `json:"name"`
				Artists []spotifyArtist `json:"artists"`
				Album   struct {
					Name   string         `json:"name"`
					Images []spotifyImage `json:"images"`
				} `json:"album"`
				ExternalURLs struct {
					Spotify string `json:"spotify"`
				} `json:"external_urls"`
			} `json:"items"`
		} `json:"tracks"`
		Albums *struct {
			Items []struct {
				ID      string          `json:"id"`
				Name    string          `json:"name"`
				Artists []spotifyArtist `json:"artists"`
				Images  []spotifyImage  `json:"images"`
				ExternalURLs struct {
					Spotify string `json:"spotify"`
				} `json:"external_urls"`
			} `json:"items"`
		} `json:"albums"`
		Playlists *struct {
			Items []struct {
				ID     string         `json:"id"`
				Name   string         `json:"name"`
				Images []spotifyImage `json:"images"`
				Owner  struct {
					DisplayName string `json:"display_name"`
				} `json:"owner"`
				Tracks struct {
					Total int `json:"total"`
				} `json:"tracks"`
				ExternalURLs struct {
					Spotify string `json:"spotify"`
				} `json:"external_urls"`
			} `json:"items"`
		} `json:"playlists"`
		Artists *struct {
			Items []struct {
				ID     string         `json:"id"`
				Name   string         `json:"name"`
				Images []spotifyImage `json:"images"`
				ExternalURLs struct {
					Spotify string `json:"spotify"`
				} `json:"external_urls"`
			} `json:"items"`
		} `json:"artists"`
	}
	if err := c.apiGET(ctx, "/search?"+q.Encode(), &body); err != nil {
		return nil, err
	}

	var hits []searchHit
	if body.Tracks != nil {
		for _, t := range body.Tracks.Items {
			if t.ID == "" {
				continue
			}
			u := t.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/track/" + t.ID
			}
			hits = append(hits, searchHit{
				Kind:       "track",
				SpotifyID:  t.ID,
				SpotifyURL: u,
				Title:      t.Name,
				Artist:     joinArtists(t.Artists),
				Album:      t.Album.Name,
				CoverURL:   bestImage(t.Album.Images),
			})
		}
	}
	if body.Albums != nil {
		for _, a := range body.Albums.Items {
			if a.ID == "" {
				continue
			}
			u := a.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/album/" + a.ID
			}
			hits = append(hits, searchHit{
				Kind:       "album",
				SpotifyID:  a.ID,
				SpotifyURL: u,
				Title:      a.Name,
				Artist:     joinArtists(a.Artists),
				Album:      a.Name,
				CoverURL:   bestImage(a.Images),
			})
		}
	}
	if body.Playlists != nil {
		for _, p := range body.Playlists.Items {
			if p.ID == "" {
				continue
			}
			u := p.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/playlist/" + p.ID
			}
			hits = append(hits, searchHit{
				Kind:       "playlist",
				SpotifyID:  p.ID,
				SpotifyURL: u,
				Title:      p.Name,
				Artist:     p.Owner.DisplayName,
				Album:      p.Name,
				CoverURL:   bestImage(p.Images),
				TrackCount: p.Tracks.Total,
			})
		}
	}
	if body.Artists != nil {
		for _, a := range body.Artists.Items {
			if a.ID == "" {
				continue
			}
			u := a.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/artist/" + a.ID
			}
			hits = append(hits, searchHit{
				Kind:       "artist",
				SpotifyID:  a.ID,
				SpotifyURL: u,
				Title:      a.Name,
				Artist:     a.Name,
				CoverURL:   bestImage(a.Images),
			})
		}
	}
	return hits, nil
}

func normalizeSearchTypes(types string) string {
	types = strings.TrimSpace(strings.ToLower(types))
	if types == "" {
		return "track,album"
	}
	allowed := map[string]bool{
		"album": true, "artist": true, "playlist": true,
		"track": true, "show": true, "episode": true, "audiobook": true,
	}
	parts := strings.Split(types, ",")
	out := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, p := range parts {
		p = strings.TrimSpace(p)
		// Common mistake: plural forms.
		switch p {
		case "tracks":
			p = "track"
		case "albums":
			p = "album"
		case "artists":
			p = "artist"
		case "playlists":
			p = "playlist"
		}
		if !allowed[p] || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	if len(out) == 0 {
		return "track,album"
	}
	return strings.Join(out, ",")
}

func firstSubmatch(re *regexp.Regexp, s string) string {
	m := re.FindStringSubmatch(s)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

func splitSpotifyDesc(desc string) []string {
	parts := strings.Split(desc, "·")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func cleanAlbumTitle(title string) string {
	title = strings.TrimSpace(title)
	// "Global Warming - Album by Pitbull | Spotify"
	if i := strings.Index(title, " - Album by "); i > 0 {
		title = title[:i]
	}
	if i := strings.Index(title, " | Spotify"); i > 0 {
		title = title[:i]
	}
	return strings.TrimSpace(title)
}

func htmlUnescape(s string) string {
	replacer := strings.NewReplacer(
		"&amp;", "&",
		"&quot;", `"`,
		"&#39;", "'",
		"&lt;", "<",
		"&gt;", ">",
	)
	return replacer.Replace(s)
}

