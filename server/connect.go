package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (s *server) registerConnectRoutes(mux *http.ServeMux) {
	mux.HandleFunc("PUT /connect/devices/{id}", s.requireAuth(s.handleConnectPutDevice))
	mux.HandleFunc("GET /connect/devices", s.requireAuth(s.handleConnectListDevices))
	mux.HandleFunc("DELETE /connect/devices/{id}", s.requireAuth(s.handleConnectDeleteDevice))
	mux.HandleFunc("PUT /connect/session", s.requireAuth(s.handleConnectPutSession))
	mux.HandleFunc("GET /connect/session", s.requireAuth(s.handleConnectGetSession))
	mux.HandleFunc("POST /connect/commands", s.requireAuth(s.handleConnectPostCommand))
	mux.HandleFunc("GET /connect/commands", s.requireAuth(s.handleConnectListCommands))
	mux.HandleFunc("POST /connect/commands/ack", s.requireAuth(s.handleConnectAckCommands))
	mux.HandleFunc("GET /connect/events", s.requireAuth(s.handleConnectEvents))
}

// PUT /connect/devices/{id}
func (s *server) handleConnectPutDevice(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "device id required")
		return
	}
	var body struct {
		Name         string   `json:"name"`
		Platform     string   `json:"platform"`
		Model        string   `json:"model"`
		IsPlaying    bool     `json:"isPlaying"`
		SongID       string   `json:"songId"`
		SongTitle    string   `json:"songTitle"`
		SongArtist   string   `json:"songArtist"`
		Elapsed      float64  `json:"elapsed"`
		Duration     float64  `json:"duration"`
		Capabilities []string `json:"capabilities"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	if strings.TrimSpace(body.Name) == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	if err := validatePlatform(body.Platform); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	d := connectDevice{
		ID:           id,
		Owner:        owner,
		Name:         body.Name,
		Platform:     body.Platform,
		Model:        body.Model,
		IsPlaying:    body.IsPlaying,
		SongID:       body.SongID,
		SongTitle:    body.SongTitle,
		SongArtist:   body.SongArtist,
		Elapsed:      body.Elapsed,
		Duration:     body.Duration,
		LastSeenAt:   nowUnix(),
		Capabilities: body.Capabilities,
	}
	if err := s.store.upsertConnectDevice(d); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	devices, _ := s.store.listConnectDevices(owner)
	if ev, err := encodeConnectEvent("devices", map[string]any{"devices": devices}); err == nil {
		s.connect.publish(owner, ev)
	}
	for i := range devices {
		if devices[i].ID == id {
			writeJSON(w, http.StatusOK, devices[i])
			return
		}
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *server) handleConnectListDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := s.store.listConnectDevices(requestUser(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if devices == nil {
		devices = []connectDevice{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (s *server) handleConnectDeleteDevice(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	id := r.PathValue("id")
	if err := s.store.deleteConnectDevice(owner, id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	devices, _ := s.store.listConnectDevices(owner)
	if ev, err := encodeConnectEvent("devices", map[string]any{"devices": devices}); err == nil {
		s.connect.publish(owner, ev)
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// PUT /connect/session — active player publishes full queue snapshot.
func (s *server) handleConnectPutSession(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	var body struct {
		ActiveDeviceID string          `json:"activeDeviceId"`
		IsPlaying      bool            `json:"isPlaying"`
		Snapshot       json.RawMessage `json:"snapshot"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	if body.ActiveDeviceID == "" {
		writeError(w, http.StatusBadRequest, "activeDeviceId is required")
		return
	}
	if len(body.Snapshot) == 0 {
		body.Snapshot = json.RawMessage("null")
	}
	sess := connectSession{
		Owner:          owner,
		ActiveDeviceID: body.ActiveDeviceID,
		IsPlaying:      body.IsPlaying,
		UpdatedAt:      nowUnix(),
		Snapshot:       body.Snapshot,
	}
	if err := s.store.putConnectSession(sess); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if ev, err := encodeConnectEvent("session", sess); err == nil {
		s.connect.publish(owner, ev)
	}
	writeJSON(w, http.StatusOK, sess)
}

func (s *server) handleConnectGetSession(w http.ResponseWriter, r *http.Request) {
	sess, err := s.store.getConnectSession(requestUser(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if sess == nil {
		writeJSON(w, http.StatusOK, map[string]any{"session": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"session": sess})
}

// POST /connect/commands
func (s *server) handleConnectPostCommand(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	var body struct {
		Type           string  `json:"type"`
		FromDeviceID   string  `json:"fromDeviceId"`
		TargetDeviceID string  `json:"targetDeviceId"`
		SeekTo         float64 `json:"seekTo"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	switch body.Type {
	case "transfer", "play", "pause", "next", "previous", "seek", "takeControl":
	default:
		writeError(w, http.StatusBadRequest, "unknown command type")
		return
	}
	if body.FromDeviceID == "" || body.TargetDeviceID == "" {
		writeError(w, http.StatusBadRequest, "fromDeviceId and targetDeviceId are required")
		return
	}

	// transfer / takeControl: mark the target as the active device.
	if body.Type == "transfer" || body.Type == "takeControl" {
		if err := s.store.setActiveDevice(owner, body.TargetDeviceID); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	cmd := connectCommand{
		ID:             newConnectCommandID(),
		Owner:          owner,
		Type:           body.Type,
		FromDeviceID:   body.FromDeviceID,
		TargetDeviceID: body.TargetDeviceID,
		SeekTo:         body.SeekTo,
		CreatedAt:      nowUnix(),
	}
	if err := s.store.enqueueConnectCommand(cmd); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if ev, err := encodeConnectEvent("command", cmd); err == nil {
		s.connect.publish(owner, ev)
	}
	if sess, _ := s.store.getConnectSession(owner); sess != nil {
		if ev, err := encodeConnectEvent("session", sess); err == nil {
			s.connect.publish(owner, ev)
		}
	}
	writeJSON(w, http.StatusCreated, cmd)
}

func (s *server) handleConnectListCommands(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	deviceID := r.URL.Query().Get("deviceId")
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "deviceId is required")
		return
	}
	after := 0.0
	if raw := r.URL.Query().Get("after"); raw != "" {
		if v, err := strconv.ParseFloat(raw, 64); err == nil {
			after = v
		}
	}
	cmds, err := s.store.listConnectCommands(owner, deviceID, after)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if cmds == nil {
		cmds = []connectCommand{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"commands": cmds})
}

func (s *server) handleConnectAckCommands(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	if err := s.store.consumeConnectCommands(owner, body.IDs); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// GET /connect/events?deviceId=… — Server-Sent Events for low-latency updates.
func (s *server) handleConnectEvents(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	ch := s.connect.subscribe(owner)
	defer s.connect.unsubscribe(owner, ch)

	// Initial snapshot so clients don't wait for the next change.
	if devices, err := s.store.listConnectDevices(owner); err == nil {
		if ev, err := encodeConnectEvent("devices", map[string]any{"devices": devices}); err == nil {
			writeSSE(w, flusher, ev)
		}
	}
	if sess, err := s.store.getConnectSession(owner); err == nil && sess != nil {
		if ev, err := encodeConnectEvent("session", sess); err == nil {
			writeSSE(w, flusher, ev)
		}
	}

	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			writeSSE(w, flusher, ev)
		case <-ticker.C:
			fmt.Fprintf(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func writeSSE(w http.ResponseWriter, flusher http.Flusher, ev connectEvent) {
	data, _ := json.Marshal(ev)
	fmt.Fprintf(w, "event: connect\ndata: %s\n\n", data)
	flusher.Flush()
}
