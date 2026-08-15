package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
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

	mu             sync.Mutex
	accessToken    string
	tokenExpiry    time.Time
	webToken       string
	webTokenExpiry time.Time
}

func newSpotifyClient(id, secret, market string) *spotifyClient {
	if market == "" {
		market = "US"
	}
	return &spotifyClient{
		clientID:     id,
		clientSecret: secret,
		market:       market,
		http:         &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *spotifyClient) hasAPICreds() bool {
	return c.clientID != "" && c.clientSecret != ""
}

var spotifyIDPattern = regexp.MustCompile(`^[0-9A-Za-z]{15,40}$`)

// Matches open.spotify / play.spotify / spotify.link URLs and spotify: URIs
// buried in pasted clipboard text.
var spotifyLinkInText = regexp.MustCompile(`(?i)(?:https?://(?:open|play)\.spotify\.com/[^\s<>"']+|https?://spotify\.link/[^\s<>"']+|spotify:(?:track|album|playlist):[0-9A-Za-z]{15,40})`)

// parseSpotifyLink accepts open.spotify.com URLs (including /intl-xx/,
// /embed/, and legacy /user/.../playlist/ variants), spotify.link short
// URLs (caller should resolve redirects first), and spotify:track:... URIs.
// Also extracts a single link when paste text wraps it in other words.
func parseSpotifyLink(raw string) (kind, id string, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", fmt.Errorf("empty spotify link")
	}

	// If the paste is prose + a URL, pull the first Spotify link out.
	if extracted := extractSpotifyLinks(raw); len(extracted) == 1 && extracted[0] != raw {
		raw = extracted[0]
	} else if len(extracted) > 1 {
		// Multi-link paste is handled by the batch path; still try first token.
		raw = extracted[0]
	}

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
	switch host {
	case "open.spotify.com", "play.spotify.com":
		// continue
	case "spotify.link":
		return "", "", fmt.Errorf("spotify short link must be resolved before parsing")
	default:
		return "", "", fmt.Errorf("not a spotify link (host %q)", host)
	}

	segments := []string{}
	for _, s := range strings.Split(u.Path, "/") {
		if s == "" || s == "embed" || strings.HasPrefix(s, "intl-") {
			continue
		}
		// Drop query-like junk sometimes left in path segments.
		if i := strings.IndexAny(s, "?#"); i >= 0 {
			s = s[:i]
		}
		if s != "" {
			segments = append(segments, s)
		}
	}

	// Modern: /track/{id}, /album/{id}, /playlist/{id}
	if len(segments) >= 2 && (segments[0] == "track" || segments[0] == "album" || segments[0] == "playlist") && spotifyIDPattern.MatchString(segments[1]) {
		return segments[0], segments[1], nil
	}
	// Legacy: /user/{userId}/playlist/{id}
	if len(segments) >= 4 && segments[0] == "user" && segments[2] == "playlist" && spotifyIDPattern.MatchString(segments[3]) {
		return "playlist", segments[3], nil
	}
	return "", "", fmt.Errorf("unsupported spotify link (only track, album, and playlist links are supported)")
}

// extractSpotifyLinks returns unique Spotify URLs/URIs found in pasted text,
// preserving order. Falls back to the trimmed whole string when nothing matches
// so single clean URLs still work.
func extractSpotifyLinks(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	matches := spotifyLinkInText.FindAllString(raw, -1)
	if len(matches) == 0 {
		// Whole paste might already be a clean URL / URI.
		if strings.Contains(raw, "spotify") || strings.HasPrefix(raw, "spotify:") {
			return []string{strings.TrimRight(raw, ".,);]}>'\"")}
		}
		return nil
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		m = strings.TrimRight(m, ".,);]}>'\"")
		key := strings.ToLower(m)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, m)
	}
	return out
}

// resolveSpotifyShortLink follows redirects from spotify.link (and similar)
// until an open.spotify.com / play.spotify.com URL is reached.
func resolveSpotifyShortLink(ctx context.Context, httpClient *http.Client, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	host := strings.ToLower(u.Hostname())
	if host == "open.spotify.com" || host == "play.spotify.com" || strings.HasPrefix(raw, "spotify:") {
		return raw, nil
	}
	if host != "spotify.link" && !strings.HasSuffix(host, ".spotify.link") {
		return raw, nil
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 15 * time.Second}
	}
	client := *httpClient
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 8 {
			return fmt.Errorf("too many redirects")
		}
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, raw, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "DromeWishlist/1.0")
	resp, err := client.Do(req)
	if err != nil {
		// Some CDNs reject HEAD — retry with GET but discard body.
		req, err = http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("User-Agent", "DromeWishlist/1.0")
		resp, err = client.Do(req)
		if err != nil {
			return "", err
		}
	}
	defer resp.Body.Close()
	final := resp.Request.URL.String()
	if final == "" {
		return "", fmt.Errorf("short link did not resolve")
	}
	return final, nil
}

