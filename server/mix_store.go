package main

import (
	"database/sql"
	"time"
)

func (s *wishlistStore) migrateMixes() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS daily_mixes (
	owner      TEXT NOT NULL,
	day        TEXT NOT NULL,
	payload    TEXT NOT NULL,
	created_at TEXT NOT NULL,
	PRIMARY KEY (owner, day)
);
CREATE TABLE IF NOT EXISTS vibe_mixes (
	owner      TEXT NOT NULL,
	vibe       TEXT NOT NULL,
	day        TEXT NOT NULL,
	payload    TEXT NOT NULL,
	created_at TEXT NOT NULL,
	PRIMARY KEY (owner, vibe, day)
);
`)
	return err
}

func (s *wishlistStore) getDailyMixJSON(owner, day string) (string, bool, error) {
	var payload string
	err := s.db.QueryRow(
		`SELECT payload FROM daily_mixes WHERE owner = ? AND day = ?`,
		owner, day,
	).Scan(&payload)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return payload, true, nil
}

func (s *wishlistStore) putDailyMixJSON(owner, day, payload string) error {
	_, err := s.db.Exec(`
INSERT INTO daily_mixes (owner, day, payload, created_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(owner, day) DO UPDATE SET payload = excluded.payload, created_at = excluded.created_at
`, owner, day, payload, time.Now().UTC().Format(time.RFC3339))
	return err
}

func (s *wishlistStore) getVibeMixJSON(owner, vibe, day string) (string, bool, error) {
	var payload string
	err := s.db.QueryRow(
		`SELECT payload FROM vibe_mixes WHERE owner = ? AND vibe = ? AND day = ?`,
		owner, vibe, day,
	).Scan(&payload)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return payload, true, nil
}

func (s *wishlistStore) putVibeMixJSON(owner, vibe, day, payload string) error {
	_, err := s.db.Exec(`
INSERT INTO vibe_mixes (owner, vibe, day, payload, created_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(owner, vibe, day) DO UPDATE SET payload = excluded.payload, created_at = excluded.created_at
`, owner, vibe, day, payload, time.Now().UTC().Format(time.RFC3339))
	return err
}
