package main

import (
	"fmt"
	"strings"
)

func sharePageHTML(headline, title, artist, album, desc, pageURL, coverURL, deep, accent, onAccent string, hasCover bool) string {
	ogImage := ""
	backdrop := `<div class="wash"></div>`
	hero := `<div class="art fallback" aria-hidden="true"></div>`
	if hasCover {
		ogImage = `<meta property="og:image" content="` + coverURL + `">
<meta property="og:image:alt" content="` + headline + `">
<meta property="og:image:width" content="400">
<meta property="og:image:height" content="400">
<meta name="twitter:image" content="` + coverURL + `">
<link rel="preload" as="image" href="` + coverURL + `">`
		backdrop = `<div class="blur" id="bg"></div>`
		hero = `<img class="art" src="` + coverURL + `" alt="` + title + `" width="400" height="400" fetchpriority="high" decoding="async" onload="document.getElementById('bg').style.backgroundImage='url('+JSON.stringify(this.currentSrc)+')'">`
	}
	artistHTML := ""
	if artist != "" {
		artistHTML = `<p class="artist">` + artist + `</p>`
	}
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>` + headline + `</title>
<link rel="canonical" href="` + pageURL + `">
<meta name="description" content="` + desc + `">
<meta property="og:type" content="music.song">
<meta property="og:title" content="` + title + `">
<meta property="og:description" content="` + desc + `">
<meta property="og:url" content="` + pageURL + `">
<meta property="og:site_name" content="Drome">
<meta property="al:ios:url" content="` + deep + `">
<meta property="al:ios:app_name" content="Drome">
<meta name="apple-itunes-app" content="app-argument=` + deep + `">
` + ogImage + `
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="` + title + `">
<meta name="twitter:description" content="` + desc + `">
<meta name="theme-color" content="` + accent + `">
<script>
(function () {
  var ua = navigator.userAgent || "";
  if (/bot|crawler|spider|preview|facebookexternalhit|Twitterbot|Slackbot|Discordbot|WhatsApp|LinkedInBot|Applebot|Googlebot|Bingbot|SkypeUriPreview|Iframely|Embedly/i.test(ua)) return;
  window.location.replace("` + deep + `");
})();
</script>
<style>
  :root { color-scheme: dark; --accent: ` + accent + `; --on-accent: ` + onAccent + `; }
  * { box-sizing: border-box; }
  html, body { margin: 0; min-height: 100%; }
  body {
    min-height: 100dvh;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
    color: #fff;
    background: #050507;
    overflow-x: hidden;
  }
  .scene {
    position: relative; min-height: 100dvh; isolation: isolate;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    padding: calc(20px + env(safe-area-inset-top)) 20px calc(24px + env(safe-area-inset-bottom));
  }
  .blur, .wash {
    position: fixed; inset: -48px;
    width: calc(100% + 96px); height: calc(100% + 96px);
    background-size: cover; background-position: center;
    pointer-events: none; z-index: 0;
    filter: blur(48px) saturate(1.35);
    transform: scale(1.08);
  }
  .wash { filter: none; background: var(--accent); opacity: .5; }
  .scrim {
    position: fixed; inset: 0; z-index: 1; pointer-events: none;
    background: rgba(0,0,0,.45);
  }
  .top {
    position: relative; z-index: 2;
    display: flex; align-items: center; gap: 8px;
    align-self: stretch;
    max-width: 380px; width: min(380px, 100%);
    margin: 0 auto 16px;
  }
  .mark {
    display: block; width: 22px; height: 19px; flex: none;
  }
  .brand { font-size: 15px; font-weight: 650; letter-spacing: -.02em; opacity: .92; }
  .card {
    position: relative; z-index: 2;
    display: flex; flex-direction: column; align-items: stretch;
    width: min(380px, 100%);
    border-radius: 16px;
    overflow: hidden;
    background: rgba(12,12,16,.78);
    box-shadow: 0 18px 50px rgba(0,0,0,.45);
    color: inherit; text-decoration: none;
  }
  .art, .art.fallback {
    width: 100%; aspect-ratio: 1;
    object-fit: cover;
    border-radius: 0;
  }
  .art.fallback { background: color-mix(in srgb, var(--accent) 38%, #14141a); min-height: 220px; }
  .copy {
    display: flex; flex-direction: column;
    text-align: left;
    padding: 18px 18px 20px;
  }
  .kind {
    margin: 0 0 8px; font-size: 11px; font-weight: 700;
    letter-spacing: .14em; text-transform: uppercase;
    color: rgba(255,255,255,.48);
  }
  h1 {
    margin: 0; font-size: clamp(1.25rem, 4vw, 1.7rem);
    line-height: 1.15; letter-spacing: -.03em; font-weight: 750;
  }
  .artist { margin: 8px 0 0; font-size: 1.02rem; font-weight: 550; color: rgba(255,255,255,.86); }
  .album { margin: 6px 0 0; font-size: .9rem; color: rgba(255,255,255,.5); }
  .actions { display: flex; flex-direction: column; align-items: stretch; gap: 10px; margin-top: 18px; }
  .play {
    display: flex; align-items: center; justify-content: center;
    width: 100%; padding: 14px 16px; border-radius: 10px;
    background: var(--accent); color: var(--on-accent);
    font-weight: 700; font-size: 1rem;
  }
  .hint { margin: 0; color: rgba(255,255,255,.38); font-size: .75rem; text-align: center; }
</style>
</head>
<body>
  <div class="scene">
    ` + backdrop + `
    <div class="scrim"></div>
    <header class="top">
      <svg class="mark" viewBox="0 0 137 120" aria-hidden="true">
        <rect x="0" y="30" width="17" height="60" rx="8.5" fill="#fff"/>
        <circle cx="32.5" cy="60" r="13.5" fill="#fff"/>
        <rect x="48" y="10" width="17" height="100" rx="8.5" fill="#fff"/>
        <rect x="72" y="0" width="17" height="120" rx="8.5" fill="#fff"/>
        <rect x="96" y="30" width="17" height="60" rx="8.5" fill="#fff"/>
        <circle cx="128.5" cy="60" r="11.5" fill="#fff"/>
      </svg>
      <span class="brand">Drome</span>
    </header>
    <a class="card" href="` + deep + `">
      ` + hero + `
      <div class="copy">
        <p class="kind">Song</p>
        <h1>` + title + `</h1>
        ` + artistHTML + `
        ` + albumLine(album) + `
        <div class="actions">
          <span class="play">Play in Drome</span>
          <p class="hint">Opens the Drome app if it’s installed.</p>
        </div>
      </div>
    </a>
  </div>
</body>
</html>`
}

func contrastText(accent string) string {
	s := strings.TrimPrefix(strings.TrimSpace(accent), "#")
	if len(s) == 3 {
		s = string([]byte{s[0], s[0], s[1], s[1], s[2], s[2]})
	}
	if len(s) != 6 {
		return "#ffffff"
	}
	var r, g, b int
	if _, err := fmt.Sscanf(strings.ToLower(s), "%02x%02x%02x", &r, &g, &b); err != nil {
		return "#ffffff"
	}
	if (0.299*float64(r)+0.587*float64(g)+0.114*float64(b))/255 > 0.62 {
		return "#111118"
	}
	return "#ffffff"
}