// normalizeSpotifyPaste resolves short links then parses kind/id.
func normalizeSpotifyPaste(ctx context.Context, httpClient *http.Client, raw string) (kind, id, canonical string, err error) {
	raw = strings.TrimSpace(raw)
	resolved, err := resolveSpotifyShortLink(ctx, httpClient, raw)
	if err != nil {
		return "", "", "", fmt.Errorf("could not resolve short link: %w", err)
	}
	kind, id, err = parseSpotifyLink(resolved)
	if err != nil {
		return "", "", "", err
	}
	return kind, id, resolved, nil
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

type spotifyAPIError struct {
	status int
	msg    string
}

func (e *spotifyAPIError) Error() string {
	if e.msg != "" {
		return e.msg
	}
	return fmt.Sprintf("spotify HTTP %d", e.status)
}

func spotifyAPIPath(path string) string {
	const root = "https://api.spotify.com/v1"
	path = strings.TrimSpace(path)
	if strings.HasPrefix(path, root) {
		path = strings.TrimPrefix(path, root)
	}
	if path == "" {
		return "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return path
}

func (c *spotifyClient) apiGETBearer(ctx context.Context, bearer, path string, out any) error {
	if bearer == "" {
		return fmt.Errorf("missing spotify token")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.spotify.com/v1"+spotifyAPIPath(path), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		msg := strings.TrimSpace(string(body))
		var payload struct {
			Error struct {
				Message string `json:"message"`
				Status  int    `json:"status"`
			} `json:"error"`
		}
		if json.Unmarshal(body, &payload) == nil && payload.Error.Message != "" {
			msg = payload.Error.Message
		}
		if msg == "" {
			msg = resp.Status
		}
		return &spotifyAPIError{status: resp.StatusCode, msg: msg}
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *spotifyClient) apiGET(ctx context.Context, path string, out any) error {
	tok, err := c.token(ctx)
	if err != nil {
		return err
	}
	return c.apiGETBearer(ctx, tok, path, out)
}

func spotifyUnavailable(err error) bool {
	var api *spotifyAPIError
	if errors.As(err, &api) {
		return api.status == http.StatusNotFound || api.status == http.StatusForbidden
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "not found") || strings.Contains(s, "not available")
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

func missingMeta(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return true
	}
	switch strings.ToLower(s) {
	case "unknown", "unknown album", "unknown artist", "untitled", "n/a", "none", "null":
		return true
	}
	return false
}

func copyMissingEntryFields(dst, src *entry) {
	if src == nil {
		return
	}
	if missingMeta(dst.Title) && !missingMeta(src.Title) {
		dst.Title = src.Title
	}
	if missingMeta(dst.Artist) && !missingMeta(src.Artist) {
		dst.Artist = src.Artist
	}
	if missingMeta(dst.AlbumArtist) && !missingMeta(src.AlbumArtist) {
		dst.AlbumArtist = src.AlbumArtist
	}
	if missingMeta(dst.Album) && !missingMeta(src.Album) {
		dst.Album = src.Album
	}
	if dst.CoverURL == "" && src.CoverURL != "" {
		dst.CoverURL = src.CoverURL
	}
	if dst.UPC == "" && src.UPC != "" {
		dst.UPC = src.UPC
	}
}

// completeEntry fills blank title/artist/album/cover from Spotify (API, public
// pages, then search) so retag never writes Unknown Album pockets.
func (c *spotifyClient) completeEntry(ctx context.Context, e *entry) {
	if c == nil || e == nil || e.Kind == "playlist" {
		return
	}
	kind := e.Kind
	if kind == "" {
		kind = "track"
	}
	if e.SpotifyID != "" {
		if resolved, err := c.resolve(ctx, kind, e.SpotifyID); err == nil {
			copyMissingEntryFields(e, resolved)
		} else {
			logf("completeEntry resolve %s/%s: %v", kind, e.SpotifyID, err)
		}
	}
	if !missingMeta(e.Title) && !missingMeta(e.Artist) && !missingMeta(e.Album) && e.CoverURL != "" {
		return
	}
	if !c.hasAPICreds() {
		return
	}
	q := strings.TrimSpace(e.Title)
	if missingMeta(q) {
		return
	}
	if !missingMeta(e.Artist) {
		q = fmt.Sprintf("track:%s artist:%s", e.Title, e.Artist)
	}
	hits, err := c.search(ctx, q, "track", 5)
	if err != nil || len(hits) == 0 {
		return
	}
	wantTitle := strings.ToLower(strings.TrimSpace(e.Title))
	wantArtist := strings.ToLower(strings.TrimSpace(e.Artist))
	var best *searchHit
	for i := range hits {
		h := &hits[i]
		if h.Kind != "track" {
			continue
		}
		if wantTitle != "" && !strings.EqualFold(strings.TrimSpace(h.Title), e.Title) &&
			!strings.Contains(strings.ToLower(h.Title), wantTitle) &&
			!strings.Contains(wantTitle, strings.ToLower(h.Title)) {
			continue
		}
		if wantArtist != "" && h.Artist != "" &&
			!strings.Contains(strings.ToLower(h.Artist), wantArtist) &&
			!strings.Contains(wantArtist, strings.ToLower(h.Artist)) {
			continue
		}
		best = h
		break
	}
	if best == nil {
		return
	}
	copyMissingEntryFields(e, &entry{
		Title:    best.Title,
		Artist:   best.Artist,
		Album:    best.Album,
		CoverURL: best.CoverURL,
	})
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
			Name        string          `json:"name"`
			Artists     []spotifyArtist `json:"artists"`
			Images      []spotifyImage  `json:"images"`
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
	if e.Kind == "playlist" {
		return "", ""
	}
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
	case "playlist":
		e.Title = strings.TrimSpace(strings.TrimSuffix(title, "| Spotify"))
		if i := strings.LastIndex(e.Title, " - playlist by "); i > 0 {
			e.Title = strings.TrimSpace(e.Title[:i])
		}
		e.Album = e.Title
		parts := splitSpotifyDesc(desc)
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
	SpotifyID   string
	SpotifyURL  string
	Title       string
	Artist      string
	AlbumArtist string
	Album       string
	CoverURL    string
}

func (c *spotifyClient) playlistTracks(ctx context.Context, playlistID string) (name string, tracks []playlistTrack, err error) {
	var best []playlistTrack
	consider := func(src, n string, t []playlistTrack, e error) {
		if n != "" && name == "" {
			name = n
		}
		if e != nil {
			logf("playlist %s via %s: %v (%d tracks)", playlistID, src, e, len(t))
		} else {
			logf("playlist %s via %s: %d tracks", playlistID, src, len(t))
		}
		if len(t) > len(best) {
			best = t
			if n != "" {
				name = n
			}
		}
	}

	// Same GraphQL fetchPlaylist path as SpotiFLAC's GUI (1000 tracks per page).
	n, t, e := c.playlistTracksSpotiFLAC(ctx, playlistID)
	consider("spotiflac-gui", n, t, e)
	if e == nil && len(t) > 0 {
		if name == "" {
			name = "Spotify playlist"
		}
		return name, best, nil
	}

	if c.hasAPICreds() {
		n, t, e := c.playlistTracksAPI(ctx, playlistID)
		consider("client-credentials", n, t, e)
	}

	n, t, e = c.playlistTracksWebToken(ctx, playlistID)
	consider("web-token", n, t, e)

	if len(best) < 101 {
		n, t, e := c.playlistTracksPublic(ctx, playlistID)
		consider("public-scrape", n, t, e)
	}

	if name == "" {
		name = "Spotify playlist"
	}
	if len(best) == 0 {
		return name, nil, errPlaylistDirectDownload
	}
	return name, best, nil
}

var errPlaylistDirectDownload = fmt.Errorf("playlist is not enumerable; download the playlist URL directly")

func spotiflacListBin() string {
	if v := strings.TrimSpace(os.Getenv("DROME_SPOTIFLAC_LIST_BIN")); v != "" {
		return v
	}
	return "drome-list-playlist"
}

func (c *spotifyClient) playlistTracksSpotiFLAC(ctx context.Context, playlistID string) (string, []playlistTrack, error) {
	bin := spotiflacListBin()
	if _, err := exec.LookPath(bin); err != nil {
		return "", nil, err
	}
	playlistURL := "https://open.spotify.com/playlist/" + playlistID
	cmd := exec.CommandContext(ctx, bin, playlistURL)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return "", nil, fmt.Errorf("%s: %s", err, msg)
		}
		return "", nil, err
	}
	var parsed struct {
		Name   string `json:"name"`
		Tracks []struct {
			ID          string `json:"id"`
			URL         string `json:"url"`
			Title       string `json:"title"`
			Artist      string `json:"artist"`
			AlbumArtist string `json:"albumArtist"`
			Album       string `json:"album"`
			Cover       string `json:"cover"`
		} `json:"tracks"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return "", nil, err
	}
	tracks := make([]playlistTrack, 0, len(parsed.Tracks))
	for _, t := range parsed.Tracks {
		id := strings.TrimSpace(t.ID)
		if id == "" {
			continue
		}
		u := strings.TrimSpace(t.URL)
		if u == "" {
			u = "https://open.spotify.com/track/" + id
		}
		tracks = append(tracks, playlistTrack{
			SpotifyID:   id,
			SpotifyURL:  u,
			Title:       t.Title,
			Artist:      t.Artist,
			AlbumArtist: t.AlbumArtist,
			Album:       t.Album,
			CoverURL:    t.Cover,
		})
	}
	return parsed.Name, tracks, nil
}

func (c *spotifyClient) playlistTracksAPI(ctx context.Context, playlistID string) (name string, tracks []playlistTrack, err error) {
	if !c.hasAPICreds() {
		return "", nil, fmt.Errorf("spotify playlist import requires API credentials")
	}
	var meta struct {
		Name   string `json:"name"`
		Tracks struct {
			Total int `json:"total"`
		} `json:"tracks"`
	}
	if err := c.apiGET(ctx, "/playlists/"+playlistID+"?fields=name,tracks.total", &meta); err != nil {
		if err2 := c.apiGET(ctx, "/playlists/"+playlistID, &meta); err2 != nil {
			logf("playlist metadata %s: %v", playlistID, err)
		}
	}
	name = meta.Name

	tracks, err = c.fetchPlaylistTrackPages(ctx, playlistID, meta.Tracks.Total, func(offset int) (playlistTracksPage, error) {
		var page playlistTracksPage
		path := fmt.Sprintf("/playlists/%s/tracks?limit=100&offset=%d&additional_types=track&market=%s",
			playlistID, offset, url.QueryEscape(c.market))
		if err := c.apiGET(ctx, path, &page); err != nil {
			path = fmt.Sprintf("/playlists/%s/tracks?limit=100&offset=%d&market=%s",
				playlistID, offset, url.QueryEscape(c.market))
			if err2 := c.apiGET(ctx, path, &page); err2 != nil {
				path = fmt.Sprintf("/playlists/%s/tracks?limit=100&offset=%d", playlistID, offset)
				if err3 := c.apiGET(ctx, path, &page); err3 != nil {
					return playlistTracksPage{}, err
				}
			}
		}
		return page, nil
	})
	if err != nil {
		return name, nil, err
	}
	if name == "" {
		name = "Spotify playlist"
	}
	if meta.Tracks.Total > len(tracks) {
		logf("playlist API %s: got %d of %d tracks", playlistID, len(tracks), meta.Tracks.Total)
	}
	return name, tracks, nil
}

type playlistTracksPage struct {
	Total int     `json:"total"`
	Next  *string `json:"next"`
	Items []struct {
		Track *struct {
			ID      string          `json:"id"`
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
			Album   struct {
				Name    string          `json:"name"`
				Artists []spotifyArtist `json:"artists"`
				Images  []spotifyImage  `json:"images"`
			} `json:"album"`
			ExternalURLs struct {
				Spotify string `json:"spotify"`
			} `json:"external_urls"`
		} `json:"track"`
	} `json:"items"`
}

func playlistTracksFromPage(page playlistTracksPage) []playlistTrack {
	var tracks []playlistTrack
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
			SpotifyID:   t.ID,
			SpotifyURL:  u,
			Title:       t.Name,
			Artist:      joinArtists(t.Artists),
			AlbumArtist: firstArtistName(t.Album.Artists),
			Album:       t.Album.Name,
			CoverURL:    bestImage(t.Album.Images),
		})
	}
	return tracks
}

func (c *spotifyClient) playlistTracksWebToken(ctx context.Context, playlistID string) (name string, tracks []playlistTrack, err error) {
	tok, err := c.anonymousWebToken(ctx, playlistID)
	if err != nil {
		return "", nil, err
	}
	var meta struct {
		Name   string `json:"name"`
		Tracks struct {
			Total int `json:"total"`
		} `json:"tracks"`
	}
	_ = c.apiGETBearer(ctx, tok, "/playlists/"+playlistID+"?fields=name,tracks.total", &meta)
	name = meta.Name
	tracks, err = c.fetchPlaylistTrackPages(ctx, playlistID, meta.Tracks.Total, func(offset int) (playlistTracksPage, error) {
		var page playlistTracksPage
		path := fmt.Sprintf("/playlists/%s/tracks?limit=100&offset=%d&additional_types=track", playlistID, offset)
		if err := c.apiGETBearer(ctx, tok, path, &page); err != nil {
			path = fmt.Sprintf("/playlists/%s/tracks?limit=100&offset=%d", playlistID, offset)
			if err2 := c.apiGETBearer(ctx, tok, path, &page); err2 != nil {
				return playlistTracksPage{}, err
			}
		}
		return page, nil
	})
	if err != nil {
		return name, nil, err
	}
	if name == "" {
		name = "Spotify playlist"
	}
	return name, tracks, nil
}

func (c *spotifyClient) anonymousWebToken(ctx context.Context, playlistID string) (string, error) {
	c.mu.Lock()
	if c.webToken != "" && time.Now().Before(c.webTokenExpiry) {
		tok := c.webToken
		c.mu.Unlock()
		return tok, nil
	}
	c.mu.Unlock()

	tryHTML := func(pageURL string) string {
		page, err := c.fetchPublicHTML(ctx, pageURL)
		if err != nil {
			return ""
		}
		return extractSpotifyAccessToken(page)
	}

	tok := ""
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://open.spotify.com/get_access_token?reason=transport&productType=web_player", nil)
	if err == nil {
		req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
		req.Header.Set("Accept", "application/json")
		if resp, err := c.http.Do(req); err == nil {
			var body struct {
				AccessToken string `json:"accessToken"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&body)
			resp.Body.Close()
			tok = body.AccessToken
		}
	}
	if tok == "" {
		tok = tryHTML("https://open.spotify.com/playlist/" + playlistID)
	}
	if tok == "" {
		tok = tryHTML("https://open.spotify.com/embed/playlist/" + playlistID)
	}
	if tok == "" {
		tok = tryHTML("https://open.spotify.com/")
	}
	if tok == "" {
		return "", fmt.Errorf("could not get a Spotify web access token")
	}
	c.mu.Lock()
	c.webToken = tok
	c.webTokenExpiry = time.Now().Add(30 * time.Minute)
	c.mu.Unlock()
	return tok, nil
}

