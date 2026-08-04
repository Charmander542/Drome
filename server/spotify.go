package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// spotifyClient resolves pasted Spotify links into track/album metadata using
// the client-credentials flow. The client secret lives only on this server.
type spotifyClient struct {
	clientID     string
	clientSecret string
	http         *http.Client

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
}

func newSpotifyClient(id, secret string) *spotifyClient {
	return &spotifyClient{
		clientID:     id,
		clientSecret: secret,
		http:         &http.Client{Timeout: 15 * time.Second},
	}
}

var spotifyIDPattern = regexp.MustCompile(`^[0-9A-Za-z]{15,40}$`)

// parseSpotifyLink accepts open.spotify.com URLs (including /intl-xx/ and
// /embed/ variants) and spotify:track:... URIs, returning the resource kind
// ("track" or "album") and its Spotify ID.
func parseSpotifyLink(raw string) (kind, id string, err error) {
	raw = strings.TrimSpace(raw)

	if strings.HasPrefix(raw, "spotify:") {
		parts := strings.Split(raw, ":")
		if len(parts) == 3 && (parts[1] == "track" || parts[1] == "album") && spotifyIDPattern.MatchString(parts[2]) {
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
	if len(segments) >= 2 && (segments[0] == "track" || segments[0] == "album") && spotifyIDPattern.MatchString(segments[1]) {
		return segments[0], segments[1], nil
	}
	return "", "", fmt.Errorf("unsupported spotify link (only track and album links are supported)")
}

func (c *spotifyClient) token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accessToken != "" && time.Now().Before(c.tokenExpiry) {
		return c.accessToken, nil
	}
	if c.clientID == "" || c.clientSecret == "" {
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
		return fmt.Errorf("spotify API error: %s", resp.Status)
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

// resolve fills in an entry's metadata from the Spotify Web API.
func (c *spotifyClient) resolve(ctx context.Context, kind, id string) (*entry, error) {
	e := &entry{Kind: kind, SpotifyID: id, SpotifyURL: "https://open.spotify.com/" + kind + "/" + id}
	switch kind {
	case "track":
		var t struct {
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
			Album   struct {
				Name   string         `json:"name"`
				Images []spotifyImage `json:"images"`
			} `json:"album"`
		}
		if err := c.apiGET(ctx, "/tracks/"+id, &t); err != nil {
			return nil, err
		}
		e.Title = t.Name
		e.Artist = joinArtists(t.Artists)
		e.Album = t.Album.Name
		e.CoverURL = bestImage(t.Album.Images)
	case "album":
		var a struct {
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
			Images  []spotifyImage  `json:"images"`
		}
		if err := c.apiGET(ctx, "/albums/"+id, &a); err != nil {
			return nil, err
		}
		e.Title = a.Name
		e.Artist = joinArtists(a.Artists)
		e.Album = a.Name
		e.CoverURL = bestImage(a.Images)
	default:
		return nil, fmt.Errorf("unsupported kind %q", kind)
	}
	return e, nil
}
