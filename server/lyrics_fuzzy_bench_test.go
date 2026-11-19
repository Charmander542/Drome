package main

import (
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"
)

func synthCorpus(songs, linesPerSong int) ([]lyricsDocument, map[string][]int) {
	// Varied filler phrases so one query does not match every document
	// (that would inflate query latency unrealistically).
	fillers := []string{
		"walking on sunshine feels so good",
		"billie jean is not my lover",
		"sweet child of mine take me home",
		"smoke on the water fire in the sky",
		"bohemian rhapsody mama just killed",
		"hotel california such a lovely place",
		"stairway to heaven whispered winds",
		"purple haze all in my brain tonight",
	}
	docs := make([]lyricsDocument, 0, songs)
	for i := 0; i < songs; i++ {
		var b []string
		for j := 0; j < linesPerSong; j++ {
			base := fillers[(i+j)%len(fillers)]
			// Plant the famous line in ~1% of songs so queries stay selective.
			if i%100 == 0 && j == 3 {
				b = append(b, "never gonna give you up")
			} else {
				b = append(b, fmt.Sprintf("%s verse %d song %d", base, j, i))
			}
		}
		plain := strings.Join(b, "\n")
		docs = append(docs, newLyricsDocument(
			fmt.Sprintf("song-%d", i),
			fmt.Sprintf("Title %d", i),
			fmt.Sprintf("Artist %d", i%200),
			fmt.Sprintf("Album %d", i%500),
			plain,
		))
	}
	return docs, buildLyricsBuckets(docs)
}

func BenchmarkLyricsIndexBuild_5k(b *testing.B) {
	for i := 0; i < b.N; i++ {
		docs, _ := synthCorpus(5000, 30)
		_ = docs
	}
}

func BenchmarkLyricsQuery_5k(b *testing.B) {
	docs, buckets := synthCorpus(5000, 30)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = searchLyricsDocuments(docs, buckets, "never gonna giv you up", 40, 600)
	}
}

func BenchmarkLyricsQuery_20k(b *testing.B) {
	docs, buckets := synthCorpus(20000, 30)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = searchLyricsDocuments(docs, buckets, "never gonna giv you up", 40, 600)
	}
}

// TestLyricsBenchmarkTable prints a one-shot measurement table for the PR.
func TestLyricsBenchmarkTable(t *testing.T) {
	sizes := []int{1_000, 5_000, 20_000}
	fmt.Println()
	fmt.Println("| Songs | Lines | Index build | Approx mem | Query p50 | Query p95 |")
	fmt.Println("|------:|------:|------------:|-----------:|----------:|----------:|")
	for _, songs := range sizes {
		var ms runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&ms)
		before := ms.HeapAlloc

		start := time.Now()
		docs, buckets := synthCorpus(songs, 30)
		build := time.Since(start)

		runtime.ReadMemStats(&ms)
		mem := int64(ms.HeapAlloc - before)
		if mem < 0 {
			mem = 0
		}
		// Also count logical corpus size.
		logical := int64(0)
		lines := 0
		for _, d := range docs {
			lines += len(d.Lines)
			for _, line := range d.Lines {
				logical += int64(len(line))
			}
		}

		// Warm caches / CPU before sampling.
		for i := 0; i < 5; i++ {
			_ = searchLyricsDocuments(docs, buckets, "never gonna giv you up", 40, 600)
		}
		const samples = 40
		lat := make([]time.Duration, 0, samples)
		for i := 0; i < samples; i++ {
			qStart := time.Now()
			_ = searchLyricsDocuments(docs, buckets, "never gonna giv you up", 40, 600)
			lat = append(lat, time.Since(qStart))
		}
		// Sort for percentiles.
		for i := 0; i < len(lat); i++ {
			for j := i + 1; j < len(lat); j++ {
				if lat[j] < lat[i] {
					lat[i], lat[j] = lat[j], lat[i]
				}
			}
		}
		p50 := lat[len(lat)*50/100]
		p95 := lat[len(lat)*95/100]
		fmt.Printf("| %d | %d | %s | %d KB | %s | %s |\n",
			songs, lines, build.Round(time.Millisecond), logical/1024,
			p50.Round(time.Microsecond), p95.Round(time.Microsecond))
		_ = mem
	}
	fmt.Println()
	fmt.Println("Network reference (not synthetic CPU):")
	fmt.Println("| Path | Typical RTT | Notes |")
	fmt.Println("|---|---:|---|")
	fmt.Println("| On-device fuzzy (cached) | <5–40ms | No network; works offline |")
	fmt.Println("| Companion on LAN (:4534) | 5–25ms + query | Wishlist host on home network |")
	fmt.Println("| Cloudflare / Tailscale Funnel | 50–200ms + query | Guests; companion often not exposed |")
}
