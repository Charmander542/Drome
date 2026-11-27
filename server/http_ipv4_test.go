package main

import (
	"net"
	"net/http"
	"testing"
	"time"
)

func TestIPv4HTTPClientDialsTCP4(t *testing.T) {
	c := ipv4HTTPClient(5 * time.Second)
	tr, ok := c.Transport.(*http.Transport)
	if !ok || tr == nil || tr.DialContext == nil {
		t.Fatal("expected custom transport dialer")
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err == nil {
			_ = conn.Close()
		}
	}()
	conn, err := tr.DialContext(t.Context(), "tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("accept timed out")
	}
}
