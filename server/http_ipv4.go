package main

import (
	"context"
	"net"
	"net/http"
	"time"
)

// ipv4HTTPClient returns an HTTP client that dials IPv4 only.
// This host often resolves Spotify (and others) to AAAA records while IPv6
// has no default route, which surfaces as "network is unreachable" or
// multi-second hangs before Happy Eyeballs gives up.
func ipv4HTTPClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = http.ProxyFromEnvironment
	transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp4", addr)
	}
	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
	}
}
