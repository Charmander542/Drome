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
  .scene { position: relative; min-height: 100dvh; isolation: isolate; }
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
    background: linear-gradient(180deg, rgba(0,0,0,.28) 0%, rgba(0,0,0,.52) 42%, rgba(0,0,0,.82) 100%);
  }
  .top {
    position: relative; z-index: 2;
    display: flex; align-items: center; gap: 10px;
    padding: calc(18px + env(safe-area-inset-top)) 24px 0;
  }
  .mark {
    width: 22px; height: 22px; border-radius: 6px;
    background: var(--accent); color: var(--on-accent);
    display: grid; place-items: center;
    font-size: 11px; font-weight: 800; letter-spacing: -.04em;
  }
  .brand { font-size: 15px; font-weight: 650; letter-spacing: -.02em; opacity: .92; }
  .stage {
    position: relative; z-index: 2;
    display: flex; flex-direction: column; align-items: center;
    gap: 28px;
    width: min(920px, 100%);
    margin: 0 auto;
    padding: 48px 24px calc(40px + env(safe-area-inset-bottom));
  }
  .art, .art.fallback {
    width: min(340px, 78vw); aspect-ratio: 1;
    border-radius: 8px; object-fit: cover;
    box-shadow: 0 28px 80px rgba(0,0,0,.62);
  }
  .art.fallback { background: color-mix(in srgb, var(--accent) 38%, #14141a); }
  .copy { text-align: center; max-width: 520px; }
  .kind {
    margin: 0 0 10px; font-size: 11px; font-weight: 700;
    letter-spacing: .14em; text-transform: uppercase;
    color: rgba(255,255,255,.48);
  }
  h1 {
    margin: 0; font-size: clamp(1.6rem, 4vw, 2.4rem);
    line-height: 1.12; letter-spacing: -.03em; font-weight: 750;
  }
  .artist { margin: 10px 0 0; font-size: 1.15rem; font-weight: 550; color: rgba(255,255,255,.86); }
  .album { margin: 8px 0 0; font-size: .95rem; color: rgba(255,255,255,.5); }
  .actions { display: flex; flex-direction: column; align-items: center; gap: 12px; margin-top: 22px; }
  .play {
    display: inline-flex; align-items: center; justify-content: center;
    min-width: 200px; padding: 14px 28px; border-radius: 999px;
    background: var(--accent); color: var(--on-accent);
    text-decoration: none; font-weight: 700; font-size: 1.02rem;
  }
  .hint { margin: 0; color: rgba(255,255,255,.38); font-size: .78rem; }
  @media (min-width: 760px) {
    .stage {
      flex-direction: row; align-items: center; justify-content: center;
      padding-top: 72px; gap: 48px;
    }
    .art, .art.fallback { width: 320px; flex: 0 0 320px; }
    .copy { text-align: left; }
    .actions { align-items: flex-start; }
  }
</style>
</head>
<body>
  <div class="scene">
    ` + backdrop + `
    <div class="scrim"></div>
    <header class="top">
      <span class="mark">D</span>
      <span class="brand">Drome</span>
    </header>
    <main class="stage">
      ` + hero + `
      <div class="copy">
        <p class="kind">Song</p>
        <h1>` + title + `</h1>
        ` + artistHTML + `
        ` + albumLine(album) + `
        <div class="actions">
          <a class="play" href="` + deep + `">Play in Drome</a>
          <p class="hint">Opens the Drome app if it’s installed.</p>
        </div>
      </div>
    </main>
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
