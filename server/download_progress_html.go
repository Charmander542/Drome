package main

import (
	"fmt"
	"html"
	"strings"
	"time"
)

func downloadProgressHTML(rep downloadStatusReport) string {
	var b strings.Builder
	b.WriteString(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="3">
<title>Drome · Download progress</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0c0d10;
    --panel: #15171c;
    --ink: #f2f3f5;
    --muted: #9aa3b2;
    --line: #2a2e38;
    --accent: #3dd6c6;
    --warn: #e8b86d;
    --bad: #e87a7a;
    --ok: #7dcea0;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100dvh;
    font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
    color: var(--ink);
    background:
      radial-gradient(1200px 600px at 10% -10%, #1a2430 0%, transparent 55%),
      radial-gradient(900px 500px at 100% 0%, #182018 0%, transparent 50%),
      var(--bg);
  }
  main {
    max-width: 920px;
    margin: 0 auto;
    padding: 28px 20px 48px;
  }
  h1 {
    font-family: "IBM Plex Serif", Georgia, serif;
    font-weight: 600;
    font-size: clamp(1.6rem, 3vw, 2.1rem);
    margin: 0 0 6px;
    letter-spacing: -0.02em;
  }
  .sub {
    color: var(--muted);
    margin: 0 0 22px;
    font-size: 0.95rem;
  }
  .grid {
    display: grid;
    gap: 14px;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    margin-bottom: 22px;
  }
  .stat {
    background: color-mix(in srgb, var(--panel) 88%, transparent);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 14px 16px;
  }
  .stat .label { color: var(--muted); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; }
  .stat .value { font-size: 1.7rem; font-weight: 650; margin-top: 4px; }
  section {
    background: color-mix(in srgb, var(--panel) 92%, transparent);
    border: 1px solid var(--line);
    border-radius: 14px;
    padding: 16px 18px;
    margin-bottom: 16px;
  }
  section h2 {
    margin: 0 0 12px;
    font-size: 0.95rem;
    font-weight: 650;
    letter-spacing: 0.02em;
    text-transform: uppercase;
    color: var(--muted);
  }
  .active-title { font-size: 1.2rem; font-weight: 600; margin: 0 0 4px; }
  .muted { color: var(--muted); }
  .phase {
    display: inline-block;
    margin-top: 10px;
    padding: 4px 10px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    color: var(--accent);
    font-size: 0.85rem;
    font-weight: 600;
  }
  .bar {
    height: 8px;
    background: #22262f;
    border-radius: 999px;
    overflow: hidden;
    margin: 10px 0 6px;
  }
  .bar > span {
    display: block;
    height: 100%;
    background: linear-gradient(90deg, #2bb3a5, var(--accent));
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.92rem;
  }
  th, td {
    text-align: left;
    padding: 8px 6px;
    border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  th { color: var(--muted); font-weight: 550; font-size: 0.78rem; text-transform: uppercase; }
  .status-queued { color: var(--warn); }
  .status-downloading { color: var(--accent); }
  .status-failed { color: var(--bad); }
  .log {
    font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace;
    font-size: 0.78rem;
    line-height: 1.45;
    max-height: 280px;
    overflow: auto;
    white-space: pre-wrap;
    color: #c8d0dc;
    background: #0a0b0e;
    border-radius: 10px;
    padding: 12px;
    border: 1px solid var(--line);
  }
  .empty { color: var(--muted); font-size: 0.95rem; }
  .pill-ok { color: var(--ok); }
</style>
</head>
<body>
<main>
`)
	fmt.Fprintf(&b, `<h1>Download progress</h1>
<p class="sub">Auto-refreshes every 3s · updated %s`, html.EscapeString(rep.UpdatedAt.Format(time.RFC3339)))
	if !rep.Enabled {
		b.WriteString(` · <span class="status-failed">auto-download disabled</span>`)
	}
	b.WriteString("</p>\n")

	fmt.Fprintf(&b, `<div class="grid">
  <div class="stat"><div class="label">Queued</div><div class="value">%d</div></div>
  <div class="stat"><div class="label">Downloading</div><div class="value">%d</div></div>
  <div class="stat"><div class="label">Failed</div><div class="value">%d</div></div>
  <div class="stat"><div class="label">Retrying</div><div class="value">%d</div></div>
</div>
`, rep.Queue.Queued, rep.Queue.Downloading, rep.Queue.Failed, rep.Queue.Retrying)

	b.WriteString(`<section><h2>Now running</h2>`)
	if rep.Active == nil {
		b.WriteString(`<p class="empty">Idle — nothing downloading right now.</p>`)
	} else {
		a := rep.Active
		title := a.Title
		if title == "" {
			title = "(untitled)"
		}
		fmt.Fprintf(&b, `<p class="active-title">%s</p>`, html.EscapeString(title))
		meta := strings.TrimSpace(strings.Join(filterNonEmpty(a.Artist, a.Album, a.Kind), " · "))
		if meta != "" {
			fmt.Fprintf(&b, `<p class="muted">%s</p>`, html.EscapeString(meta))
		}
		if a.SourcePlaylistName != "" {
			fmt.Fprintf(&b, `<p class="muted">From playlist %s</p>`, html.EscapeString(a.SourcePlaylistName))
		}
		fmt.Fprintf(&b, `<div class="phase">%s</div>`, html.EscapeString(a.Phase))
		if a.Detail != "" {
			fmt.Fprintf(&b, `<p class="muted" style="margin-top:10px">%s</p>`, html.EscapeString(a.Detail))
		}
		if a.TracksTotal > 0 {
			pct := 0
			if a.TracksTotal > 0 {
				pct = int(float64(a.TracksDone) / float64(a.TracksTotal) * 100)
				if pct > 100 {
					pct = 100
				}
			}
			fmt.Fprintf(&b, `<div class="bar"><span style="width:%d%%"></span></div>
<p class="muted">Tracks %d / %d · attempt %d/%d · %ds elapsed</p>`,
				pct, a.TracksDone, a.TracksTotal, a.Attempt, a.MaxAttempts, a.ElapsedSec)
		} else {
			fmt.Fprintf(&b, `<p class="muted" style="margin-top:8px">Attempt %d/%d · %ds elapsed</p>`,
				a.Attempt, a.MaxAttempts, a.ElapsedSec)
		}
	}
	if rep.CooldownRemaining != "" {
		fmt.Fprintf(&b, `<p class="status-failed" style="margin-top:12px">Provider cooldown: %s</p>`,
			html.EscapeString(rep.CooldownRemaining))
	}
	b.WriteString(`</section>`)

	b.WriteString(`<section><h2>Playlist imports</h2>`)
	if len(rep.Playlists) == 0 {
		b.WriteString(`<p class="empty">No playlist downloads in the queue.</p>`)
	} else {
		b.WriteString(`<table><thead><tr><th>Playlist</th><th>Progress</th><th>Queued</th><th>Down</th><th>Failed</th></tr></thead><tbody>`)
		for _, p := range rep.Playlists {
			name := p.PlaylistName
			if name == "" {
				name = p.PlaylistID
			}
			curHTML := ""
			if p.CurrentTitle != "" {
				cur := p.CurrentTitle
				if p.CurrentArtist != "" {
					cur += " — " + p.CurrentArtist
				}
				curHTML = `<div class="muted" style="margin-top:4px">` + html.EscapeString(cur) + `</div>`
			}
			fmt.Fprintf(&b, `<tr>
<td>%s%s</td>
<td><div class="bar"><span style="width:%d%%"></span></div><span class="muted">%d left</span></td>
<td>%d</td><td>%d</td><td>%d</td>
</tr>`,
				html.EscapeString(name), curHTML,
				p.Percent, p.Total, p.Queued, p.Downloading, p.Failed)
		}
		b.WriteString(`</tbody></table>`)
	}
	b.WriteString(`</section>`)

	b.WriteString(`<section><h2>Queue</h2>`)
	if len(rep.Items) == 0 {
		b.WriteString(`<p class="empty">Queue is empty.</p>`)
	} else {
		b.WriteString(`<table><thead><tr><th>Status</th><th>Item</th><th>Detail</th></tr></thead><tbody>`)
		for _, e := range rep.Items {
			stClass := "status-" + e.Status
			detail := e.StatusMsg
			if e.SourcePlaylistName != "" {
				if detail != "" {
					detail = e.SourcePlaylistName + " · " + detail
				} else {
					detail = "from " + e.SourcePlaylistName
				}
			}
			if !e.NextRetry.IsZero() {
				retry := "retry " + e.NextRetry.UTC().Format(time.RFC3339)
				if detail != "" {
					detail = retry + " · " + detail
				} else {
					detail = retry
				}
			}
			title := e.Title
			if e.Artist != "" {
				title = e.Title + " — " + e.Artist
			}
			fmt.Fprintf(&b, `<tr>
<td class="%s">%s</td>
<td>%s <span class="muted">(%s)</span></td>
<td class="muted">%s</td>
</tr>`, stClass, html.EscapeString(e.Status), html.EscapeString(title), html.EscapeString(e.Kind), html.EscapeString(detail))
		}
		b.WriteString(`</tbody></table>`)
	}
	b.WriteString(`</section>`)

	b.WriteString(`<section><h2>Recent SpotiFLAC log</h2>`)
	if len(rep.RecentLog) == 0 {
		b.WriteString(`<p class="empty">No live log lines yet.</p>`)
	} else {
		b.WriteString(`<div class="log">`)
		b.WriteString(html.EscapeString(strings.Join(rep.RecentLog, "\n")))
		b.WriteString(`</div>`)
	}
	b.WriteString(`</section>
</main>
</body>
</html>`)
	return b.String()
}

func filterNonEmpty(parts ...string) []string {
	var out []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
