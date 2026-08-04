package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// navidromeVerifier authenticates requests by replaying the caller's Subsonic
// token credentials (u, t, s) against the Navidrome `ping` endpoint. No
// passwords are ever stored here; Navidrome remains the single source of
// truth for identity. Successful verifications are cached briefly so bursts
// of app traffic do not hammer Navidrome.
type navidromeVerifier struct {
	baseURL string
	ttl     time.Duration
	client  *http.Client

	mu    sync.Mutex
	cache map[string]time.Time // sha256(u|t|s) -> expiry
}

func newNavidromeVerifier(baseURL string, ttl time.Duration) *navidromeVerifier {
	return &navidromeVerifier{
		baseURL: baseURL,
		ttl:     ttl,
		client:  &http.Client{Timeout: 10 * time.Second},
		cache:   map[string]time.Time{},
	}
}

type subsonicPingResponse struct {
	SubsonicResponse struct {
		Status string `json:"status"`
		Error  struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	} `json:"subsonic-response"`
}

func (v *navidromeVerifier) verify(ctx context.Context, user, token, salt string) error {
	if user == "" || token == "" || salt == "" {
		return fmt.Errorf("missing credentials")
	}

	sum := sha256.Sum256([]byte(user + "|" + token + "|" + salt))
	key := hex.EncodeToString(sum[:])

	v.mu.Lock()
	if exp, ok := v.cache[key]; ok && time.Now().Before(exp) {
		v.mu.Unlock()
		return nil
	}
	v.mu.Unlock()

	q := url.Values{}
	q.Set("u", user)
	q.Set("t", token)
	q.Set("s", salt)
	q.Set("v", "1.16.1")
	q.Set("c", "drome-server")
	q.Set("f", "json")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.baseURL+"/rest/ping.view?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return fmt.Errorf("navidrome unreachable: %w", err)
	}
	defer resp.Body.Close()

	var ping subsonicPingResponse
	if err := json.NewDecoder(resp.Body).Decode(&ping); err != nil {
		return fmt.Errorf("bad navidrome response: %w", err)
	}
	if ping.SubsonicResponse.Status != "ok" {
		return fmt.Errorf("navidrome rejected credentials: %s", ping.SubsonicResponse.Error.Message)
	}

	v.mu.Lock()
	v.cache[key] = time.Now().Add(v.ttl)
	v.mu.Unlock()
	return nil
}

type contextKey string

const userContextKey contextKey = "drome.user"

// requireAuth wraps a handler, verifying Subsonic credentials passed either
// as query parameters (u, t, s — same convention as the Subsonic API) or as
// X-Drome-User / X-Drome-Token / X-Drome-Salt headers.
func (s *server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user := r.URL.Query().Get("u")
		token := r.URL.Query().Get("t")
		salt := r.URL.Query().Get("s")
		if user == "" {
			user = r.Header.Get("X-Drome-User")
			token = r.Header.Get("X-Drome-Token")
			salt = r.Header.Get("X-Drome-Salt")
		}

		if err := s.navidrome.verify(r.Context(), user, token, salt); err != nil {
			writeError(w, http.StatusUnauthorized, fmt.Sprintf("authentication failed: %v", err))
			return
		}

		next(w, r.WithContext(context.WithValue(r.Context(), userContextKey, user)))
	}
}

func requestUser(r *http.Request) string {
	u, _ := r.Context().Value(userContextKey).(string)
	return u
}
