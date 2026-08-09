package main

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type entry struct {
	ID         int64     `json:"id"`
	Owner      string    `json:"owner"`
	Kind       string    `json:"kind"` // "track" or "album"
	SpotifyID  string    `json:"spotifyId"`
	SpotifyURL string    `json:"spotifyUrl"`
	Title      string    `json:"title"`
	Artist     string    `json:"artist"`
	Album      string    `json:"album"`
	CoverURL   string    `json:"coverUrl"`
	Acquired   bool      `json:"acquired"`
	Status     string    `json:"status,omitempty"` // queued|downloading|done|failed|skipped
	StatusMsg  string    `json:"statusMessage,omitempty"`
	Attempts   int       `json:"attempts,omitempty"`
	NextRetry  time.Time `json:"nextRetryAt,omitempty"`
	CreatedAt  time.Time `json:"createdAt"`
	// SourcePlaylistID/Name tag tracks imported from a Spotify playlist.
	SourcePlaylistID   string `json:"sourcePlaylistId,omitempty"`
	SourcePlaylistName string `json:"sourcePlaylistName,omitempty"`
	// SharedWith lists usernames this entry is explicitly shared with
	// (populated for entries the requester owns).
	SharedWith []string `json:"sharedWith,omitempty"`
	// SharedBy is set when the entry belongs to someone else and is visible
	// to the requester through a share.
	SharedBy string `json:"sharedBy,omitempty"`
}

type wishlistStore struct {
	db *sql.DB
}

func openStore(path string) (*wishlistStore, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// modernc.org/sqlite is safest with a single writer connection.
	db.SetMaxOpenConns(1)

	schema := `
CREATE TABLE IF NOT EXISTS entries (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	owner       TEXT NOT NULL,
	kind        TEXT NOT NULL,
	spotify_id  TEXT NOT NULL,
	spotify_url TEXT NOT NULL,
	title       TEXT NOT NULL,
	artist      TEXT NOT NULL DEFAULT '',
	album       TEXT NOT NULL DEFAULT '',
	cover_url   TEXT NOT NULL DEFAULT '',
	acquired    INTEGER NOT NULL DEFAULT 0,
	status      TEXT NOT NULL DEFAULT '',
	status_msg  TEXT NOT NULL DEFAULT '',
	created_at  TEXT NOT NULL,
	UNIQUE (owner, kind, spotify_id)
);
CREATE TABLE IF NOT EXISTS entry_shares (
	entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
	username TEXT NOT NULL,
	PRIMARY KEY (entry_id, username)
);
CREATE TABLE IF NOT EXISTS list_shares (
	owner    TEXT NOT NULL,
	username TEXT NOT NULL,
	PRIMARY KEY (owner, username)
);
CREATE INDEX IF NOT EXISTS entries_status_idx ON entries(status, id);`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	// Migrate DBs created before status / source-playlist / retry columns existed.
	for _, stmt := range []string{
		`ALTER TABLE entries ADD COLUMN status TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE entries ADD COLUMN status_msg TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE entries ADD COLUMN source_playlist_id TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE entries ADD COLUMN source_playlist_name TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE entries ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE entries ADD COLUMN next_retry_at TEXT NOT NULL DEFAULT ''`,
	} {
		if _, err := db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			db.Close()
			return nil, err
		}
	}
	return &wishlistStore{db: db}, nil
}

func (s *wishlistStore) Close() error { return s.db.Close() }

