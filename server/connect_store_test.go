package main

import (
	"path/filepath"
	"testing"
	"time"
)

func TestListConnectDevicesNoDeadlock(t *testing.T) {
	dir := t.TempDir()
	store, err := openStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	d := connectDevice{
		ID: "phone", Owner: "alice", Name: "iPhone", Platform: "ios",
		LastSeenAt: nowUnix(), Capabilities: []string{"audio"},
	}
	if err := store.upsertConnectDevice(d); err != nil {
		t.Fatal(err)
	}
	if err := store.putConnectSession(connectSession{
		Owner: "alice", ActiveDeviceID: "phone", UpdatedAt: nowUnix(),
		Snapshot: []byte("null"),
	}); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := store.listConnectDevices("alice")
		done <- err
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("listConnectDevices deadlocked (nested query with MaxOpenConns(1))")
	}
}
