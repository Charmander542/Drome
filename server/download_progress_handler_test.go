package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func withRequestUser(r *http.Request, user string) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), userContextKey, user))
}

func TestHandleDownloadProgressJSONAndHTML(t *testing.T) {
	dir := t.TempDir()
	store, err := openStore(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	e := &entry{
		Owner: "charlie", Kind: "track", SpotifyID: "t1", SpotifyURL: "https://open.spotify.com/track/t1",
		Title: "Demo", Artist: "Artist", Status: statusQueued, CreatedAt: time.Now().UTC(),
	}
	if err := store.insert(e); err != nil {
		t.Fatal(err)
	}

	worker := newDownloadWorker(downloadConfig{Enabled: true, MaxAttempts: 5}, store, nil, nil, "")
	srv := &server{store: store, downloads: worker}

	// Bypass requireAuth by calling the handler directly with a forged request user.
	req := httptest.NewRequest(http.MethodGet, "/wishlist/downloads", nil)
	req = withRequestUser(req, "charlie")
	rr := httptest.NewRecorder()
	srv.handleDownloadProgress(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var rep downloadStatusReport
	if err := json.Unmarshal(rr.Body.Bytes(), &rep); err != nil {
		t.Fatal(err)
	}
	if !rep.Enabled || rep.Queue.Queued != 1 {
		t.Fatalf("report=%+v", rep)
	}

	reqHTML := httptest.NewRequest(http.MethodGet, "/wishlist/downloads?format=html", nil)
	reqHTML = withRequestUser(reqHTML, "charlie")
	rrHTML := httptest.NewRecorder()
	srv.handleDownloadProgress(rrHTML, reqHTML)
	if rrHTML.Code != http.StatusOK {
		t.Fatalf("html status=%d", rrHTML.Code)
	}
	ctype := rrHTML.Header().Get("Content-Type")
	if !strings.Contains(ctype, "text/html") {
		t.Fatalf("content-type=%q", ctype)
	}
	body := rrHTML.Body.String()
	if !strings.Contains(body, "Download progress") || !strings.Contains(body, "Demo") {
		t.Fatalf("unexpected html: %s", body[:min(len(body), 400)])
	}
}
