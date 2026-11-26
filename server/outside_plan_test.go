package main

import (
	"os"
	"testing"
	"time"
)

func TestOutsidePlanConfigFromEnvDefaults(t *testing.T) {
	keys := []string{
		"DROME_OUTSIDE_PLAN_ENABLED",
		"DROME_OUTSIDE_PLAN_USERS",
		"DROME_OUTSIDE_PLAN_INTERVAL",
		"DROME_OUTSIDE_PLAN_ON_START",
		"DROME_OUTSIDE_PLAN_PER_RUN",
		"DROME_OUTSIDE_PLAN_PER_ARTIST",
		"DROME_OUTSIDE_PLAN_SEED_ARTISTS",
		"DROME_OUTSIDE_PLAN_MAX_ACTIVE",
	}
	for _, k := range keys {
		t.Setenv(k, "")
		_ = os.Unsetenv(k)
	}
	cfg := outsidePlanConfigFromEnv()
	if cfg.Enabled {
		t.Fatal("expected disabled by default")
	}
	if len(cfg.Users) != 1 || cfg.Users[0] != "cvanhook" {
		t.Fatalf("users: %#v", cfg.Users)
	}
	if cfg.Interval != 24*time.Hour {
		t.Fatalf("interval %s", cfg.Interval)
	}
	if cfg.PerRun != 3 || cfg.PerArtist != 1 || cfg.SeedArtists != 4 || cfg.MaxActive != 8 {
		t.Fatalf("limits: %+v", cfg)
	}
}

func TestOutsidePlanConfigFromEnvCustom(t *testing.T) {
	t.Setenv("DROME_OUTSIDE_PLAN_ENABLED", "true")
	t.Setenv("DROME_OUTSIDE_PLAN_USERS", "cvanhook, bubba, cvanhook")
	t.Setenv("DROME_OUTSIDE_PLAN_INTERVAL", "12h")
	t.Setenv("DROME_OUTSIDE_PLAN_PER_RUN", "5")
	t.Setenv("DROME_OUTSIDE_PLAN_MAX_ACTIVE", "10")
	cfg := outsidePlanConfigFromEnv()
	if !cfg.Enabled {
		t.Fatal("expected enabled")
	}
	if len(cfg.Users) != 2 || cfg.Users[0] != "cvanhook" || cfg.Users[1] != "bubba" {
		t.Fatalf("users: %#v", cfg.Users)
	}
	if cfg.Interval != 12*time.Hour || cfg.PerRun != 5 || cfg.MaxActive != 10 {
		t.Fatalf("cfg: %+v", cfg)
	}
}
