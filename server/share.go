package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type trackShare struct {
	Token     string
	SongID    string
	Title     string
	Artist    string
	Album     string
	Accent    string
	Cover     []byte
	CoverType string
	CreatedAt time.Time
}

func (s *wishlistStore) upsertTrackShare(in *trackShare) error {
	if in.Token == "" {
		buf := make([]byte, 12)
		if _, err := rand.Read(buf); err != nil {
			return err
		}
		in.Token = hex.EncodeToString(buf)
	}
	if in.CoverType == "" {
		in.CoverType = "image/jpeg"
	}
	in.CreatedAt = time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO track_shares (token, song_id, title, artist, album, accent, cover, cover_type, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (song_id) DO UPDATE SET
			title = excluded.title,
			artist = excluded.artist,
			album = excluded.album,
			accent = excluded.accent,
			cover = CASE WHEN excluded.cover IS NOT NULL AND length(excluded.cover) > 0 THEN excluded.cover ELSE track_shares.cover END,
			cover_type = CASE WHEN excluded.cover IS NOT NULL AND length(excluded.cover) > 0 THEN excluded.cover_type ELSE track_shares.cover_type END
		`,
		in.Token, in.SongID, in.Title, in.Artist, in.Album, in.Accent, in.Cover, in.CoverType,
		in.CreatedAt.Format(time.RFC3339))
	if err != nil {
		return err
	}
	row := s.db.QueryRow(`SELECT token FROM track_shares WHERE song_id = ?`, in.SongID)
	return row.Scan(&in.Token)
}

func (s *wishlistStore) trackShare(token string) (*trackShare, error) {
	row := s.db.QueryRow(`
		SELECT token, song_id, title, artist, album, accent, cover, cover_type, created_at
		FROM track_shares WHERE token = ?`, token)
	var sh trackShare
	var created string
	if err := row.Scan(&sh.Token, &sh.SongID, &sh.Title, &sh.Artist, &sh.Album, &sh.Accent,
		&sh.Cover, &sh.CoverType, &created); err != nil {
		return nil, err
	}
	sh.CreatedAt, _ = time.Parse(time.RFC3339, created)
	return &sh, nil
}

func publicBaseURL(r *http.Request) string {
	if v := strings.TrimRight(os.Getenv("DROME_PUBLIC_URL"), "/"); v != "" {
		return v
	}
	scheme := r.Header.Get("X-Forwarded-Proto")
	if scheme == "" {
		if r.TLS != nil {
			scheme = "https"
		} else {
			scheme = "http"
		}
	}
	return scheme + "://" + r.Host
}

func (s *server) handleCreateTrackShare(w http.ResponseWriter, r *http.Request) {
	var body struct {
		SongID      string `json:"songId"`
		Title       string `json:"title"`
		Artist      string `json:"artist"`
		Album       string `json:"album"`
		Accent      string `json:"accent"`
		CoverBase64 string `json:"coverJpegBase64"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	body.SongID = strings.TrimSpace(body.SongID)
	body.Title = strings.TrimSpace(body.Title)
	if body.SongID == "" || body.Title == "" {
		writeError(w, http.StatusBadRequest, "songId and title are required")
		return
	}
	sh := &trackShare{
		SongID: body.SongID,
		Title:  body.Title,
		Artist: strings.TrimSpace(body.Artist),
		Album:  strings.TrimSpace(body.Album),
		Accent: strings.TrimSpace(body.Accent),
	}
	if raw := strings.TrimSpace(body.CoverBase64); raw != "" {
		// Accept raw base64 or data-URL.
		if i := strings.Index(raw, ","); i >= 0 && strings.Contains(raw[:i], "base64") {
			raw = raw[i+1:]
		}
		data, err := decodeBase64(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "cover is not valid base64")
			return
		}
		if len(data) > 900_000 {
			writeError(w, http.StatusRequestEntityTooLarge, "cover is too large")
			return
		}
		sh.Cover = data
		sh.CoverType = "image/jpeg"
	}
	if err := s.store.upsertTrackShare(sh); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save share")
		return
	}
	base := publicBaseURL(r)
	shareURL := base + "/s/" + sh.Token + "?song=" + url.QueryEscape(sh.SongID)
	writeJSON(w, http.StatusCreated, map[string]string{
		"token":    sh.Token,
		"url":      shareURL,
		"coverUrl": base + "/s/" + sh.Token + "/cover",
		"songId":   sh.SongID,
	})
}

