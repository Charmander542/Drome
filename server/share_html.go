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
    max-width: 640px; width: min(640px, 100%);
    margin: 0 auto 16px;
  }
  .mark {
    width: 20px; height: 20px; border-radius: 5px;
    background: var(--accent); color: var(--on-accent);
    display: grid; place-items: center;
    font-size: 10px; font-weight: 800; letter-spacing: -.04em;
  }
  .brand { font-size: 14px; font-weight: 650; letter-spacing: -.02em; opacity: .92; }
  .card {
    position: relative; z-index: 2;
    display: flex; flex-direction: row; align-items: stretch;
    width: min(640px, 100%);
    aspect-ratio: 1.91 / 1;
    max-height: 336px;
    border-radius: 14px;
    overflow: hidden;
    background: rgba(12,12,16,.72);
    box-shadow: 0 18px 50px rgba(0,0,0,.45);
    color: inherit; text-decoration: none;
  }
  .art, .art.fallback {
    height: 100%; width: auto; aspect-ratio: 1;
    flex: 0 0 auto;
    object-fit: cover;
    border-radius: 0;
  }
  .art.fallback { background: color-mix(in srgb, var(--accent) 38%, #14141a); }
  .copy {
    flex: 1 1 auto; min-width: 0;
    display: flex; flex-direction: column; justify-content: center;
    text-align: left;
    padding: 16px 18px 16px 20px;
  }
  .kind {
    margin: 0 0 6px; font-size: 10px; font-weight: 700;
    letter-spacing: .14em; text-transform: uppercase;
    color: rgba(255,255,255,.48);
  }
  h1 {
    margin: 0; font-size: clamp(1.05rem, 3.2vw, 1.55rem);
    line-height: 1.15; letter-spacing: -.03em; font-weight: 750;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .artist { margin: 6px 0 0; font-size: .95rem; font-weight: 550; color: rgba(255,255,255,.86);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .album { margin: 4px 0 0; font-size: .82rem; color: rgba(255,255,255,.5);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .actions { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; margin-top: 14px; }
  .play {
    display: inline-flex; align-items: center; justify-content: center;
    padding: 9px 16px; border-radius: 999px;
    background: var(--accent); color: var(--on-accent);
    text-decoration: none; font-weight: 700; font-size: .88rem;
  }
  .hint { margin: 0; color: rgba(255,255,255,.38); font-size: .7rem; }
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
