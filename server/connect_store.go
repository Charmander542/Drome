package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
)

// Connect is Spotify-style multi-device presence + remote control.
// Platform-agnostic JSON so iOS, tvOS, web, and desktop share one contract.

const (
	connectDeviceTTL   = 45 * time.Second
	connectCommandTTL  = 2 * time.Minute
	connectMaxCommands = 200
)

type connectDevice struct {
	ID           string  `json:"id"`
	Owner        string  `json:"owner"`
	Name         string  `json:"name"`
	Platform     string  `json:"platform"` // ios | tvos | web | desktop | …
	Model        string  `json:"model,omitempty"`
	IsActive     bool    `json:"isActive"`
	IsPlaying    bool    `json:"isPlaying"`
	SongID       string  `json:"songId,omitempty"`
	SongTitle    string  `json:"songTitle,omitempty"`
	SongArtist   string  `json:"songArtist,omitempty"`
	Elapsed      float64 `json:"elapsed,omitempty"`
	Duration     float64 `json:"duration,omitempty"`
	LastSeenAt   float64 `json:"lastSeenAt"`
	Capabilities []string `json:"capabilities,omitempty"`
}

type connectSession struct {
	Owner          string          `json:"owner"`
	ActiveDeviceID string          `json:"activeDeviceId"`
	IsPlaying      bool            `json:"isPlaying"`
	UpdatedAt      float64         `json:"updatedAt"`
	Snapshot       json.RawMessage `json:"snapshot"` // PlaybackSessionSnapshot JSON
}

type connectCommand struct {
	ID             string  `json:"id"`
	Owner          string  `json:"owner"`
	Type           string  `json:"type"` // transfer | play | pause | next | previous | seek | takeControl
	FromDeviceID   string  `json:"fromDeviceId"`
	TargetDeviceID string  `json:"targetDeviceId"`
	SeekTo         float64 `json:"seekTo,omitempty"`
	CreatedAt      float64 `json:"createdAt"`
}

type connectHub struct {
	mu   sync.Mutex
	subs map[string]map[chan connectEvent]struct{} // owner -> subscribers
}

type connectEvent struct {
	Kind string          `json:"kind"` // devices | session | command
	Data json.RawMessage `json:"data"`
}

func newConnectHub() *connectHub {
	return &connectHub{subs: map[string]map[chan connectEvent]struct{}{}}
}

func (h *connectHub) subscribe(owner string) chan connectEvent {
	ch := make(chan connectEvent, 16)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[owner] == nil {
		h.subs[owner] = map[chan connectEvent]struct{}{}
	}
	h.subs[owner][ch] = struct{}{}
	return ch
}

func (h *connectHub) unsubscribe(owner string, ch chan connectEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if m := h.subs[owner]; m != nil {
		delete(m, ch)
		if len(m) == 0 {
			delete(h.subs, owner)
		}
	}
	close(ch)
}

func (h *connectHub) publish(owner string, ev connectEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[owner] {
		select {
		case ch <- ev:
		default:
			// Drop if subscriber is slow — poll still works.
		}
	}
}