var (
	accessTokenJSONRe = regexp.MustCompile(`"accessToken"\s*:\s*"([^"]+)"`)
	sessionScriptRe   = regexp.MustCompile(`(?s)<script[^>]*id="session"[^>]*>(.*?)</script>`)
)

func extractSpotifyAccessToken(html string) string {
	if m := sessionScriptRe.FindStringSubmatch(html); len(m) > 1 {
		var s struct {
			AccessToken string `json:"accessToken"`
		}
		if json.Unmarshal([]byte(m[1]), &s) == nil && s.AccessToken != "" {
			return s.AccessToken
		}
	}
	if m := accessTokenJSONRe.FindStringSubmatch(html); len(m) > 1 {
		return m[1]
	}
	return ""
}

func (c *spotifyClient) fetchPlaylistTrackPages(ctx context.Context, playlistID string, knownTotal int, getPage func(offset int) (playlistTracksPage, error)) ([]playlistTrack, error) {
	var tracks []playlistTrack
	seen := map[string]struct{}{}
	total := knownTotal
	for offset := 0; offset <= 10000; offset += 100 {
		page, err := getPage(offset)
		if err != nil {
			if offset == 0 {
				return nil, err
			}
			logf("playlist %s page offset %d: %v (keeping %d tracks)", playlistID, offset, err, len(tracks))
			break
		}
		if page.Total > total {
			total = page.Total
		}
		newOnPage := 0
		for _, t := range playlistTracksFromPage(page) {
			if t.SpotifyID == "" {
				continue
			}
			if _, ok := seen[t.SpotifyID]; ok {
				continue
			}
			seen[t.SpotifyID] = struct{}{}
			tracks = append(tracks, t)
			newOnPage++
		}
		logf("playlist %s offset %d: +%d (have %d / total %d)", playlistID, offset, newOnPage, len(tracks), total)
		if total > 0 && len(tracks) >= total {
			break
		}
		if len(page.Items) == 0 {
			break
		}
		if newOnPage == 0 && offset > 0 {
			break
		}
		if len(page.Items) < 100 && (total <= 0 || len(tracks) >= total || total-len(tracks) < 1) {
			break
		}
		if len(page.Items) < 100 && newOnPage == 0 {
			break
		}
	}
	return tracks, nil
}

