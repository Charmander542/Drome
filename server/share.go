package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
		SELECT token, song_id, title, artist, album, accent,
		       CASE WHEN cover IS NOT NULL AND length(cover) > 0 THEN 1 ELSE 0 END,
		       created_at
		FROM track_shares WHERE token = ?`, token)
	var sh trackShare
	var created string
	var hasCover int
	if err := row.Scan(&sh.Token, &sh.SongID, &sh.Title, &sh.Artist, &sh.Album, &sh.Accent,
		&hasCover, &created); err != nil {
		return nil, err
	}
	sh.CreatedAt, _ = time.Parse(time.RFC3339, created)
	if hasCover == 1 {
		sh.CoverType = "has"
	}
	return &sh, nil
}

func (s *wishlistStore) trackShareCoverBytes(token string) (data []byte, ctype string, err error) {
	row := s.db.QueryRow(`SELECT cover, cover_type FROM track_shares WHERE token = ?`, token)
	if err = row.Scan(&data, &ctype); err != nil {
		return nil, "", err
	}
	return data, ctype, nil
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
		contrastText(accent),
		sh.CoverType == "has",
	))
}

func (s *server) handleTrackShareCover(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	data, ctype, err := s.store.trackShareCoverBytes(token)
	if err != nil || len(data) == 0 {
		http.NotFound(w, r)
		return
	}
	if ctype == "" {
		ctype = "image/jpeg"
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+token+`-`+fmt.Sprintf("%d", len(data))+`"`)
	if match := r.Header.Get("If-None-Match"); match != "" && strings.Contains(match, token) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
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
