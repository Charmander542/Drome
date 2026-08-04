package main

import (
	"database/sql"
	"fmt"
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
	CreatedAt  time.Time `json:"createdAt"`
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
);`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &wishlistStore{db: db}, nil
}

func (s *wishlistStore) Close() error { return s.db.Close() }

func (s *wishlistStore) insert(e *entry) error {
	res, err := s.db.Exec(`
		INSERT INTO entries (owner, kind, spotify_id, spotify_url, title, artist, album, cover_url, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (owner, kind, spotify_id) DO UPDATE SET
			title = excluded.title, artist = excluded.artist,
			album = excluded.album, cover_url = excluded.cover_url`,
		e.Owner, e.Kind, e.SpotifyID, e.SpotifyURL, e.Title, e.Artist, e.Album, e.CoverURL,
		e.CreatedAt.UTC().Format(time.RFC3339))
	if err != nil {
		return err
	}
	if id, err := res.LastInsertId(); err == nil && id > 0 {
		e.ID = id
	}
	// On upsert LastInsertId can be unreliable; fetch the definitive row id.
	return s.db.QueryRow(
		`SELECT id, acquired FROM entries WHERE owner = ? AND kind = ? AND spotify_id = ?`,
		e.Owner, e.Kind, e.SpotifyID).Scan(&e.ID, &e.Acquired)
}

// listFor returns everything visible to user: their own entries, entries
// individually shared with them, and all entries of owners who shared their
// whole list with them.
func (s *wishlistStore) listFor(user string) ([]entry, error) {
	rows, err := s.db.Query(`
		SELECT DISTINCT e.id, e.owner, e.kind, e.spotify_id, e.spotify_url,
		       e.title, e.artist, e.album, e.cover_url, e.acquired, e.created_at
		FROM entries e
		LEFT JOIN entry_shares es ON es.entry_id = e.id
		LEFT JOIN list_shares ls ON ls.owner = e.owner
		WHERE e.owner = ? OR es.username = ? OR ls.username = ?
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
		var createdAt string
		if err := rows.Scan(&e.ID, &e.Owner, &e.Kind, &e.SpotifyID, &e.SpotifyURL,
			&e.Title, &e.Artist, &e.Album, &e.CoverURL, &acquired, &createdAt); err != nil {
			return nil, err
		}
		e.Acquired = acquired != 0
		e.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
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
	var createdAt string
	err := s.db.QueryRow(`
		SELECT id, owner, kind, spotify_id, spotify_url, title, artist, album, cover_url, acquired, created_at
		FROM entries WHERE id = ?`, id).
		Scan(&e.ID, &e.Owner, &e.Kind, &e.SpotifyID, &e.SpotifyURL,
			&e.Title, &e.Artist, &e.Album, &e.CoverURL, &acquired, &createdAt)
	if err != nil {
		return nil, err
	}
	e.Acquired = acquired != 0
	e.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	return &e, nil
}

func (s *wishlistStore) delete(id int64) error {
	_, err := s.db.Exec(`DELETE FROM entries WHERE id = ?`, id)
	return err
}

func (s *wishlistStore) setAcquired(id int64, acquired bool) error {
	v := 0
	if acquired {
		v = 1
	}
	_, err := s.db.Exec(`UPDATE entries SET acquired = ? WHERE id = ?`, v, id)
	return err
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