// findActiveByTitleArtist returns an existing non-acquired wishlist row with the
// same owner/kind/title/artist (case-insensitive). Used to stop duplicate
// Spotify album/track adds when the Spotify ID differs (deluxe/region).
func (s *wishlistStore) findActiveByTitleArtist(owner, kind, title, artist string) (*entry, error) {
	row := s.db.QueryRow(`
		SELECT id, owner, kind, spotify_id, spotify_url, title, artist, album, cover_url,
		       acquired, status, status_msg, attempts, next_retry_at,
		       source_playlist_id, source_playlist_name, created_at
		FROM entries
		WHERE owner = ? AND kind = ?
		  AND lower(trim(title)) = lower(trim(?))
		  AND lower(trim(artist)) = lower(trim(?))
		  AND acquired = 0
		  AND status NOT IN ('done')
		ORDER BY id DESC
		LIMIT 1`, owner, kind, title, artist)
	var e entry
	var acquired int
	var createdAt, nextRetry string
	if err := row.Scan(&e.ID, &e.Owner, &e.Kind, &e.SpotifyID, &e.SpotifyURL,
		&e.Title, &e.Artist, &e.Album, &e.CoverURL, &acquired, &e.Status, &e.StatusMsg,
		&e.Attempts, &nextRetry, &e.SourcePlaylistID, &e.SourcePlaylistName, &createdAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	e.Acquired = acquired != 0
	e.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	if nextRetry != "" {
		e.NextRetry, _ = time.Parse(time.RFC3339, nextRetry)
	}
	return &e, nil
}

func (s *wishlistStore) insert(e *entry) error {
	if e.Status == "" {
		e.Status = statusQueued
	}
	res, err := s.db.Exec(`
		INSERT INTO entries (owner, kind, spotify_id, spotify_url, title, artist, album, cover_url, status, status_msg, source_playlist_id, source_playlist_name, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (owner, kind, spotify_id) DO UPDATE SET
			title = excluded.title, artist = excluded.artist,
			album = excluded.album, cover_url = excluded.cover_url,
			source_playlist_id = CASE
				WHEN excluded.source_playlist_id != '' THEN excluded.source_playlist_id
				ELSE entries.source_playlist_id
			END,
			source_playlist_name = CASE
				WHEN excluded.source_playlist_name != '' THEN excluded.source_playlist_name
				ELSE entries.source_playlist_name
			END,
			status = CASE
				WHEN entries.acquired = 1 OR entries.status IN ('done', 'downloading') THEN entries.status
				ELSE excluded.status
			END,
			status_msg = CASE
				WHEN entries.acquired = 1 OR entries.status IN ('done', 'downloading') THEN entries.status_msg
				ELSE excluded.status_msg
			END`,
		e.Owner, e.Kind, e.SpotifyID, e.SpotifyURL, e.Title, e.Artist, e.Album, e.CoverURL,
		e.Status, e.StatusMsg, e.SourcePlaylistID, e.SourcePlaylistName, e.CreatedAt.UTC().Format(time.RFC3339))
	if err != nil {
		return err
	}
	if id, err := res.LastInsertId(); err == nil && id > 0 {
		e.ID = id
	}
	// On upsert LastInsertId can be unreliable; fetch the definitive row id.
	var acquired int
	err = s.db.QueryRow(
		`SELECT id, acquired, status, status_msg, source_playlist_id, source_playlist_name FROM entries WHERE owner = ? AND kind = ? AND spotify_id = ?`,
		e.Owner, e.Kind, e.SpotifyID).Scan(&e.ID, &acquired, &e.Status, &e.StatusMsg, &e.SourcePlaylistID, &e.SourcePlaylistName)
	if err != nil {
		return err
	}
	e.Acquired = acquired != 0
	return nil
}

// listFor returns everything visible to user: their own entries, entries
// individually shared with them, and all entries of owners who shared their
// whole list with them.
func (s *wishlistStore) listFor(user string) ([]entry, error) {
	rows, err := s.db.Query(`
		SELECT DISTINCT e.id, e.owner, e.kind, e.spotify_id, e.spotify_url,
		       e.title, e.artist, e.album, e.cover_url, e.acquired, e.status, e.status_msg,
		       e.attempts, e.next_retry_at,
		       e.source_playlist_id, e.source_playlist_name, e.created_at
		FROM entries e
		LEFT JOIN entry_shares es ON es.entry_id = e.id
		LEFT JOIN list_shares ls ON ls.owner = e.owner
		WHERE (e.owner = ? OR es.username = ? OR ls.username = ?)
		  AND e.acquired = 0
		  AND e.status NOT IN ('done')
		ORDER BY e.created_at DESC, e.id DESC`,
		user, user, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []entry
	for rows.Next() {
		var e entry
		var acquired int
		var createdAt, nextRetry string
		if err := rows.Scan(&e.ID, &e.Owner, &e.Kind, &e.SpotifyID, &e.SpotifyURL,
			&e.Title, &e.Artist, &e.Album, &e.CoverURL, &acquired, &e.Status, &e.StatusMsg,
			&e.Attempts, &nextRetry, &e.SourcePlaylistID, &e.SourcePlaylistName, &createdAt); err != nil {
			return nil, err
		}
		e.Acquired = acquired != 0
		e.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		if nextRetry != "" {
			e.NextRetry, _ = time.Parse(time.RFC3339, nextRetry)
		}
		if e.Owner != user {
			e.SharedBy = e.Owner
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Attach explicit share lists to the requester's own entries.
	shareRows, err := s.db.Query(`
		SELECT es.entry_id, es.username FROM entry_shares es
		JOIN entries e ON e.id = es.entry_id WHERE e.owner = ?`, user)
	if err != nil {
		return nil, err
	}
	defer shareRows.Close()
	sharesByEntry := map[int64][]string{}
	for shareRows.Next() {
		var id int64
		var name string
		if err := shareRows.Scan(&id, &name); err != nil {
			return nil, err
		}
		sharesByEntry[id] = append(sharesByEntry[id], name)
	}
	for i := range entries {
		if entries[i].Owner == user {
			entries[i].SharedWith = sharesByEntry[entries[i].ID]
		}
	}
	return entries, nil
}

func (s *wishlistStore) get(id int64) (*entry, error) {
	var e entry
	var acquired int
	var createdAt, nextRetry string
	err := s.db.QueryRow(`
		SELECT id, owner, kind, spotify_id, spotify_url, title, artist, album, cover_url, acquired, status, status_msg,
		       attempts, next_retry_at, source_playlist_id, source_playlist_name, created_at
		FROM entries WHERE id = ?`, id).
		Scan(&e.ID, &e.Owner, &e.Kind, &e.SpotifyID, &e.SpotifyURL,
			&e.Title, &e.Artist, &e.Album, &e.CoverURL, &acquired, &e.Status, &e.StatusMsg,
			&e.Attempts, &nextRetry, &e.SourcePlaylistID, &e.SourcePlaylistName, &createdAt)
	if err != nil {
		return nil, err
	}
	e.Acquired = acquired != 0
	e.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	if nextRetry != "" {
		e.NextRetry, _ = time.Parse(time.RFC3339, nextRetry)
	}
	return &e, nil
}

func (s *wishlistStore) delete(id int64) error {
	_, err := s.db.Exec(`DELETE FROM entries WHERE id = ?`, id)
	return err
}

func (s *wishlistStore) deleteBySourcePlaylist(owner, playlistID string) (int64, error) {
	res, err := s.db.Exec(
		`DELETE FROM entries WHERE owner = ? AND source_playlist_id = ? AND acquired = 0`,
		owner, playlistID)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *wishlistStore) setAcquired(id int64, acquired bool) error {
	if acquired {
		// “Got it” / downloaded — drop from the active wishlist.
		return s.delete(id)
	}
	_, err := s.db.Exec(`UPDATE entries SET acquired = 0 WHERE id = ?`, id)
	return err
}

// purgeCompleted removes historically acquired / done rows so they no longer
// clutter the wishlist UI after the “leave on download” behavior shipped.
func (s *wishlistStore) purgeCompleted() (int64, error) {
	res, err := s.db.Exec(`DELETE FROM entries WHERE acquired = 1 OR status = 'done'`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *wishlistStore) setStatus(id int64, status, msg string) error {
	_, err := s.db.Exec(`UPDATE entries SET status = ?, status_msg = ? WHERE id = ?`, status, msg, id)
	return err
}

// resetForRetry clears failure state and attempt budget for a manual re-queue.
func (s *wishlistStore) resetForRetry(id int64) error {
	_, err := s.db.Exec(`
		UPDATE entries SET status = ?, status_msg = '', attempts = 0, next_retry_at = ''
		WHERE id = ?`, statusQueued, id)
	return err
}

// markFailed increments attempts and either schedules a retry or leaves the
// entry failed permanently once maxAttempts is reached.
func (s *wishlistStore) markFailed(id int64, msg string, attempts, maxAttempts int, retryAfter time.Duration) error {
	if attempts < maxAttempts {
		next := time.Now().UTC().Add(retryAfter).Format(time.RFC3339)
		_, err := s.db.Exec(`
			UPDATE entries SET status = ?, status_msg = ?, attempts = ?, next_retry_at = ?
			WHERE id = ?`, statusFailed, msg, attempts, next, id)
		return err
	}
	_, err := s.db.Exec(`
		UPDATE entries SET status = ?, status_msg = ?, attempts = ?, next_retry_at = ''
		WHERE id = ?`, statusFailed, msg, attempts, id)
	return err
}

// requeueDueRetries moves failed jobs whose next_retry_at has passed back to queued.
func (s *wishlistStore) requeueDueRetries(maxAttempts int) (int64, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := s.db.Exec(`
		UPDATE entries SET status = ?, status_msg = '', next_retry_at = ''
		WHERE status = ? AND attempts < ? AND next_retry_at != '' AND next_retry_at <= ?`,
		statusQueued, statusFailed, maxAttempts, now)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// nextQueued returns the oldest queued entry, or nil if the queue is empty.
func (s *wishlistStore) nextQueued() (*entry, error) {
	var id int64
	err := s.db.QueryRow(`SELECT id FROM entries WHERE status = ? ORDER BY id ASC LIMIT 1`, statusQueued).Scan(&id)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return s.get(id)
}

// requeueDownloading resets interrupted downloads back to queued after a restart.
func (s *wishlistStore) requeueDownloading() (int64, error) {
	res, err := s.db.Exec(`UPDATE entries SET status = ?, status_msg = '' WHERE status = ?`, statusQueued, statusDownloading)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *wishlistStore) shareEntry(id int64, username string) error {
	_, err := s.db.Exec(`INSERT OR IGNORE INTO entry_shares (entry_id, username) VALUES (?, ?)`, id, username)
	return err
}

func (s *wishlistStore) unshareEntry(id int64, username string) error {
	_, err := s.db.Exec(`DELETE FROM entry_shares WHERE entry_id = ? AND username = ?`, id, username)
	return err
}

func (s *wishlistStore) shareList(owner, username string) error {
	_, err := s.db.Exec(`INSERT OR IGNORE INTO list_shares (owner, username) VALUES (?, ?)`, owner, username)
	return err
}

func (s *wishlistStore) unshareList(owner, username string) error {
	_, err := s.db.Exec(`DELETE FROM list_shares WHERE owner = ? AND username = ?`, owner, username)
	return err
}
