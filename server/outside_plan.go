package main

import (
	"context"
	"os"
	"strings"
	"time"
)

// outsidePlanConfig controls the background "songs you might like" planner.
// It reuses the same Spotify search + library-owns filter as GET
// /recommendations/outside, then queues wishlist downloads for configured users.
type outsidePlanConfig struct {
	Enabled    bool
	Users      []string
	Interval   time.Duration
	RunOnStart bool
	// PerRun is how many new tracks to queue for each user per tick.
	PerRun int
	// PerArtist caps picks from one seed artist in a single run.
	PerArtist int
	// SeedArtists is how many listening artists to search Spotify for.
	SeedArtists int
	// MaxActive skips planning when the user already has this many
	// queued+downloading+failed wishlist rows (avoids piling onto big imports).
	MaxActive int
}

func outsidePlanConfigFromEnv() outsidePlanConfig {
	enabled := strings.ToLower(envOr("DROME_OUTSIDE_PLAN_ENABLED", "false"))
	onStart := strings.ToLower(envOr("DROME_OUTSIDE_PLAN_ON_START", "false"))
	usersRaw := envOr("DROME_OUTSIDE_PLAN_USERS", "cvanhook")
	var users []string
	seen := map[string]struct{}{}
	for _, part := range strings.Split(usersRaw, ",") {
		u := strings.TrimSpace(part)
		if u == "" {
			continue
		}
		key := strings.ToLower(u)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		users = append(users, u)
	}
	cfg := outsidePlanConfig{
		Enabled:     enabled == "1" || enabled == "true" || enabled == "yes",
		Users:       users,
		Interval:    envDuration("DROME_OUTSIDE_PLAN_INTERVAL", 24*time.Hour),
		RunOnStart:  onStart == "1" || onStart == "true" || onStart == "yes",
		PerRun:      envInt("DROME_OUTSIDE_PLAN_PER_RUN", 3),
		PerArtist:   envInt("DROME_OUTSIDE_PLAN_PER_ARTIST", 1),
		SeedArtists: envInt("DROME_OUTSIDE_PLAN_SEED_ARTISTS", 4),
		MaxActive:   envInt("DROME_OUTSIDE_PLAN_MAX_ACTIVE", 8),
	}
	if cfg.PerRun < 1 {
		cfg.PerRun = 1
	}
	if cfg.PerArtist < 1 {
		cfg.PerArtist = 1
	}
	if cfg.SeedArtists < 1 {
		cfg.SeedArtists = 1
	}
	if cfg.MaxActive < 1 {
		cfg.MaxActive = 1
	}
	return cfg
}

const (
	autoPicksSourceID   = "drome:auto-picks"
	autoPicksSourceName = "Auto picks"
)

type outsidePlanner struct {
	cfg    outsidePlanConfig
	server *server
}

func newOutsidePlanner(cfg outsidePlanConfig, srv *server) *outsidePlanner {
	return &outsidePlanner{cfg: cfg, server: srv}
}

func (p *outsidePlanner) Run(ctx context.Context) {
	if p == nil || p.server == nil {
		return
	}
	if !p.cfg.Enabled {
		logf("outside planner disabled (DROME_OUTSIDE_PLAN_ENABLED=false)")
		return
	}
	if len(p.cfg.Users) == 0 {
		logf("outside planner enabled but DROME_OUTSIDE_PLAN_USERS is empty")
		return
	}
	if p.cfg.Interval < time.Minute {
		p.cfg.Interval = time.Minute
	}
	logf("outside planner enabled every %s for %s (perRun=%d perArtist=%d maxActive=%d)",
		p.cfg.Interval, strings.Join(p.cfg.Users, ","), p.cfg.PerRun, p.cfg.PerArtist, p.cfg.MaxActive)

	if p.cfg.RunOnStart {
		// Short delay so Mornye/bootstrap and operator creds can settle.
		select {
		case <-ctx.Done():
			return
		case <-time.After(3 * time.Minute):
			p.runOnce(ctx)
		}
	}

	t := time.NewTicker(p.cfg.Interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.runOnce(ctx)
		}
	}
}

func (p *outsidePlanner) runOnce(ctx context.Context) {
	if p.server.spotify == nil || !p.server.spotify.hasAPICreds() {
		logf("outside planner: skip (Spotify API not configured)")
		return
	}
	if p.server.downloads == nil || !p.server.downloads.cfg.Enabled {
		logf("outside planner: skip (auto-download disabled)")
		return
	}
	creds, ok := p.server.downloads.scanCreds()
	if !ok || p.server.navidrome == nil {
		logf("outside planner: skip (no Navidrome credentials yet — open the app once or set DROME_NAVIDROME_SCAN_*)")
		return
	}

	for _, owner := range p.cfg.Users {
		if err := ctx.Err(); err != nil {
			return
		}
		// Listening seeds + library-owns checks use the Subsonic session.
		// Prefer planning only when that session belongs to the target user.
		sessionUser := creds.user
		if scanUser := strings.TrimSpace(os.Getenv("DROME_NAVIDROME_SCAN_USER")); scanUser != "" {
			sessionUser = scanUser
		}
		if !strings.EqualFold(sessionUser, owner) {
			logf("outside planner: skip %s (Navidrome session is %q)", owner, sessionUser)
			continue
		}
		n, err := p.planForUser(ctx, owner, creds)
		if err != nil {
			logf("outside planner: %s: %v", owner, err)
			continue
		}
		if n > 0 {
			logf("outside planner: queued %d auto pick(s) for %s", n, owner)
		} else {
			logf("outside planner: no new picks for %s", owner)
		}
	}
}

func (p *outsidePlanner) planForUser(ctx context.Context, owner string, creds subsonicCreds) (int, error) {
	owner = strings.TrimSpace(owner)
	if owner == "" {
		return 0, nil
	}
	st, err := p.server.store.downloadQueueStats(owner)
	if err != nil {
		return 0, err
	}
	active := st.Queued + st.Downloading + st.Failed
	if active >= p.cfg.MaxActive {
		logf("outside planner: skip %s (active queue %d ≥ %d)", owner, active, p.cfg.MaxActive)
		return 0, nil
	}

	planCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()

	picks, note := p.server.planOutsidePicks(planCtx, owner, creds, nil, p.cfg.SeedArtists, p.cfg.PerArtist, p.cfg.PerRun)
	if len(picks) == 0 {
		if note != "" {
			logf("outside planner: %s: %s", owner, note)
		}
		return 0, nil
	}

	added := 0
	for _, pick := range picks {
		if err := ctx.Err(); err != nil {
			return added, err
		}
		ok, err := p.server.enqueueOutsidePick(planCtx, owner, pick, creds)
		if err != nil {
			logf("outside planner: enqueue %q — %s: %v", pick.Title, pick.Artist, err)
			continue
		}
		if ok {
			added++
		}
	}
	if added > 0 && p.server.downloads != nil {
		p.server.downloads.kick()
	}
	return added, nil
}