func (s *wishlistStore) migrateConnect() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS connect_devices (
	id            TEXT NOT NULL,
	owner         TEXT NOT NULL,
	name          TEXT NOT NULL,
	platform      TEXT NOT NULL DEFAULT '',
	model         TEXT NOT NULL DEFAULT '',
	is_playing    INTEGER NOT NULL DEFAULT 0,
	song_id       TEXT NOT NULL DEFAULT '',
	song_title    TEXT NOT NULL DEFAULT '',
	song_artist   TEXT NOT NULL DEFAULT '',
	elapsed       REAL NOT NULL DEFAULT 0,
	duration      REAL NOT NULL DEFAULT 0,
	capabilities  TEXT NOT NULL DEFAULT '[]',
	last_seen_at  REAL NOT NULL,
	PRIMARY KEY (owner, id)
);
CREATE TABLE IF NOT EXISTS connect_sessions (
	owner            TEXT PRIMARY KEY,
	active_device_id TEXT NOT NULL,
	is_playing       INTEGER NOT NULL DEFAULT 0,
	updated_at       REAL NOT NULL,
	snapshot_json    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS connect_commands (
	id               TEXT PRIMARY KEY,
	owner            TEXT NOT NULL,
	type             TEXT NOT NULL,
	from_device_id   TEXT NOT NULL,
	target_device_id TEXT NOT NULL,
	seek_to          REAL NOT NULL DEFAULT 0,
	created_at       REAL NOT NULL,
	consumed         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS connect_commands_owner_idx ON connect_commands(owner, created_at);
`)
	return err
}

func (s *wishlistStore) upsertConnectDevice(d connectDevice) error {
	caps, _ := json.Marshal(d.Capabilities)
	if caps == nil {
		caps = []byte("[]")
	}
	playing := 0
	if d.IsPlaying {
		playing = 1
	}
	_, err := s.db.Exec(`
INSERT INTO connect_devices(
	id, owner, name, platform, model, is_playing, song_id, song_title, song_artist,
	elapsed, duration, capabilities, last_seen_at)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(owner, id) DO UPDATE SET
	name=excluded.name,
	platform=excluded.platform,
	model=excluded.model,
	is_playing=excluded.is_playing,
	song_id=excluded.song_id,
	song_title=excluded.song_title,
	song_artist=excluded.song_artist,
	elapsed=excluded.elapsed,
	duration=excluded.duration,
	capabilities=excluded.capabilities,
	last_seen_at=excluded.last_seen_at
`, d.ID, d.Owner, d.Name, d.Platform, d.Model, playing, d.SongID, d.SongTitle, d.SongArtist,
		d.Elapsed, d.Duration, string(caps), d.LastSeenAt)
	return err
}

func (s *wishlistStore) deleteConnectDevice(owner, id string) error {
	_, err := s.db.Exec(`DELETE FROM connect_devices WHERE owner=? AND id=?`, owner, id)
	return err
}

func (s *wishlistStore) listConnectDevices(owner string) ([]connectDevice, error) {
	cutoff := float64(time.Now().Add(-connectDeviceTTL).UnixMilli()) / 1000.0
	rows, err := s.db.Query(`
SELECT id, owner, name, platform, model, is_playing, song_id, song_title, song_artist,
       elapsed, duration, capabilities, last_seen_at
FROM connect_devices
WHERE owner=? AND last_seen_at >= ?
ORDER BY name COLLATE NOCASE`, owner, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var activeID string
	_ = s.db.QueryRow(`SELECT active_device_id FROM connect_sessions WHERE owner=?`, owner).Scan(&activeID)

	out := []connectDevice{}
	for rows.Next() {
		var d connectDevice
		var playing int
		var caps string
		if err := rows.Scan(&d.ID, &d.Owner, &d.Name, &d.Platform, &d.Model, &playing,
			&d.SongID, &d.SongTitle, &d.SongArtist, &d.Elapsed, &d.Duration, &caps, &d.LastSeenAt); err != nil {
			return nil, err
		}
		d.IsPlaying = playing == 1
		d.IsActive = d.ID == activeID
		_ = json.Unmarshal([]byte(caps), &d.Capabilities)
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *wishlistStore) putConnectSession(sess connectSession) error {
	playing := 0
	if sess.IsPlaying {
		playing = 1
	}
	snap := string(sess.Snapshot)
	if snap == "" {
		snap = "null"
	}
	_, err := s.db.Exec(`
INSERT INTO connect_sessions(owner, active_device_id, is_playing, updated_at, snapshot_json)
VALUES(?,?,?,?,?)
ON CONFLICT(owner) DO UPDATE SET
	active_device_id=excluded.active_device_id,
	is_playing=excluded.is_playing,
	updated_at=excluded.updated_at,
	snapshot_json=excluded.snapshot_json
`, sess.Owner, sess.ActiveDeviceID, playing, sess.UpdatedAt, snap)
	return err
}

func (s *wishlistStore) getConnectSession(owner string) (*connectSession, error) {
	var sess connectSession
	var playing int
	var snap string
	err := s.db.QueryRow(`
SELECT owner, active_device_id, is_playing, updated_at, snapshot_json
FROM connect_sessions WHERE owner=?`, owner).Scan(
		&sess.Owner, &sess.ActiveDeviceID, &playing, &sess.UpdatedAt, &snap)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sess.IsPlaying = playing == 1
	sess.Snapshot = json.RawMessage(snap)
	return &sess, nil
}

func (s *wishlistStore) enqueueConnectCommand(cmd connectCommand) error {
	_, _ = s.db.Exec(`DELETE FROM connect_commands WHERE created_at < ?`,
		float64(time.Now().Add(-connectCommandTTL).UnixMilli())/1000.0)
	_, err := s.db.Exec(`
INSERT INTO connect_commands(id, owner, type, from_device_id, target_device_id, seek_to, created_at, consumed)
VALUES(?,?,?,?,?,?,?,0)`,
		cmd.ID, cmd.Owner, cmd.Type, cmd.FromDeviceID, cmd.TargetDeviceID, cmd.SeekTo, cmd.CreatedAt)
	return err
}

func (s *wishlistStore) listConnectCommands(owner, deviceID string, after float64) ([]connectCommand, error) {
	rows, err := s.db.Query(`
SELECT id, owner, type, from_device_id, target_device_id, seek_to, created_at
FROM connect_commands
WHERE owner=? AND target_device_id=? AND created_at > ? AND consumed=0
ORDER BY created_at ASC
LIMIT ?`, owner, deviceID, after, connectMaxCommands)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []connectCommand{}
	for rows.Next() {
		var c connectCommand
		if err := rows.Scan(&c.ID, &c.Owner, &c.Type, &c.FromDeviceID, &c.TargetDeviceID, &c.SeekTo, &c.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *wishlistStore) consumeConnectCommands(owner string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	placeholders := make([]string, len(ids))
	args := make([]any, 0, len(ids)+1)
	args = append(args, owner)
	for i, id := range ids {
		placeholders[i] = "?"
		args = append(args, id)
	}
	_, err := s.db.Exec(`UPDATE connect_commands SET consumed=1 WHERE owner=? AND id IN (`+
		strings.Join(placeholders, ",")+`)`, args...)
	return err
}

func newConnectCommandID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func nowUnix() float64 {
	return float64(time.Now().UnixMilli()) / 1000.0
}

func encodeConnectEvent(kind string, v any) (connectEvent, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return connectEvent{}, err
	}
	return connectEvent{Kind: kind, Data: data}, nil
}

func (s *wishlistStore) setActiveDevice(owner, deviceID string) error {
	sess, err := s.getConnectSession(owner)
	if err != nil {
		return err
	}
	if sess == nil {
		return s.putConnectSession(connectSession{
			Owner:          owner,
			ActiveDeviceID: deviceID,
			IsPlaying:      false,
			UpdatedAt:      nowUnix(),
			Snapshot:       json.RawMessage("null"),
		})
	}
	sess.ActiveDeviceID = deviceID
	sess.UpdatedAt = nowUnix()
	return s.putConnectSession(*sess)
}

func validatePlatform(p string) error {
	switch p {
	case "ios", "tvos", "web", "desktop", "android", "other":
		return nil
	default:
		if p == "" {
			return fmt.Errorf("platform is required")
		}
		// Allow future platforms without a server deploy.
		if len(p) > 32 {
			return fmt.Errorf("platform too long")
		}
		return nil
	}
}
