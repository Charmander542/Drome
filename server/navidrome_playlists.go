package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

type subsonicCreds struct {
	user, token, salt string
}

// flexString accepts JSON strings or numbers (Navidrome ids are sometimes numeric).
type flexString string

func (s *flexString) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || string(b) == "null" {
		*s = ""
		return nil
	}
	if b[0] == '"' {
		var v string
		if err := json.Unmarshal(b, &v); err != nil {
			return err
		}
		*s = flexString(v)
		return nil
	}
	*s = flexString(b)
	return nil
}

func (s flexString) String() string { return string(s) }

type playlistList []ndPlaylist

func (p *playlistList) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || string(b) == "null" {
		*p = nil
		return nil
	}
	if b[0] == '{' {
		var one ndPlaylist
		if err := json.Unmarshal(b, &one); err != nil {
			return err
		}
		*p = []ndPlaylist{one}
		return nil
	}
	var many []ndPlaylist
	if err := json.Unmarshal(b, &many); err != nil {
		return err
	}
	*p = many
	return nil
}

func (v *navidromeVerifier) subsonicQuery(creds subsonicCreds) url.Values {
	q := url.Values{}
	q.Set("u", creds.user)
	q.Set("t", creds.token)
	q.Set("s", creds.salt)
	q.Set("v", "1.16.1")
	q.Set("c", "drome-server")
	q.Set("f", "json")
	return q
}

func (v *navidromeVerifier) subsonicGET(ctx context.Context, endpoint string, creds subsonicCreds, extra url.Values) (json.RawMessage, error) {
	q := v.subsonicQuery(creds)
	for k, vs := range extra {
		for _, val := range vs {
			q.Add(k, val)
		}
	}
	if !strings.HasSuffix(endpoint, ".view") && !strings.Contains(endpoint, ".") {
		endpoint += ".view"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.baseURL+"/rest/"+endpoint+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var envelope struct {
		SubsonicResponse json.RawMessage `json:"subsonic-response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, err
	}
	var status struct {
		Status string `json:"status"`
		Error  struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(envelope.SubsonicResponse, &status); err != nil {
		return nil, err
	}
	if status.Status != "ok" {
		msg := status.Error.Message
		if msg == "" {
			msg = "navidrome error"
		}
		return nil, fmt.Errorf("%s", msg)
	}
	return envelope.SubsonicResponse, nil
}

type ndPlaylist struct {
	ID    flexString `json:"id"`
	Name  string     `json:"name"`
	Owner string     `json:"owner"`
}

func (v *navidromeVerifier) listPlaylists(ctx context.Context, creds subsonicCreds) ([]ndPlaylist, error) {
	raw, err := v.subsonicGET(ctx, "getPlaylists", creds, nil)
	if err != nil {
		return nil, err
	}
	var body struct {
		Playlists struct {
			Playlist playlistList `json:"playlist"`
		} `json:"playlists"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return nil, err
	}
	return body.Playlists.Playlist, nil
}

func (v *navidromeVerifier) playlistSongIDs(ctx context.Context, creds subsonicCreds, playlistID string) (map[string]struct{}, error) {
	extra := url.Values{}
	extra.Set("id", playlistID)
	raw, err := v.subsonicGET(ctx, "getPlaylist", creds, extra)
	if err != nil {
		return nil, err
	}
	var body struct {
		Playlist struct {
			Entry []struct {
				ID flexString `json:"id"`
			} `json:"entry"`
		} `json:"playlist"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return nil, err
	}
	out := map[string]struct{}{}
	for _, e := range body.Playlist.Entry {
		if id := e.ID.String(); id != "" {
			out[id] = struct{}{}
		}
	}
	return out, nil
}

func (v *navidromeVerifier) createPlaylist(ctx context.Context, creds subsonicCreds, name string) (string, error) {
	extra := url.Values{}
	extra.Set("name", name)
	raw, err := v.subsonicGET(ctx, "createPlaylist", creds, extra)
	if err != nil {
		return "", err
	}
	var body struct {
		Playlist ndPlaylist `json:"playlist"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return "", err
	}
	if body.Playlist.ID.String() == "" {
		// Some servers omit the id on create; look it up by name.
		if lists, lerr := v.listPlaylists(ctx, creds); lerr == nil {
			want := strings.ToLower(strings.TrimSpace(name))
			for _, p := range lists {
				if strings.ToLower(strings.TrimSpace(p.Name)) == want && p.ID.String() != "" {
					return p.ID.String(), nil
				}
			}
		}
		return "", fmt.Errorf("createPlaylist returned no id")
	}
	return body.Playlist.ID.String(), nil
}

func (v *navidromeVerifier) addSongsToPlaylist(ctx context.Context, creds subsonicCreds, playlistID string, songIDs []string) error {
	if len(songIDs) == 0 {
		return nil
	}
	const batch = 40
	for i := 0; i < len(songIDs); i += batch {
		end := i + batch
		if end > len(songIDs) {
			end = len(songIDs)
		}
		extra := url.Values{}
		extra.Set("playlistId", playlistID)
		for _, id := range songIDs[i:end] {
			extra.Add("songIdToAdd", id)
		}
		if _, err := v.subsonicGET(ctx, "updatePlaylist", creds, extra); err != nil {
			return err
		}
	}
	return nil
}

func (v *navidromeVerifier) setPlaylistPublic(ctx context.Context, creds subsonicCreds, playlistID string) {
	extra := url.Values{}
	extra.Set("playlistId", playlistID)
	extra.Set("public", "true")
	_, _ = v.subsonicGET(ctx, "updatePlaylist", creds, extra)
}

func (v *navidromeVerifier) findPlaylistID(lists []ndPlaylist, name, owner string) string {
	want := strings.ToLower(strings.TrimSpace(name))
	for _, p := range lists {
		if strings.ToLower(strings.TrimSpace(p.Name)) != want {
			continue
		}
		if owner != "" && p.Owner != "" && !strings.EqualFold(p.Owner, owner) {
			continue
		}
		if id := p.ID.String(); id != "" {
			return id
		}
	}
	return ""
}

func (v *navidromeVerifier) ensureNamedPlaylist(ctx context.Context, creds subsonicCreds, name, owner string, makePublic bool) (id string, created bool, err error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Spotify playlist"
	}
	lists, err := v.listPlaylists(ctx, creds)
	if err != nil {
		return "", false, err
	}
	if existing := v.findPlaylistID(lists, name, owner); existing != "" {
		return existing, false, nil
	}
	id, err = v.createPlaylist(ctx, creds, name)
	if err != nil {
		return "", false, err
	}
	if makePublic {
		v.setPlaylistPublic(ctx, creds, id)
	}
	return id, true, nil
}

func (v *navidromeVerifier) addTrackToNamedPlaylist(ctx context.Context, creds subsonicCreds, playlistID, title, artist string) error {
	songID := v.findSongID(ctx, creds.user, creds.token, creds.salt, title, artist)
	if songID == "" {
		return fmt.Errorf("song not in library yet")
	}
	have, err := v.playlistSongIDs(ctx, creds, playlistID)
	if err != nil {
		return err
	}
	if _, ok := have[songID]; ok {
		return nil
	}
	return v.addSongsToPlaylist(ctx, creds, playlistID, []string{songID})
}