func (s *server) handleTrackSharePage(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	sh, err := s.store.trackShare(token)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if wantsJSON(r) {
		writeJSON(w, http.StatusOK, map[string]string{
			"songId": sh.SongID,
			"title":  sh.Title,
			"artist": sh.Artist,
			"album":  sh.Album,
			"token":  sh.Token,
		})
		return
	}
	base := publicBaseURL(r)
	deep := "drome://track/" + sh.SongID
	pageURL := base + "/s/" + sh.Token + "?song=" + url.QueryEscape(sh.SongID)
	coverURL := base + "/s/" + sh.Token + "/cover"
	headline := sh.Title
	if sh.Artist != "" {
		headline = sh.Title + " — " + sh.Artist
	}
	accent := sh.Accent
	if accent == "" {
		accent = "#3D7EFF"
	}
	desc := sh.Artist
	if sh.Album != "" {
		if desc != "" {
			desc += " · " + sh.Album
		} else {
			desc = sh.Album
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	_, _ = io.WriteString(w, sharePageHTML(
		html.EscapeString(headline),
		html.EscapeString(sh.Title),
		html.EscapeString(sh.Artist),
		html.EscapeString(sh.Album),
		html.EscapeString(desc),
		html.EscapeString(pageURL),
		html.EscapeString(coverURL),
		html.EscapeString(deep),
		html.EscapeString(accent),
		len(sh.Cover) > 0,
	))
}

func (s *server) handleTrackShareCover(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	sh, err := s.store.trackShare(token)
	if err != nil || len(sh.Cover) == 0 {
		http.NotFound(w, r)
		return
	}
	ctype := sh.CoverType
	if ctype == "" {
		ctype = "image/jpeg"
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(sh.Cover)
}

func sharePageHTML(headline, title, artist, album, desc, pageURL, coverURL, deep, accent string, hasCover bool) string {
	ogImage := ""
	hero := `<div class="art fallback">♪</div>`
	if hasCover {
		ogImage = `<meta property="og:image" content="` + coverURL + `">
<meta property="og:image:width" content="800">
<meta property="og:image:height" content="800">
<meta name="twitter:image" content="` + coverURL + `">`
		hero = `<img class="art" src="` + coverURL + `" alt="">`
	}
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>` + headline + `</title>
<meta name="description" content="` + desc + `">
<meta property="og:type" content="music.song">
<meta property="og:title" content="` + headline + `">
<meta property="og:description" content="` + desc + `">
<meta property="og:url" content="` + pageURL + `">
<meta property="og:site_name" content="Drome">
<meta property="al:ios:url" content="` + deep + `">
<meta property="al:ios:app_name" content="Drome">
<meta name="apple-itunes-app" content="app-argument=` + deep + `">
` + ogImage + `
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="` + headline + `">
<meta name="twitter:description" content="` + desc + `">
<meta name="theme-color" content="` + accent + `">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
    color: #fff;
    background: radial-gradient(1200px 800px at 50% -10%, ` + accent + `55, #07070a 55%);
    display: flex; align-items: center; justify-content: center;
    padding: 32px 20px;
  }
  .card {
    width: min(420px, 100%);
    text-align: center;
  }
  .art, .art.fallback {
    width: min(320px, 80vw); height: min(320px, 80vw);
    border-radius: 12px; object-fit: cover;
    box-shadow: 0 24px 60px rgba(0,0,0,.55);
    margin: 0 auto 22px;
  }
  .art.fallback {
    display: grid; place-items: center;
    background: #1c1c22; font-size: 64px; color: #8a8a96;
  }
  h1 { font-size: 1.45rem; margin: 0 0 6px; letter-spacing: -.02em; }
  .artist { margin: 0; color: rgba(255,255,255,.72); font-size: 1.02rem; }
  .album { margin: 8px 0 0; color: rgba(255,255,255,.45); font-size: .9rem; }
  .play {
    display: inline-flex; align-items: center; gap: 10px;
    margin-top: 28px; padding: 14px 28px; border-radius: 999px;
    background: ` + accent + `; color: #fff; text-decoration: none;
    font-weight: 650; font-size: 1.02rem;
  }
  .hint { margin-top: 18px; color: rgba(255,255,255,.38); font-size: .8rem; }
</style>
<script>
(function () {
  var ua = navigator.userAgent || "";
  if (/bot|crawler|spider|preview|facebookexternalhit|Twitterbot|Slackbot|Discordbot|WhatsApp|LinkedInBot|Applebot|Googlebot|Bingbot/i.test(ua)) return;
  window.location.replace("` + deep + `");
})();
</script>
</head>
<body>
  <main class="card">
    ` + hero + `
    <h1>` + title + `</h1>
    <p class="artist">` + artist + `</p>
    ` + albumLine(album) + `
    <a class="play" href="` + deep + `">Play in Drome</a>
    <p class="hint">Opens in Drome if you have the app.</p>
  </main>
</body>
</html>`
}

func wantsJSON(r *http.Request) bool {
	accept := strings.ToLower(r.Header.Get("Accept"))
	return strings.Contains(accept, "application/json") && !strings.Contains(accept, "text/html")
}

func (s *server) handleAppleAppSiteAssociation(w http.ResponseWriter, r *http.Request) {
	appID := os.Getenv("DROME_AASA_APP_ID")
	if appID == "" {
		appID = "LURJ69YS93.drome.app"
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = io.WriteString(w, `{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "`+appID+`",
        "appIDs": ["`+appID+`"],
        "paths": ["/s/*"],
        "components": [
          {"/": "/s/*/cover", "exclude": true},
          {"/": "/.well-known/*", "exclude": true},
          {"/": "/s/*"}
        ]
      }
    ]
  }
}`)
}

func albumLine(album string) string {
	if album == "" {
		return ""
	}
	return `<p class="album">` + album + `</p>`
}

func decodeBase64(s string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(s)
}