var (
	spotifyTrackURIRe  = regexp.MustCompile(`spotify:track:([0-9A-Za-z]{22})`)
	spotifyTrackPathRe = regexp.MustCompile(`(?i)(?:open\.spotify\.com/(?:embed/)?(?:intl-[a-z]{2}/)?track/|/track/)([0-9A-Za-z]{22})`)
)

func unescapeSpotifyHTML(s string) string {
	replacer := strings.NewReplacer(
		`\u003a`, ":",
		`\u003A`, ":",
		`\u002f`, "/",
		`\u002F`, "/",
		`\/`, "/",
		`\\u003a`, ":",
	)
	return replacer.Replace(s)
}

func extractSpotifyTrackIDs(html string) []string {
	html = unescapeSpotifyHTML(html)
	seen := make(map[string]struct{})
	var ids []string
	add := func(id string) {
		if len(id) != 22 || !spotifyIDPattern.MatchString(id) {
			return
		}
		if _, ok := seen[id]; ok {
			return
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	for _, m := range spotifyTrackURIRe.FindAllStringSubmatch(html, -1) {
		add(m[1])
	}
	for _, m := range spotifyTrackPathRe.FindAllStringSubmatch(html, -1) {
		add(m[1])
	}
	return ids
}

func (c *spotifyClient) fetchPublicHTML(ctx context.Context, pageURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pageURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
	req.Header.Set("Accept-Language", "en")
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("Referer", "https://open.spotify.com/")
	req.Header.Set("Cache-Control", "no-cache")
	client := c.http
	if client == nil || client.Timeout < 25*time.Second {
		client = &http.Client{Timeout: 25 * time.Second}
		if c.http != nil {
			client.Transport = c.http.Transport
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("spotify page %s: %s", pageURL, resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", err
	}
	return string(body), nil
}

func playlistNameFromHTML(html string) string {
	if name := playlistNameFromNextData(html); name != "" {
		return name
	}
	title := htmlUnescape(firstSubmatch(ogTitleRe, html))
	title = strings.TrimSpace(strings.TrimSuffix(title, "| Spotify"))
	if i := strings.LastIndex(strings.ToLower(title), " - playlist by "); i > 0 {
		title = strings.TrimSpace(title[:i])
	}
	return title
}

func playlistNameFromNextData(html string) string {
	m := nextDataRe.FindStringSubmatch(html)
	if len(m) < 2 {
		return ""
	}
	var v any
	if err := json.Unmarshal([]byte(m[1]), &v); err != nil {
		return ""
	}
	var name string
	var walk func(any)
	walk = func(node any) {
		if name != "" {
			return
		}
		obj, ok := node.(map[string]any)
		if !ok {
			if arr, ok := node.([]any); ok {
				for _, child := range arr {
					walk(child)
				}
			}
			return
		}
		if tl, ok := obj["trackList"].([]any); ok && len(tl) > 0 {
			if n, _ := obj["name"].(string); n != "" {
				name = n
				return
			}
			if n, _ := obj["title"].(string); n != "" {
				name = n
				return
			}
		}
		for _, child := range obj {
			walk(child)
		}
	}
	walk(v)
	return strings.TrimSpace(name)
}

func (c *spotifyClient) playlistTracksPublic(ctx context.Context, playlistID string) (name string, tracks []playlistTrack, err error) {
	seen := map[string]struct{}{}
	var lastErr error
	for _, offset := range []int{0, 100, 200, 300, 400, 500} {
		pages := []string{
			"https://open.spotify.com/embed/playlist/" + playlistID,
			"https://open.spotify.com/playlist/" + playlistID,
		}
		if offset > 0 {
			off := fmt.Sprintf("?offset=%d", offset)
			pages = []string{
				"https://open.spotify.com/embed/playlist/" + playlistID + off,
				"https://open.spotify.com/playlist/" + playlistID + off,
			}
		}
		gotNew := 0
		for _, u := range pages {
			page, fetchErr := c.fetchPublicHTML(ctx, u)
			if fetchErr != nil {
				lastErr = fetchErr
				continue
			}
			if name == "" {
				name = playlistNameFromHTML(page)
			}
			batch := extractPlaylistTracksFromHTML(page)
			for _, t := range batch {
				if t.SpotifyID == "" {
					continue
				}
				if _, ok := seen[t.SpotifyID]; ok {
					continue
				}
				seen[t.SpotifyID] = struct{}{}
				tracks = append(tracks, t)
				gotNew++
			}
			if len(batch) > 0 {
				break
			}
		}
		if offset == 0 && len(tracks) == 0 {
			break
		}
		if offset > 0 && gotNew == 0 {
			break
		}
		if offset == 0 && len(tracks) < 100 {
			break
		}
	}
	if len(tracks) == 0 {
		if lastErr != nil {
			return name, nil, lastErr
		}
		return name, nil, fmt.Errorf("public playlist page has no track ids")
	}
	tracks = c.hydratePlaylistTracks(ctx, tracks)
	return name, tracks, nil
}

func extractPlaylistTracksFromHTML(html string) []playlistTrack {
	html = unescapeSpotifyHTML(html)
	var tracks []playlistTrack
	collectTracksFromJSONBlobs(html, &tracks)
	if len(tracks) == 0 {
		ids := extractSpotifyTrackIDs(html)
		tracks = make([]playlistTrack, 0, len(ids))
		for _, id := range ids {
			tracks = append(tracks, playlistTrack{
				SpotifyID:  id,
				SpotifyURL: "https://open.spotify.com/track/" + id,
			})
		}
	}
	return tracks
}

var nextDataRe = regexp.MustCompile(`(?s)<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>`)
var jsonScriptRe = regexp.MustCompile(`(?s)<script[^>]*type="application/json"[^>]*>(.*?)</script>`)

func collectTracksFromJSONBlobs(html string, out *[]playlistTrack) {
	seen := make(map[string]struct{})
	addJSON := func(raw string) {
		raw = strings.TrimSpace(htmlUnescape(raw))
		if raw == "" {
			return
		}
		var v any
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			return
		}
		walkJSONForPlaylistTracks(v, out, seen)
	}
	if m := nextDataRe.FindStringSubmatch(html); len(m) > 1 {
		addJSON(m[1])
	}
	if len(*out) > 0 {
		return
	}
	for _, m := range jsonScriptRe.FindAllStringSubmatch(html, -1) {
		if len(m) > 1 {
			addJSON(m[1])
		}
		if len(*out) > 0 {
			return
		}
	}
}

func walkJSONForPlaylistTracks(v any, out *[]playlistTrack, seen map[string]struct{}) {
	switch t := v.(type) {
	case map[string]any:
		if tl, ok := t["trackList"].([]any); ok {
			for _, item := range tl {
				if m, ok := item.(map[string]any); ok {
					if tr, ok := playlistTrackFromEmbedMap(m); ok {
						if _, dup := seen[tr.SpotifyID]; dup {
							continue
						}
						seen[tr.SpotifyID] = struct{}{}
						*out = append(*out, tr)
					}
				}
			}
		}
		if tr, ok := playlistTrackFromEmbedMap(t); ok && t["trackList"] == nil {
			if _, dup := seen[tr.SpotifyID]; !dup && tr.Title != "" {
				seen[tr.SpotifyID] = struct{}{}
				*out = append(*out, tr)
			}
		}
		for _, child := range t {
			walkJSONForPlaylistTracks(child, out, seen)
		}
	case []any:
		for _, child := range t {
			walkJSONForPlaylistTracks(child, out, seen)
		}
	}
}

func playlistTrackFromEmbedMap(m map[string]any) (playlistTrack, bool) {
	id := ""
	if uri, _ := m["uri"].(string); strings.HasPrefix(uri, "spotify:track:") {
		id = strings.TrimPrefix(uri, "spotify:track:")
	}
	if id == "" {
		if s, _ := m["id"].(string); spotifyIDPattern.MatchString(s) {
			if _, hasType := m["type"]; !hasType || m["type"] == "track" {
				id = s
			}
		}
	}
	if id == "" || !spotifyIDPattern.MatchString(id) {
		return playlistTrack{}, false
	}
	title, _ := m["title"].(string)
	if title == "" {
		title, _ = m["name"].(string)
	}
	artist, _ := m["subtitle"].(string)
	if artist == "" {
		if artists, ok := m["artists"].([]any); ok {
			var names []spotifyArtist
			for _, a := range artists {
				if am, ok := a.(map[string]any); ok {
					if n, _ := am["name"].(string); n != "" {
						names = append(names, spotifyArtist{Name: n})
					}
				}
			}
			artist = joinArtists(names)
		}
	}
	cover := embedCoverURL(m)
	album := ""
	if am, ok := m["album"].(map[string]any); ok {
		album, _ = am["name"].(string)
		if cover == "" {
			cover = embedCoverURL(am)
		}
	}
	return playlistTrack{
		SpotifyID:  id,
		SpotifyURL: "https://open.spotify.com/track/" + id,
		Title:      strings.TrimSpace(title),
		Artist:     strings.TrimSpace(artist),
		Album:      strings.TrimSpace(album),
		CoverURL:   cover,
	}, true
}

func embedCoverURL(m map[string]any) string {
	if s, _ := m["imageUrl"].(string); s != "" {
		return s
	}
	if cover, ok := m["coverArt"].(map[string]any); ok {
		if sources, ok := cover["sources"].([]any); ok {
			return bestEmbedImage(sources)
		}
	}
	if vis, ok := m["visualIdentity"].(map[string]any); ok {
		if images, ok := vis["image"].([]any); ok {
			return bestEmbedImage(images)
		}
	}
	if images, ok := m["images"].([]any); ok {
		return bestEmbedImage(images)
	}
	return ""
}

func bestEmbedImage(images []any) string {
	best, bestW := "", -1
	for _, raw := range images {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		u, _ := m["url"].(string)
		if u == "" {
			continue
		}
		w := 0
		for _, key := range []string{"width", "maxWidth", "height", "maxHeight"} {
			switch n := m[key].(type) {
			case float64:
				if int(n) > w {
					w = int(n)
				}
			}
		}
		if w > bestW {
			best, bestW = u, w
		}
	}
	return best
}

func (c *spotifyClient) hydratePlaylistTracks(ctx context.Context, tracks []playlistTrack) []playlistTrack {
	if len(tracks) == 0 {
		return tracks
	}
	need := make([]string, 0, len(tracks))
	idx := make(map[string]int, len(tracks))
	for i, t := range tracks {
		idx[t.SpotifyID] = i
		if t.Title == "" || t.CoverURL == "" || t.Album == "" {
			need = append(need, t.SpotifyID)
		}
	}
	if len(need) > 0 && c.hasAPICreds() {
		hydrated, err := c.tracksByIDs(ctx, need)
		if err != nil {
			logf("hydrate scraped playlist tracks: %v", err)
		} else {
			for _, h := range hydrated {
				i, ok := idx[h.SpotifyID]
				if !ok {
					continue
				}
				tracks[i] = mergePlaylistTrack(tracks[i], h)
			}
		}
	}
	var missing []int
	for i, t := range tracks {
		if t.Title == "" || t.CoverURL == "" {
			missing = append(missing, i)
		}
	}
	if len(missing) == 0 {
		return tracks
	}
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for _, i := range missing {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			e := &entry{
				Kind:       "track",
				SpotifyID:  tracks[i].SpotifyID,
				SpotifyURL: tracks[i].SpotifyURL,
			}
			if err := c.resolvePublic(ctx, e); err != nil {
				return
			}
			h := playlistTrack{
				SpotifyID:  e.SpotifyID,
				SpotifyURL: e.SpotifyURL,
				Title:      e.Title,
				Artist:     e.Artist,
				Album:      e.Album,
				CoverURL:   e.CoverURL,
			}
			tracks[i] = mergePlaylistTrack(tracks[i], h)
		}()
	}
	wg.Wait()
	return tracks
}

func mergePlaylistTrack(base, extra playlistTrack) playlistTrack {
	if base.SpotifyID == "" {
		base.SpotifyID = extra.SpotifyID
	}
	if base.SpotifyURL == "" {
		base.SpotifyURL = extra.SpotifyURL
	}
	if base.Title == "" {
		base.Title = extra.Title
	}
	if base.Artist == "" {
		base.Artist = extra.Artist
	}
	if base.AlbumArtist == "" {
		base.AlbumArtist = extra.AlbumArtist
	}
	if base.Album == "" {
		base.Album = extra.Album
	}
	if base.CoverURL == "" {
		base.CoverURL = extra.CoverURL
	}
	if base.SpotifyURL == "" && base.SpotifyID != "" {
		base.SpotifyURL = "https://open.spotify.com/track/" + base.SpotifyID
	}
	return base
}

func (c *spotifyClient) tracksByIDs(ctx context.Context, ids []string) ([]playlistTrack, error) {
	if !c.hasAPICreds() {
		return nil, fmt.Errorf("spotify tracks lookup requires API credentials")
	}
	var tracks []playlistTrack
	for i := 0; i < len(ids); i += 50 {
		end := i + 50
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[i:end]
		path := "/tracks?ids=" + url.QueryEscape(strings.Join(chunk, ","))
		if c.market != "" {
			path += "&market=" + url.QueryEscape(c.market)
		}
		var body struct {
			Tracks []*struct {
				ID      string          `json:"id"`
				Name    string          `json:"name"`
				Artists []spotifyArtist `json:"artists"`
				Album   struct {
					Name    string          `json:"name"`
					Artists []spotifyArtist `json:"artists"`
					Images  []spotifyImage  `json:"images"`
				} `json:"album"`
				ExternalURLs struct {
					Spotify string `json:"spotify"`
				} `json:"external_urls"`
			} `json:"tracks"`
		}
		if err := c.apiGET(ctx, path, &body); err != nil {
			return nil, err
		}
		for _, t := range body.Tracks {
			if t == nil || t.ID == "" {
				continue
			}
			u := t.ExternalURLs.Spotify
			if u == "" {
				u = "https://open.spotify.com/track/" + t.ID
			}
			tracks = append(tracks, playlistTrack{
				SpotifyID:   t.ID,
				SpotifyURL:  u,
				Title:       t.Name,
				Artist:      joinArtists(t.Artists),
				AlbumArtist: firstArtistName(t.Album.Artists),
				Album:       t.Album.Name,
				CoverURL:    bestImage(t.Album.Images),
			})
		}
	}
	return tracks, nil
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
				ID           string          `json:"id"`
				Name         string          `json:"name"`
				Artists      []spotifyArtist `json:"artists"`
				Images       []spotifyImage  `json:"images"`
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
				ID           string         `json:"id"`
				Name         string         `json:"name"`
				Images       []spotifyImage `json:"images"`
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
