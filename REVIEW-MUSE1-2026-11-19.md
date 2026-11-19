# Review + fixes by Muse #1 (coordinator) — 2026-11-19 evening, LOCAL ONLY

Working copy HEAD: `8b3a3fe` (test fix included). **Not pushed, no release,
no APK build attempted** (Gradle daemon blocked on the Muse VM).

## Verdict after this pass

The app is now professionally sound in code and honestly specified.
Release still needs: an APK built on a machine where Gradle works
(the user's laptop), plus the signing decision (F-4, user's call).

## What was fixed (audit F-1..F-9)

- **F-1 HLS — FIXED, implemented properly.** `lib/download/hls_downloader.dart`
  (new): playlist parsing (master/variant/media, relative URL resolution,
  `#EXT-X-MAP` init segment, `#EXT-X-KEY`, live detection). The download
  manager fetches the playlist, picks the best variant, downloads every
  segment and concatenates them into one playable file (`.ts`, or `.mp4`
  for fragmented MP4). Encrypted and live streams are refused honestly.
  Segment progress drives the progress bar. Tested end-to-end against a
  fake HLS origin (master/variant/segments, fMP4, encrypted, live,
  pause/resume).
- **F-2 Share-intent — FIXED.** `MainActivity.kt`: `ACTION_SEND` text is
  read in `onCreate` (cold start) and `onNewIntent` (singleTop, warm
  share) and forwarded to Dart as `sharedLink`; `HomeScreen` prefills the
  link field. Dart side verified by widget tests; the Kotlin side is
  code-reviewed only — confirm on a real phone (share a link from
  YouTube/Chrome and check the field prefills).
- **F-3 Queue persistence — FIXED (persistence half).** New
  `lib/download/queue_store.dart`: the queue is saved as JSON on every
  status change and per 1 MB of progress (direct downloads) / per HLS
  segment (awaited save after flush, so the file and the queue can never
  disagree). `DownloadManager.restore()` (awaited in `main()` before the
  first frame) brings interrupted downloads back as Paused with `.part`
  progress intact; a missing `.part` restarts from zero. Related note
  fixed: failed history entries no longer record partial bytes as the
  file size.
- **F-5** already fixed by `8b3a3fe` — confirmed via analyze (clean).
- **F-6** FIXED: the early-EOF check now only enforces a total the GET
  response itself declared (Content-Length / Content-Range); a HEAD total
  is display-only. Chunked GETs with no declared length are accepted.
- **F-7** FIXED: `.m3u8` routing checks the URL path only, not the query.
- **F-8** FIXED: save failure now says why (MediaStore channel
  unavailable + scoped storage blocks the fallback on Android 10+).
- **F-9** serial queue is by design — left as-is.
- **F-4 signing — NOT TOUCHED.** Debug keys stay; the user decides.

## Other professional cleanups

- `main.dart`: async startup (queue restore + history load before the
  first frame); `_recorded` moved up with the other fields.
- `api_client.dart`: the tripled POST extracted into `_postOnce`.
- `home_screen.dart`: quality rows no longer promise `.m3u8` as the saved
  file (HLS shows "HLS stream"); SnackBar after sheet-pop uses the page
  context, not the deactivated sheet context.
- `downloads_screen.dart`: progress bar uses segment progress for HLS.
- `nebula.dart`: stale comment fixed (the design spec file DOES exist);
  color values unchanged.
- `download_manager.dart`: a task removed mid-download no longer gets
  its file saved; `.part` file is deleted on remove.
- `README.md`: features + honest limits updated.

## Verification (this VM, 2026-11-19)

- `flutter test`: **47/47 passed** (was 24/24; +23 new: HLS parser 8,
  HLS downloads 5, queue persistence 5, share-intent 3, F-6 + remove
  guard 2).
- `flutter analyze`: **No issues found!**
- **NOT verified without an APK/phone:** the Kotlin share-intent path
  end-to-end, MediaStore publish on a real device, HLS playback of a
  real stream in a real player, the foreground-service remainder.

## Still owed (not this pass)

- Foreground service + persistent notification for backgrounded
  downloads (F-3 remainder).
- Signing decision (F-4): debug keys vs a release keystore.
- Parallel downloads (future feature).
- The laptop build itself (Flutter + SDK 36 install there first).
