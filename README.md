# NOVA Downloader — Flutter (API-only)

Mobile downloader for Android, built in Flutter. It resolves links **only**
through the [NOVA Downloader API](https://github.com/irfan420x/nova-downloader-api)
(`https://nova-downloader-api.vercel.app`) and downloads bytes directly from
CDNs. No local extractors, no yt-dlp, no local fallback of any kind.

## API contract

Base URL: `https://nova-downloader-api.vercel.app`

| Endpoint | Platform |
|---|---|
| `POST /youtube` | YouTube |
| `POST /tiktok` | TikTok |
| `POST /facebook` | Facebook |
| `POST /x` | X |
| `POST /soundcloud` | SoundCloud |
| `POST /direct` | Direct file (HEAD probe, refuses web pages) |
| `POST /hls` | HLS `.m3u8` playlist |
| `GET /api/health` | `{"ok": true}` |
| `GET /` | Endpoint list — the app consults this so future API endpoints light up without an app update |

All resolve endpoints take `POST {"url": "..."}` and return
`{title, thumbnail?, source, qualities[{id, label, ext, url, alternates[],
headers{User-Agent, Referer, Cookie}, size, videoOnly, audioOnly}],
debug{platform, ms, attempts[]}}`. Errors are honest
`{error:{code, message}}` — `UNSUPPORTED` 400, `NOT_FOUND` 404,
`BLOCKED` 502, `UPSTREAM_ERROR` 502 — and the app surfaces the API's
message, never a generic "failed".

Full verification of the API (live calls, routing table from
`lib/detect.js`, cold-start timing): see the API repo and
`API-CHECK-2026-11-19.md` in the review notes.

## Features

- Paste a link → platform detection → API resolve → quality sheet with
  **all** qualities (label, approx size, video/audio flags). Combined
  formats sort first.
- Download manager: queue, pause/resume via HTTP `Range`, progress,
  cancel, retry, per-file log.
- Per-quality headers (Cookie, Referer, User-Agent) are sent on **both**
  the probe and the download; primary URL + alternates are tried in order.
- Files saved to the public **Downloads** folder (Android: MediaStore via
  a platform channel, `lib/download/downloads_channel.dart` +
  `MainActivity.kt` — scoped storage blocks a direct Dart write).
- Downloads list with open / share / delete; history (persisted JSON).
- `/api/health` check on start with an honest offline message.
- 90s resolve timeout + one retry (API cold start was measured at ~49s),
  with a visible "Resolving…" state.
- Platforms with no API endpoint yet — Instagram, Pinterest, Twitch,
  Reddit, Vimeo, Dailymotion — show an honest "not supported yet" message.
  Never faked.
- Where only separate video+audio exist, both are downloaded and labelled
  clearly. Merging is deferred — the app never fakes a merged file.

## Design

NOVA Nebula Dark Premium: background `#0A0C1C`, cards `#14172B`,
primary violet `#8B5CF6`, gradient `#7C3AED → #3B82F6`, secondary cyan
`#22D3EE`, pink `#EC4899` sparing. See `lib/theme/nebula.dart`.

## Build

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release   # Android first; iOS later
```

Requirements: Flutter stable, JDK 17, Android SDK 35 + build-tools 35.0.0.
The release APK in this repo is signed with the debug key for now; a real
release key is created by the releaser before publishing.

## Privacy

Logs never contain full stream URLs or cookie values (host + header names
only). Stream URLs expire (TikTok: minutes) — the app downloads
immediately after resolving and never caches URLs across sessions.
