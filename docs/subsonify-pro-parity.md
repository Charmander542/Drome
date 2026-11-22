# Subsonify Pro feature parity

Goal: match Subsonify Pro’s capabilities in Drome (self-hosted Navidrome client), without a paywall.

## Status matrix

| Pro feature | Drome | Notes |
|---|---|---|
| Offline downloads + library | **Done** | Downloads, auto-starred, offline mode |
| Discovery (Song Radio / For You / Play something) | **Done** | Instant Mix, Daily Mixes, Vibe Tuner, Autoplay |
| Apple Watch on its own | **Partial** | Companion remote + Song Radio / rating / volume; `WKRunsIndependentlyOfCompanionApp` on. Standalone stream/download still TODO |
| Ten-band EQ + headphone profiles | **Done** | 10-band PCM EQ; per-output profiles with auto-apply |
| Beat-aligned mix transitions | **Done** | Soft + beat-aligned modes; same-album stays gapless |
| Chromecast | **Deferred** | AirPlay + Drome Connect cover casting on Apple platforms; Google Cast SDK not bundled |
| Smart playlists | **Done / in progress** | Rule-based smart playlists in Library |
| Listening stats | **Done / in progress** | Settings → Your listening |
| CarPlay | **Improved** | Song Radio on Home + Now Playing |

## Demo / streaming-only mode

Without a wishlist companion URL, Drome is streaming-only:

- Daily Mixes / For You hidden on Home
- Wishlist hidden in Library
- Spotify “missing tracks” search hidden on album/artist pages
- Connect multi-device needs the companion — also off

**Try public demo:** Login and Home both offer `demo.navidrome.org` (`demo` / `demo`).

## Follow-ups

1. **Watch standalone audio** — Subsonic client + AVPlayer on watchOS, Wi‑Fi/LTE stream, WatchConnectivity file transfer for a small download cache.
2. **Chromecast** — Only if/when Google Cast SPM + receiver registration is worth the dependency vs AirPlay/Connect.
3. **True dual-player overlap crossfade** — Current mix transitions fade out before end + fade in after advance (AVQueuePlayer single stream).
4. **AutoEq import** — Import published headphone curves into headphone profiles.
5. **Disc/track numbers in album UI** — from Subsonify Reddit feedback.
