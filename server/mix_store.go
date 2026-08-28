package main

import (
	"database/sql"
	"encoding/json"
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

// recentDailyMixSongIDs returns every song ID that appeared in stored Daily
// Mixes on the given radio days (used to enforce multi-day no-repeat).
func (s *wishlistStore) recentDailyMixSongIDs(owner string, days []string) (map[string]struct{}, error) {
	out := make(map[string]struct{})
	for _, day := range days {
		raw, ok, err := s.getDailyMixJSON(owner, day)
		if err != nil || !ok {
			continue
		}
		var resp dailyMixResponse
		if json.Unmarshal([]byte(raw), &resp) != nil {
			continue
		}
		for _, mix := range resp.Mixes {
			for _, song := range mix.Songs {
				if song.ID != "" {
					out[song.ID] = struct{}{}
				}
			}
		}
	}
	return out, nil
}

func previousRadioDays(currentDay string, count int) []string {
	if count <= 0 {
		return nil
	}
	t, err := time.Parse("2006-01-02", currentDay)
	if err != nil {
		return nil
	}
	out := make([]string, 0, count)
	for i := 1; i <= count; i++ {
		out = append(out, t.AddDate(0, 0, -i).Format("2006-01-02"))
	}
	return out
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
