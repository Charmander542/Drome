package main

import (
	"strings"
	"testing"
)

func TestContrastText(t *testing.T) {
	if got := contrastText("#3D7EFF"); got != "#ffffff" {
		t.Fatalf("blue CTA text = %s", got)
	}
	if got := contrastText("#F2E6C9"); got != "#111118" {
		t.Fatalf("light CTA text = %s", got)
	}
}

func TestSharePageHTMLUsesCoverAndDeepLink(t *testing.T) {
	html := sharePageHTML(
		"Song — Artist", "Song", "Artist", "Album",
		"Artist · Album",
		"https://drome.example/s/abc?song=1",
		"https://drome.example/s/abc/cover",
		"drome://track/1",
		"#3D7EFF", "#ffffff", true)
	for _, want := range []string{
		`og:url" content="https://drome.example/s/abc?song=1"`,
		`rel="preload" as="image" href="https://drome.example/s/abc/cover"`,
		`src="https://drome.example/s/abc/cover"`,
		`<h1>Song</h1>`,
		`class="artist">Artist</p>`,
		`href="drome://track/1"`,
		`Play in Drome`,
		`<a class="card" href="drome://track/1">`,
		`location.replace("drome://track/1")`,
		`aspect-ratio: 1.91 / 1`,
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("share HTML missing %q", want)
		}
	}
}
